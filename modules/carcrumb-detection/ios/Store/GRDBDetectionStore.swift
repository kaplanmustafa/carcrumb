import Foundation
import GRDB
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

extension StoredTrip: FetchableRecord {}
extension StoredParking: FetchableRecord {}

/// Trips and parking in SQLite (GRDB), `Application Support/CarCrumb/carcrumb.sqlite`.
///
/// ## Single writer: `DatabaseQueue`, not `DatabasePool`
/// Swift is the only writer and every call arrives on the engine's serial queue
/// (`DetectionEngine.queue`); JS reads are routed through that queue as well. There is never
/// a concurrent reader to serve, so a pool's extra reader connections buy nothing, while a
/// single serialized connection keeps the single-writer rule structural (no second
/// connection can exist in the process), uses one file handle, and makes `VACUUM` and
/// `checkpoint(TRUNCATE)` in history deletion deterministic (a pool reader holding a WAL
/// snapshot would make TRUNCATE return BUSY). Writes are tiny and rare (a few per trip).
///
/// ## WAL
/// Enabled per connection in `prepareDatabase` (docs/DECISIONS.md: "SQLite (GRDB, WAL)").
/// A write that is interrupted by the process being killed in the background (jetsam) never
/// leaves a half-written main file, and commits are cheaper than rollback-journal fsyncs.
///
/// ## File protection / backup
/// The `CarCrumb/` directory is created with `completeUntilFirstUserAuthentication` and is
/// excluded from backup; `-wal` / `-shm` are created inside it and inherit the class. After
/// opening, the class is also set explicitly on the db, `-wal` and `-shm`.
///
/// ## Locked device (before first unlock after a reboot)
/// Opening is lazy and retried at every call; it never crashes. Until it succeeds,
/// `beginTrip` and the reads throw `StoreError.unavailable`; `refineTripStart`, `endTrip`
/// and `saveParking` are buffered in memory (bounded, in order) and replayed, with the same
/// rules, right after the first successful open, then also throw `.unavailable` so the
/// engine knows the write is deferred. Buffered writes are lost if the process dies first.
///
/// Threading: not thread-safe by itself; confined to the engine queue (see `DetectionStore`).
/// Privacy: no logging here at all; coordinates only go to SQLite.
public final class GRDBDetectionStore: DetectionStore {
  public static let fileName = "carcrumb.sqlite"
  static let maxPendingWrites = 64

  private let directoryProvider: () throws -> URL
  private var dbQueue: DatabaseQueue?
  private var pending: [PendingWrite] = []
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

  // MARK: Buffered writes

  enum PendingWrite {
    case refine(tripID: Int64, startedAt: Date)
    case end(tripID: Int64, status: TripStatus, endedAt: Date)
    case park(ParkPoint, tripID: Int64?)
  }

  private func buffer(_ write: PendingWrite) {
    pending.append(write)
    if pending.count > Self.maxPendingWrites {
      pending.removeFirst(pending.count - Self.maxPendingWrites)
    }
  }

  private func flushPending(into queue: DatabaseQueue) {
    let writes = pending
    pending.removeAll()
    for write in writes {
      // Same rules as a live write; a rejected or failing one is dropped.
      _ = try? queue.write { db in try Self.apply(write, db) }
    }
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
    return try queue.write { db in try Self.apply(write, db) }
  }

  @discardableResult
  static func apply(_ write: PendingWrite, _ db: Database) throws -> ParkingWriteOutcome? {
    switch write {
    case let .refine(tripID, startedAt):
      // Only ever earlier (the estimator looks back from detection).
      try db.execute(
        sql: "UPDATE trips SET startedAt = ? WHERE id = ? AND startedAt > ?",
        arguments: [startedAt, tripID, startedAt])
      return nil
    case let .end(tripID, status, endedAt):
      try db.execute(
        sql: "UPDATE trips SET endedAt = ?, status = ? WHERE id = ?",
        arguments: [endedAt, StoredTripStatus(status).rawValue, tripID])
      return nil
    case let .park(point, tripID):
      return try saveParking(point, tripID: tripID, db)
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
    let newestHigh = try Date.fetchOne(db, sql: "SELECT MAX(parkedAt) FROM parkings WHERE confidence = 'high'")

    let outcome: ParkingWriteOutcome
    switch ParkingPolicy.decide(point, tripStatus: tripStatus, sameTrip: sameTrip, newestHighParkedAt: newestHigh) {
    case let .reject(rejection):
      return rejection
    case let .replace(existingID):
      try db.execute(
        sql: """
          UPDATE parkings SET latitude = ?, longitude = ?, accuracy = ?, confidence = ?, parkedAt = ?, fixAt = ?
          WHERE id = ?
          """,
        arguments: [
          point.location.latitude, point.location.longitude, point.location.accuracy,
          point.confidence.rawValue, point.parkedAt, point.location.timestamp, existingID,
        ])
      outcome = .replaced
    case .insert:
      try db.execute(
        sql: """
          INSERT INTO parkings (tripId, latitude, longitude, accuracy, confidence, parkedAt, fixAt)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          tripID, point.location.latitude, point.location.longitude, point.location.accuracy,
          point.confidence.rawValue, point.parkedAt, point.location.timestamp,
        ])
      outcome = .inserted
    }
    // Keep the last 3 (same order as ParkingPolicy.isNewer).
    try db.execute(
      sql: "DELETE FROM parkings WHERE id NOT IN (SELECT id FROM parkings ORDER BY \(newestFirst) LIMIT ?)",
      arguments: [ParkingPolicy.keepCount])
    return outcome
  }

  /// SQL twin of `ParkingPolicy.isNewer`.
  static let newestFirst = "parkedAt DESC, (confidence = 'high') DESC, id DESC"

  public func abandonOpenTrips(except tripID: Int64?) throws {
    try database().write { db in
      try db.execute(
        sql: """
          UPDATE trips SET status = 'uncertain', endedAt = COALESCE(endedAt, startedAt)
          WHERE status IS NULL AND (? IS NULL OR id != ?)
          """,
        arguments: [tripID, tripID])
    }
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
        db, sql: "SELECT * FROM trips ORDER BY startedAt DESC, id DESC LIMIT ?",
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
    let queue = try database()
    try queue.write { db in
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
