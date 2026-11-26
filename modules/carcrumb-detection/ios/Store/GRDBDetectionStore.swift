import Foundation
import GRDB
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

extension StoredTrip: FetchableRecord {}
extension StoredParking: FetchableRecord {}
extension RoutePoint: FetchableRecord {}

/// Trips and parking in SQLite (GRDB), `Application Support/CarCrumb/carcrumb.sqlite`.
///
/// ## Single writer: `DatabaseQueue`, not `DatabasePool`
/// Swift is the only writer and every call arrives on the engine's serial queue
/// (`DetectionEngine.queue`); JS reads are routed through that queue as well. There is never
/// a concurrent reader to serve, so a pool's extra reader connections buy nothing, while a
/// single serialized connection keeps the single-writer rule structural (no second
/// connection can exist in the process), uses one file handle, and makes `VACUUM` and
/// `checkpoint(TRUNCATE)` deterministic (a pool reader holding a WAL snapshot would make
/// TRUNCATE return BUSY). Writes are small and rare: a few per trip, plus one route batch
/// (≤ `RouteSamplingConfig.flushBatchSize` points, one transaction) about once a minute while
/// driving.
///
/// ## WAL
/// Enabled per connection in `prepareDatabase` (docs/DECISIONS.md: "SQLite (GRDB, WAL)").
/// A write that is interrupted by the process being killed in the background (jetsam) never
/// leaves a half-written main file, and commits are cheaper than rollback-journal fsyncs.
/// Removed coordinates must not linger in the WAL: `secure_delete` zeroes them in the page
/// images, every write that deletes coordinates (park replace / prune, route thinning, route
/// retention purge) is followed by `checkpoint(TRUNCATE)` (cheap here: tiny database, serial queue, no readers), and
/// `journal_size_limit = 0` truncates the WAL whenever SQLite itself resets it.
///
/// ## File protection / backup
/// The `CarCrumb/` directory is created with `completeUntilFirstUserAuthentication` and is
/// excluded from backup; `-wal` / `-shm` are created inside it and inherit the class. After
/// opening, the class is also set explicitly on the db, `-wal` and `-shm`.
///
/// ## Locked device (before first unlock after a reboot)
/// Opening is lazy and retried at every call; it never crashes. Until it succeeds,
/// `beginTrip` and the reads throw `StoreError.unavailable`; `refineTripStart`, `endTrip`,
/// `saveClosedTrip` and `saveParking` are buffered in memory (bounded, in order) and replayed,
/// with the same rules, right after the first successful open. Buffered calls throw
/// `.unavailable` (except `saveClosedTrip`, which returns a provisional id) so the engine knows
/// the write is deferred. Buffered writes are lost if the process dies first.
/// Route points are the exception: `appendRoutePoints` is never buffered (a trip that began
/// while locked has no trip row, so the engine records no route for it; the trip itself is
/// still written by `saveClosedTrip`, "rotasız", with `distanceMeters = NULL`).
///
/// Threading: not thread-safe by itself; confined to the engine queue (see `DetectionStore`).
/// Privacy: no logging here at all; coordinates only go to SQLite.
public final class GRDBDetectionStore: DetectionStore {
  public static let fileName = "carcrumb.sqlite"
  static let maxPendingWrites = 64

  private let directoryProvider: () throws -> URL
  private var dbQueue: DatabaseQueue?
  private var pending: [PendingWrite] = []
  /// Provisional (negative) trip id from `saveClosedTrip` → real row id, filled at replay.
  private var provisionalTripIDs: [Int64: Int64] = [:]
  private var nextProvisionalID: Int64 = -1
  public private(set) var databaseURL: URL?

  /// Application Support/CarCrumb (protected, excluded from backup).
  public convenience init() {
    self.init(directoryProvider: { try ProtectedFiles.directory("CarCrumb") })
  }

  /// `directoryProvider` is called at every open attempt until one succeeds (tests pass a
  /// temporary directory, or a provider that fails first to simulate a locked device).
  public init(directoryProvider: @escaping () throws -> URL) {
    self.directoryProvider = directoryProvider
  }

  public var isOpen: Bool { dbQueue != nil }
  var pendingWriteCount: Int { pending.count }

  // MARK: Open

  private func database() throws -> DatabaseQueue {
    if let dbQueue { return dbQueue }
    let url: URL
    let queue: DatabaseQueue
    do {
      url = try directoryProvider().appendingPathComponent(Self.fileName)
      queue = try DatabaseQueue(path: url.path, configuration: Self.configuration())
      try StoreSchema.migrator.migrate(queue)
    } catch {
      // Typically: data protection before the first unlock. No error text is kept (it can
      // contain the container path); retried at the next call.
      throw StoreError.unavailable
    }
    Self.protectFiles(of: url)
    dbQueue = queue
    databaseURL = url
    flushPending(into: queue)
    return queue
  }

  private struct WALRefused: Error {}

  static func configuration() -> Configuration {
    var config = Configuration()
    config.label = "CarCrumbStore"
    config.foreignKeysEnabled = true
    config.prepareDatabase { db in
      let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
      guard mode?.lowercased() == "wal" else { throw WALRefused() }
      // Deleted content is overwritten with zeros (history deletion, superseded parks).
      try db.execute(sql: "PRAGMA secure_delete = ON")
      // Truncate the WAL to 0 bytes whenever SQLite resets it (no stale frames kept on disk).
      _ = try Int.fetchOne(db, sql: "PRAGMA journal_size_limit = 0")
    }
    return config
  }

  private static func protectFiles(of dbURL: URL) {
    for suffix in ["", "-wal", "-shm"] {
      let url = URL(fileURLWithPath: dbURL.path + suffix)
      try? ProtectedFiles.protectExistingFile(at: url)
    }
    var db = dbURL
    try? ProtectedFiles.excludeFromBackup(&db)
  }

  /// Copies the WAL into the main file and truncates it to 0 bytes. Best effort: the data is
  /// already committed; a failure (BUSY) only delays it to the next one.
  private static func truncateWAL(_ queue: DatabaseQueue) {
    _ = try? queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
  }

  // MARK: Buffered writes

  enum PendingWrite {
    case refine(tripID: Int64, startedAt: Date)
    case end(tripID: Int64, status: TripStatus, endedAt: Date)
    case closedTrip(provisionalID: Int64, startedAt: Date, detectedAt: Date, endedAt: Date, status: TripStatus)
    case park(ParkPoint, tripID: Int64?)
  }

  private func buffer(_ write: PendingWrite) {
    pending.append(write)
    if pending.count > Self.maxPendingWrites {
      // Oldest first. A dropped closedTrip leaves its park without trip; a dropped endTrip
      // leaves the trip open until `abandonOpenTrips` at a later launch.
      pending.removeFirst(pending.count - Self.maxPendingWrites)
    }
  }

  private func flushPending(into queue: DatabaseQueue) {
    let writes = pending
    pending.removeAll()
    guard !writes.isEmpty else { return }
    for write in writes {
      // Same rules as a live write; a rejected or failing one is dropped.
      _ = try? queue.write { db in try self.apply(write, db) }
    }
    Self.truncateWAL(queue)
  }

  /// Writes now, or buffers and throws `.unavailable` when the database cannot be opened.
  @discardableResult
  private func perform(_ write: PendingWrite) throws -> ParkingWriteOutcome? {
    let queue: DatabaseQueue
    do {
      queue = try database()
    } catch {
      buffer(write)
      throw error
    }
    let outcome = try queue.write { db in try self.apply(write, db) }
    if case .park = write, outcome?.wasWritten == true {
      // A replace or prune may have deleted a park: do not leave its frames in the WAL.
      Self.truncateWAL(queue)
    }
    return outcome
  }

  @discardableResult
  private func apply(_ write: PendingWrite, _ db: Database) throws -> ParkingWriteOutcome? {
    switch write {
    case let .refine(tripID, startedAt):
      // Only ever earlier (the estimator looks back from detection).
      try db.execute(
        sql: "UPDATE trips SET startedAt = ? WHERE id = ? AND startedAt > ?",
        arguments: [startedAt, tripID, startedAt])
      return nil
    case let .end(tripID, status, endedAt):
      // Running total from appendRoutePoints (not the thinned route); the route's own sum
      // only covers a route begun by an older build. Same transaction as the close.
      let accumulated = try Double.fetchOne(db, sql: "SELECT distanceMeters FROM trips WHERE id = ?", arguments: [tripID])
      let distance = try RouteDistance.closing(
        accumulated: accumulated, routeSum: RouteDistance.meters(Self.route(tripID: tripID, db)))
      try db.execute(
        sql: "UPDATE trips SET endedAt = ?, status = ?, distanceMeters = ? WHERE id = ?",
        arguments: [endedAt, StoredTripStatus(status).rawValue, distance, tripID])
      return nil
    case let .closedTrip(provisionalID, startedAt, detectedAt, endedAt, status):
      provisionalTripIDs[provisionalID] = try Self.insertClosedTrip(
        startedAt: startedAt, detectedAt: detectedAt, endedAt: endedAt, status: status, db)
      return nil
    case let .park(point, tripID):
      // A provisional id resolves to the row its buffered closedTrip created (nil if dropped).
      let resolved = tripID.flatMap { $0 < 0 ? provisionalTripIDs[$0] : $0 }
      return try Self.saveParking(point, tripID: resolved, db)
    }
  }

  // MARK: DetectionStore (writes)

  public func beginTrip(startedAt: Date) throws -> Int64 {
    try database().write { db in
      try db.execute(
        sql: "INSERT INTO trips (startedAt, detectedAt) VALUES (?, ?)",
        arguments: [startedAt, startedAt])
      return db.lastInsertedRowID
    }
  }

  public func refineTripStart(tripID: Int64, startedAt: Date) throws {
    try perform(.refine(tripID: tripID, startedAt: startedAt))
  }

  public func endTrip(tripID: Int64?, status: TripStatus, endedAt: Date) throws {
    guard let tripID else { return }
    try perform(.end(tripID: tripID, status: status, endedAt: endedAt))
  }

  public func saveClosedTrip(startedAt: Date, detectedAt: Date, endedAt: Date, status: TripStatus) throws -> Int64 {
    let queue: DatabaseQueue
    do {
      queue = try database()
    } catch {
      let provisional = nextProvisionalID
      nextProvisionalID -= 1
      buffer(.closedTrip(
        provisionalID: provisional, startedAt: startedAt, detectedAt: detectedAt, endedAt: endedAt, status: status))
      return provisional
    }
    return try queue.write { db in
      try Self.insertClosedTrip(startedAt: startedAt, detectedAt: detectedAt, endedAt: endedAt, status: status, db)
    }
  }

  private static func insertClosedTrip(
    startedAt: Date, detectedAt: Date, endedAt: Date, status: TripStatus, _ db: Database
  ) throws -> Int64 {
    try db.execute(
      sql: "INSERT INTO trips (startedAt, detectedAt, endedAt, status) VALUES (?, ?, ?, ?)",
      arguments: [startedAt, detectedAt, endedAt, StoredTripStatus(status).rawValue])
    return db.lastInsertedRowID
  }

  @discardableResult
  public func saveParking(_ point: ParkPoint, tripID: Int64?) throws -> ParkingWriteOutcome {
    // `perform` returns an outcome for every `.park` write.
    try perform(.park(point, tripID: tripID)) ?? .inserted
  }

  /// `ParkingPolicy` inside one write transaction (decision, write and pruning are atomic).
  static func saveParking(_ point: ParkPoint, tripID requestedTripID: Int64?, _ db: Database) throws -> ParkingWriteOutcome {
    var tripID: Int64?
    var tripStatus: StoredTripStatus?
    if let id = requestedTripID,
       let row = try Row.fetchOne(db, sql: "SELECT id, status FROM trips WHERE id = ?", arguments: [id]) {
      tripID = id
      tripStatus = (row["status"] as String?).flatMap(StoredTripStatus.init(rawValue:))
    } // Unknown trip (e.g. deleted): stored without trip reference.

    let sameTrip = try tripID.flatMap {
      try StoredParking.fetchOne(db, sql: "SELECT * FROM parkings WHERE tripId = ?", arguments: [$0])
    }
    let latestHigh = try StoredParking.fetchOne(
      db, sql: "SELECT * FROM parkings WHERE confidence = 'high' ORDER BY \(newestFirst) LIMIT 1")

    let outcome: ParkingWriteOutcome
    switch ParkingPolicy.decide(point, tripID: tripID, tripStatus: tripStatus, sameTrip: sameTrip, latestHigh: latestHigh) {
    case let .reject(rejection):
      return rejection
    case let .replace(existingID):
      // Delete + insert: the replacement gets a new id, i.e. it is the newest write.
      try db.execute(sql: "DELETE FROM parkings WHERE id = ?", arguments: [existingID])
      outcome = .replaced
    case .insert:
      outcome = .inserted
    }
    try db.execute(
      sql: """
        INSERT INTO parkings (tripId, latitude, longitude, accuracy, confidence, parkedAt, fixAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        tripID, point.location.latitude, point.location.longitude, point.location.accuracy,
        point.confidence.rawValue, point.parkedAt, point.location.timestamp,
      ])
    let newID = db.lastInsertedRowID
    // Keep the last 3 by write order (same order as ParkingPolicy.isNewer).
    try db.execute(
      sql: "DELETE FROM parkings WHERE id NOT IN (SELECT id FROM parkings ORDER BY \(newestFirst) LIMIT ?)",
      arguments: [ParkingPolicy.keepCount])
    // The outcome must match the stored data (the engine moves the geofence only if written).
    let kept = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM parkings WHERE id = ?)", arguments: [newID]) ?? false
    return kept ? outcome : .notKept
  }

  /// SQL twin of `ParkingPolicy.isNewer`: write order, never the device clock.
  static let newestFirst = "id DESC"

  public func abandonOpenTrips(except tripID: Int64?) throws {
    try database().write { db in
      // Detach parks first: an uncertain trip has no park (rule 1; the trigger only checks
      // inserts / tripId updates, not a status change of the trip).
      try db.execute(
        sql: """
          UPDATE parkings SET tripId = NULL
          WHERE tripId IN (SELECT id FROM trips WHERE status IS NULL AND (? IS NULL OR id != ?))
          """,
        arguments: [tripID, tripID])
      try db.execute(
        sql: """
          UPDATE trips SET status = 'uncertain', endedAt = COALESCE(endedAt, startedAt)
          WHERE status IS NULL AND (? IS NULL OR id != ?)
          """,
        arguments: [tripID, tripID])
    }
  }

  // MARK: Route

  @discardableResult
  public func appendRoutePoints(_ points: [RoutePoint], tripID: Int64, maxPoints: Int) throws -> RouteAppendResult {
    // Not `perform`: route points are never buffered (see the type doc).
    let queue = try database()
    let result = try queue.write { db -> RouteAppendResult in
      guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM trips WHERE id = ?)", arguments: [tripID]) == true else {
        return RouteAppendResult(storedCount: 0, thinCount: 0) // deleted / unknown trip
      }
      let maxSeq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM trip_points WHERE tripId = ?", arguments: [tripID])
      // Running distance BEFORE thinning (the last stored point is never thinned away).
      let previous = try maxSeq.flatMap {
        try RoutePoint.fetchOne(
          db, sql: "SELECT latitude, longitude, accuracy, timestamp FROM trip_points WHERE tripId = ? AND seq = ?",
          arguments: [tripID, $0])
      }
      if let added = RouteDistance.increment(after: previous, appending: points) {
        try db.execute(
          sql: "UPDATE trips SET distanceMeters = COALESCE(distanceMeters, 0) + ? WHERE id = ?",
          arguments: [added, tripID])
      }
      var seq = (maxSeq ?? -1) + 1
      let insert = try db.makeStatement(sql: """
        INSERT INTO trip_points (tripId, seq, timestamp, latitude, longitude, accuracy)
        VALUES (?, ?, ?, ?, ?, ?)
        """)
      for point in points {
        try insert.execute(arguments: [tripID, seq, point.timestamp, point.latitude, point.longitude, point.accuracy])
        seq += 1
      }
      return try Self.thinRoute(tripID: tripID, maxPoints: maxPoints, db)
    }
    if result.thinned {
      // Thinned-out coordinates must not linger in the WAL (same rule as pruned parks).
      Self.truncateWAL(queue)
    }
    return result
  }

  /// `RouteThinning` on the stored rows (route order = seq), inside the caller's transaction.
  static func thinRoute(tripID: Int64, maxPoints: Int, _ db: Database) throws -> RouteAppendResult {
    let ids = try Int64.fetchAll(db, sql: "SELECT id FROM trip_points WHERE tripId = ? ORDER BY seq", arguments: [tripID])
    let (kept, passes) = RouteThinning.thinCounting(ids, maxCount: maxPoints)
    if passes > 0 {
      let keep = Set(kept)
      let delete = try db.makeStatement(sql: "DELETE FROM trip_points WHERE id = ?")
      for id in ids where !keep.contains(id) {
        try delete.execute(arguments: [id])
      }
    }
    return RouteAppendResult(storedCount: kept.count, thinCount: passes)
  }

  public func tripRoute(tripID: Int64) throws -> [RoutePoint] {
    try database().read { db in try Self.route(tripID: tripID, db) }
  }

  /// From the `seq` gap of the first two points (`RouteThinning.thinCount`).
  public func routeThinCount(tripID: Int64) throws -> Int {
    try database().read { db in
      let seqs = try Int64.fetchAll(
        db, sql: "SELECT seq FROM trip_points WHERE tripId = ? ORDER BY seq LIMIT 2", arguments: [tripID])
      guard seqs.count == 2 else { return 0 }
      return RouteThinning.thinCount(firstSeq: seqs[0], secondSeq: seqs[1])
    }
  }

  /// Retention purge. Dates compare correctly as stored text (see StoreSchema).
  @discardableResult
  public func purgeExpiredRoutes(olderThan cutoff: Date) throws -> Int {
    let queue = try database()
    // Closed trips only; an open trip has no endedAt (and no status).
    let expired = "SELECT id FROM trips WHERE status IS NOT NULL AND endedAt IS NOT NULL AND endedAt < ?"
    // Nothing expired (the usual daily case): no write transaction at all.
    let any = try queue.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM trip_points WHERE tripId IN (\(expired)))", arguments: [cutoff])
    } ?? false
    guard any else { return 0 }
    let deleted = try queue.write { db -> Int in
      try db.execute(sql: "DELETE FROM trip_points WHERE tripId IN (\(expired))", arguments: [cutoff])
      return db.changesCount
    }
    if deleted > 0 {
      // Purged coordinates must not linger in the WAL (same rule as thinning / pruned parks).
      Self.truncateWAL(queue)
    }
    return deleted
  }

  static func route(tripID: Int64, _ db: Database) throws -> [RoutePoint] {
    try RoutePoint.fetchAll(
      db, sql: "SELECT latitude, longitude, accuracy, timestamp FROM trip_points WHERE tripId = ? ORDER BY seq",
      arguments: [tripID])
  }

  // MARK: DetectionStore (reads)

  public func lastParking() throws -> StoredParking? {
    try database().read { db in
      try StoredParking.fetchOne(db, sql: "SELECT * FROM parkings ORDER BY \(Self.newestFirst) LIMIT 1")
    }
  }

  public func recentParkings() throws -> [StoredParking] {
    try database().read { db in
      try StoredParking.fetchAll(
        db, sql: "SELECT * FROM parkings ORDER BY \(Self.newestFirst) LIMIT ?",
        arguments: [ParkingPolicy.keepCount])
    }
  }

  public func trips(limit: Int) throws -> [StoredTrip] {
    try database().read { db in
      try StoredTrip.fetchAll(
        db, sql: "SELECT * FROM trips ORDER BY id DESC LIMIT ?", // write order, see DetectionStore
        arguments: [max(0, limit)])
    }
  }

  // MARK: History deletion

  /// Rows → VACUUM (rebuilds the file without the freed pages) → checkpoint(TRUNCATE)
  /// (copies the WAL into the main file and truncates `-wal` to 0 bytes, so no deleted
  /// content survives in the WAL either). `secure_delete` additionally zeroes freed pages.
  /// `sqlite_sequence` is kept on purpose (ids are never reused, see StoreSchema).
  public func deleteAllHistory() throws {
    pending.removeAll()
    provisionalTripIDs.removeAll()
    let queue = try database()
    try queue.write { db in
      // trip_points would also go with the trips (ON DELETE CASCADE); deleted explicitly so
      // the step does not depend on the foreign-key setting of the connection.
      try db.execute(sql: "DELETE FROM trip_points")
      try db.execute(sql: "DELETE FROM parkings")
      try db.execute(sql: "DELETE FROM trips")
    }
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM")
      _ = try db.checkpoint(.truncate)
    }
  }

  // MARK: Test support

  func read<T>(_ block: (Database) throws -> T) throws -> T {
    try database().read(block)
  }
}
