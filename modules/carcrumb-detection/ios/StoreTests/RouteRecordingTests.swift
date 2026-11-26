import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

// Route recording: sampler, thinning, distance, schema v2, store behaviour.
// Synthetic coordinates only (CLAUDE.md: 41.0±0.1 / -40.0±0.1). Runs on macOS CI (`swift test`).

enum RouteFixtures {
  static let metresPerDegreeLat = 6_371_000.0 * .pi / 180 // haversine radius, ≈ 111 195 m

  /// A fix `north` metres north of 41.0 / -40.0 at `offset` seconds after `t0`.
  static func sample(
    north: Double, at offset: TimeInterval, accuracy: Double = 5, speed: Double = 10
  ) -> LocationSample {
    LocationSample(
      latitude: 41.0 + north / metresPerDegreeLat, longitude: -40.0,
      accuracy: accuracy, speed: speed, timestamp: StoreFixtures.date(offset))
  }

  static func point(north: Double, at offset: TimeInterval) -> RoutePoint {
    RoutePoint(sample(north: north, at: offset))
  }

  /// `count` points 100 m apart going north (≤ 0.09° for count ≤ 100: inside the box).
  static func straightRoute(_ count: Int, from start: TimeInterval = 0) -> [RoutePoint] {
    (0..<count).map { point(north: Double($0) * 100, at: start + Double($0) * 10) }
  }
}

final class RouteSamplerTests: XCTestCase {
  private func sampler() -> RouteSampler {
    var s = RouteSampler()
    s.begin(tripID: 1)
    return s
  }

  func testDefaultsAreTheDocumentedValues() {
    let c = RouteSamplingConfig()
    XCTAssertEqual(c.maxAccuracy, 30)
    XCTAssertEqual(c.minDistance, 25)
    XCTAssertEqual(c.minInterval, 15)
    XCTAssertEqual(c.minVehicleSpeed, DetectionConfig().maxWalkingSpeed, "same threshold as the reducer's movement evidence")
    XCTAssertEqual(c.maxPointsPerTrip, 5000)
    XCTAssertEqual(c.flushBatchSize, 20)
    XCTAssertEqual(c.maxPendingAge, 60)
    XCTAssertEqual(c.maxClockStepBack, 60)
  }

  func testNothingWithoutTripOrOutsideDriving() {
    var idle = RouteSampler()
    XCTAssertFalse(idle.offer(RouteFixtures.sample(north: 0, at: 0), driving: true), "no trip row")
    var s = sampler()
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 0), driving: false), "MAYBE_PARKED / not driving")
    XCTAssertTrue(s.pending.isEmpty)
  }

  func testAccuracyFilter() {
    var s = sampler()
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 0, accuracy: 30.1), driving: true))
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 1, accuracy: -1), driving: true), "invalid accuracy")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 2, accuracy: 30), driving: true), "limit is inclusive")
  }

  func testOnlyVehicleSpeed() {
    var s = sampler()
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 0, speed: 1.4), driving: true), "walking speed")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 1, speed: 2.5), driving: true), "walking limit itself")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 0, at: 2, speed: -1), driving: true), "unknown speed")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 3, speed: 2.6), driving: true))
  }

  func testSpacingDistanceOrTime() {
    var s = sampler()
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 0), driving: true), "first point")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 20, at: 5), driving: true), "20 m, 5 s: too close")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 26, at: 6), driving: true), ">= 25 m")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 36, at: 20), driving: true), "10 m, 14 s")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 36, at: 21), driving: true), "10 m but >= 15 s")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 500, at: 10), driving: true), "older than the last kept fix")
    XCTAssertEqual(s.pending.count, 3)
    // Compared with the last KEPT point, not the last offered one.
    XCTAssertEqual(s.lastKept?.timestamp, StoreFixtures.date(21))
  }

  func testThinningDoublesSpacing() {
    var s = sampler()
    s.didThin()
    XCTAssertEqual(s.spacingScale, 2)
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 0), driving: true))
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 30, at: 5), driving: true), "30 m < 50 m")
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 30, at: 20), driving: true), "20 s < 30 s")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 51, at: 21), driving: true))
  }

  func testFlushPolicy() {
    var s = sampler()
    XCTAssertFalse(s.shouldFlush(now: StoreFixtures.date(1000)), "nothing pending")
    for i in 0..<19 {
      s.offer(RouteFixtures.sample(north: Double(i) * 30, at: Double(i)), driving: true)
    }
    XCTAssertEqual(s.pending.count, 19)
    XCTAssertFalse(s.shouldFlush(now: StoreFixtures.date(20)))
    XCTAssertTrue(s.shouldFlush(now: StoreFixtures.date(60)), "oldest pending is 60 s old")
    s.offer(RouteFixtures.sample(north: 19 * 30, at: 19), driving: true)
    XCTAssertTrue(s.shouldFlush(now: StoreFixtures.date(20)), "batch of 20")
    XCTAssertTrue(s.shouldFlush(now: StoreFixtures.date(-5000)), "a full batch flushes even if the clock jumped back")
    let taken = s.takePending()
    XCTAssertEqual(taken.count, 20)
    XCTAssertTrue(s.pending.isEmpty)
    XCTAssertEqual(s.lastKept, taken.last, "spacing continues from the written points")
  }

  func testBeginAndResetDropEverything() {
    var s = sampler()
    s.didThin()
    s.offer(RouteFixtures.sample(north: 0, at: 0), driving: true)
    s.begin(tripID: 2)
    XCTAssertEqual(s.tripID, 2)
    XCTAssertTrue(s.pending.isEmpty)
    XCTAssertNil(s.lastKept)
    XCTAssertEqual(s.spacingScale, 1)
    s.reset()
    XCTAssertNil(s.tripID)
  }
}

final class RouteThinningAndDistanceTests: XCTestCase {
  func testPositionsToRemove() {
    XCTAssertEqual(RouteThinning.positionsToRemove(count: 2), [])
    XCTAssertEqual(RouteThinning.positionsToRemove(count: 3), [1])
    XCTAssertEqual(RouteThinning.positionsToRemove(count: 5), [1, 3])
    XCTAssertEqual(RouteThinning.positionsToRemove(count: 6), [1, 3], "last point is kept")
  }

  func testThinKeepsFirstAndLastAndRespectsCap() {
    let points = Array(0..<5001)
    let (thinned, didThin) = RouteThinning.thin(points, maxCount: 5000)
    XCTAssertTrue(didThin)
    XCTAssertEqual(thinned.first, 0)
    XCTAssertEqual(thinned.last, 5000)
    XCTAssertEqual(thinned.count, 2501)
    XCTAssertEqual(thinned, thinned.sorted(), "order kept")
    XCTAssertFalse(RouteThinning.thin(Array(0..<5000), maxCount: 5000).thinned, "at the cap: untouched")
  }

  func testDistance() throws {
    XCTAssertNil(RouteDistance.meters([]))
    XCTAssertNil(RouteDistance.meters([RouteFixtures.point(north: 0, at: 0)]), "one point: unknown, not 0")
    // 0.01° of latitude on the haversine sphere.
    let a = RoutePoint(latitude: 41.0, longitude: -40.0, accuracy: 5, timestamp: StoreFixtures.date(0))
    let b = RoutePoint(latitude: 41.01, longitude: -40.0, accuracy: 5, timestamp: StoreFixtures.date(60))
    XCTAssertEqual(try XCTUnwrap(RouteDistance.meters([a, b])), 1111.95, accuracy: 0.01)
    // Sum of segments, not start-to-end: there and back is twice the distance.
    XCTAssertEqual(try XCTUnwrap(RouteDistance.meters([a, b, a])), 2223.9, accuracy: 0.02)
    XCTAssertEqual(try XCTUnwrap(RouteDistance.meters(RouteFixtures.straightRoute(5))), 400, accuracy: 0.01)
    // East-west at 41° N: shorter than the same angle north-south.
    let c = RoutePoint(latitude: 41.0, longitude: -39.99, accuracy: 5, timestamp: StoreFixtures.date(60))
    XCTAssertEqual(try XCTUnwrap(RouteDistance.meters([a, c])), 1111.95 * cos(41.0 * .pi / 180), accuracy: 0.1)
  }
}

/// Same scenarios against both stores.
enum RouteStoreScenarios {
  static func routeOrderAndDistance(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = RouteFixtures.straightRoute(6)
    XCTAssertEqual(try store.appendRoutePoints(Array(route[0..<4]), tripID: trip, maxPoints: 5000),
                   RouteAppendResult(storedCount: 4, thinCount: 0), file: file, line: line)
    try store.appendRoutePoints(Array(route[4...]), tripID: trip, maxPoints: 5000)
    XCTAssertEqual(try store.tripRoute(tripID: trip), route, "batches keep route order", file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line), 500, accuracy: 0.01,
                   "open trip: running distance across both batches (bridge segment included)", file: file, line: line)

    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    let distance = try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line)
    XCTAssertEqual(distance, 500, accuracy: 0.01, file: file, line: line)

    // A trip without a route (or one point) has an unknown distance.
    let bare = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    try store.appendRoutePoints([RouteFixtures.point(north: 0, at: 1000)], tripID: bare, maxPoints: 5000)
    try store.endTrip(tripID: bare, status: .uncertain, endedAt: StoreFixtures.date(1600))
    XCTAssertNil(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line)
    let closed = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(2000), detectedAt: StoreFixtures.date(2000), endedAt: StoreFixtures.date(2600), status: .confirmed)
    XCTAssertEqual(try store.tripRoute(tripID: closed), [], file: file, line: line)
    XCTAssertNil(try store.trips(limit: 1).first?.distanceMeters, "saveClosedTrip: rotasız", file: file, line: line)
  }

  static func unknownTripWritesNothing(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(3), tripID: 999_999, maxPoints: 5000),
                   RouteAppendResult(storedCount: 0, thinCount: 0), file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: 999_999), [], file: file, line: line)
  }

  static func thinsAtTheCap(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = RouteFixtures.straightRoute(13)
    try store.appendRoutePoints(Array(route[0..<8]), tripID: trip, maxPoints: 10)
    XCTAssertEqual(try store.appendRoutePoints(Array(route[8...]), tripID: trip, maxPoints: 10),
                   RouteAppendResult(storedCount: 7, thinCount: 1), file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: trip), stride(from: 0, to: 13, by: 2).map { route[$0] },
                   "every second point, first and last kept", file: file, line: line)
    // Later points still come after the thinned ones.
    let next = RouteFixtures.point(north: 1300, at: 130)
    try store.appendRoutePoints([next], tripID: trip, maxPoints: 10)
    XCTAssertEqual(try store.tripRoute(tripID: trip).last, next, file: file, line: line)
    // Distance is unchanged by thinning on a straight road.
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line), 1300, accuracy: 0.01,
                   file: file, line: line)
  }

  static func deleteAllRemovesRoutes(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.appendRoutePoints(RouteFixtures.straightRoute(5), tripID: trip, maxPoints: 5000)
    try store.deleteAllHistory()
    XCTAssertEqual(try store.tripRoute(tripID: trip), [], file: file, line: line)
    // The stale id (still held by the engine for a moment) cannot write into nothing.
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(2), tripID: trip, maxPoints: 5000).storedCount, 0,
                   file: file, line: line)
  }

  static func routesAreSeparatePerTrip(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let b = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    let routeA = RouteFixtures.straightRoute(3)
    let routeB = RouteFixtures.straightRoute(4, from: 1000)
    try store.appendRoutePoints([routeA[0]], tripID: a, maxPoints: 5000)
    try store.appendRoutePoints(Array(routeB[0..<2]), tripID: b, maxPoints: 5000)
    try store.appendRoutePoints(Array(routeA[1...]), tripID: a, maxPoints: 5000)
    try store.appendRoutePoints(Array(routeB[2...]), tripID: b, maxPoints: 5000)
    XCTAssertEqual(try store.tripRoute(tripID: a), routeA, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: b), routeB, file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try routeOrderAndDistance(make())
    try unknownTripWritesNothing(make())
    try thinsAtTheCap(make())
    try deleteAllRemovesRoutes(make())
    try routesAreSeparatePerTrip(make())
  }
}

final class InMemoryRouteStoreTests: XCTestCase {
  func testSameRouteRulesAsSQLiteStore() throws {
    try RouteStoreScenarios.runAll { InMemoryDetectionStore() }
  }
}

final class GRDBRouteStoreTests: TemporaryDirectoryTestCase {
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  private var databasePath: String { directory.appendingPathComponent(GRDBDetectionStore.fileName).path }

  private static func bytes(of value: Double) -> Data {
    var bits = value.bitPattern.bigEndian // SQLite stores REAL big-endian
    return Data(bytes: &bits, count: 8)
  }

  func testRouteOrderAndDistance() throws { try RouteStoreScenarios.routeOrderAndDistance(fresh()) }
  func testUnknownTripWritesNothing() throws { try RouteStoreScenarios.unknownTripWritesNothing(fresh()) }
  func testThinsAtTheCap() throws { try RouteStoreScenarios.thinsAtTheCap(fresh()) }
  func testDeleteAllRemovesRoutes() throws { try RouteStoreScenarios.deleteAllRemovesRoutes(fresh()) }
  func testRoutesAreSeparatePerTrip() throws { try RouteStoreScenarios.routesAreSeparatePerTrip(fresh()) }

  // MARK: Schema

  func testV2SchemaAndIndex() throws {
    let store = makeStore()
    XCTAssertEqual(try store.trips(limit: 1).count, 0)
    try store.read { db in
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings", "v2_trip_points"])
      XCTAssertEqual(Set(try db.columns(in: "trip_points").map(\.name)),
                     ["id", "tripId", "seq", "timestamp", "latitude", "longitude", "accuracy"])
      let index = try XCTUnwrap(try db.indexes(on: "trip_points").first { $0.name == "trip_points_on_tripId_seq" })
      XCTAssertEqual(index.columns, ["tripId", "seq"])
      XCTAssertTrue(index.isUnique)
      let fk = try XCTUnwrap(try db.foreignKeys(on: "trip_points").first)
      XCTAssertEqual(fk.destinationTable, "trips")
    }
  }

  /// A database written by the v1 build: opening it with this build applies v2 only and keeps
  /// every trip and park; the old trips get routes from now on.
  func testMigrationV1ToV2KeepsData() throws {
    let old = try DatabaseQueue(path: databasePath, configuration: GRDBDetectionStore.configuration())
    try StoreSchema.migrator.migrate(old, upTo: "v1_trips_parkings")
    try old.write { db in
      XCTAssertFalse(try db.tableExists("trip_points"))
      try db.execute(
        sql: "INSERT INTO trips (startedAt, detectedAt, endedAt, status) VALUES (?, ?, ?, 'confirmed')",
        arguments: [StoreFixtures.date(0), StoreFixtures.date(60), StoreFixtures.date(600)])
      let trip = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO parkings (tripId, latitude, longitude, accuracy, confidence, parkedAt, fixAt)
          VALUES (?, 41.03, -39.97, 6, 'high', ?, ?)
          """,
        arguments: [trip, StoreFixtures.date(600), StoreFixtures.date(595)])
      try db.execute(sql: "INSERT INTO trips (startedAt, detectedAt) VALUES (?, ?)", arguments: [StoreFixtures.date(1000), StoreFixtures.date(1000)])
    }
    try old.close()

    let store = makeStore()
    let trips = try store.trips(limit: 10)
    XCTAssertEqual(trips.count, 2)
    let closed = try XCTUnwrap(trips.last)
    XCTAssertEqual(closed.status, .confirmed)
    XCTAssertEqual(closed.detectedAt, StoreFixtures.date(60))
    XCTAssertNil(closed.distanceMeters)
    let park = try XCTUnwrap(try store.lastParking())
    XCTAssertEqual(park.tripID, closed.id)
    XCTAssertEqual(park.latitude, 41.03)
    try store.read { db in
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings", "v2_trip_points"])
    }
    // The trip that was open in the old build records a route and gets a distance.
    let open = try XCTUnwrap(trips.first)
    try store.appendRoutePoints(RouteFixtures.straightRoute(3, from: 1000), tripID: open.id, maxPoints: 5000)
    try store.endTrip(tripID: open.id, status: .confirmed, endedAt: StoreFixtures.date(1600))
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters), 200, accuracy: 0.01)
    // New ids continue after the old ones (AUTOINCREMENT kept).
    XCTAssertGreaterThan(try store.beginTrip(startedAt: StoreFixtures.date(2000)), open.id)
  }

  func testDeletingATripCascadesToItsRoute() throws {
    let store = makeStore()
    let a = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let b = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    try store.appendRoutePoints(RouteFixtures.straightRoute(4), tripID: a, maxPoints: 5000)
    try store.appendRoutePoints(RouteFixtures.straightRoute(3, from: 1000), tripID: b, maxPoints: 5000)

    // A future "delete this trip" (or any code path) removes the route with the row.
    let other = try DatabaseQueue(path: databasePath) // GRDB default: foreign keys ON
    try other.write { db in try db.execute(sql: "DELETE FROM trips WHERE id = ?", arguments: [a]) }
    try other.close()

    XCTAssertEqual(try store.tripRoute(tripID: a), [])
    XCTAssertEqual(try store.tripRoute(tripID: b).count, 3, "other trips keep their routes")
    try store.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trip_points WHERE tripId = ?", arguments: [a]), 0)
    }
  }

  /// A relaunch during a trip: a new store instance continues the same route after the
  /// stored points (seq from the database, not from the restarted sampler).
  func testRouteContinuesAcrossRelaunch() throws {
    var store: GRDBDetectionStore? = makeStore()
    let trip = try store!.beginTrip(startedAt: StoreFixtures.date(0))
    let route = RouteFixtures.straightRoute(6)
    try store!.appendRoutePoints(Array(route[0..<3]), tripID: trip, maxPoints: 5000)
    store = nil

    let relaunched = makeStore()
    try relaunched.appendRoutePoints(Array(route[3...]), tripID: trip, maxPoints: 5000)
    XCTAssertEqual(try relaunched.tripRoute(tripID: trip), route)
    try relaunched.read { db in
      XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT seq FROM trip_points WHERE tripId = ? ORDER BY seq", arguments: [trip]),
                     [0, 1, 2, 3, 4, 5])
    }
  }

  /// Before the first unlock: route points are NOT buffered (the trip itself is, elsewhere).
  func testUnavailableDatabaseDropsRoutePoints() throws {
    struct Locked: Error {}
    var locked = false
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let relaunched = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    locked = true
    XCTAssertThrowsError(try relaunched.appendRoutePoints(RouteFixtures.straightRoute(3), tripID: trip, maxPoints: 5000)) {
      XCTAssertEqual($0 as? StoreError, .unavailable)
    }
    XCTAssertEqual(relaunched.pendingWriteCount, 0, "no route buffering")
    locked = false
    XCTAssertEqual(try relaunched.tripRoute(tripID: trip), [])
    _ = store
  }

  // MARK: Privacy

  /// "Geçmişi sil": no route coordinate byte remains in the database file or the WAL.
  func testDeleteAllHistoryLeavesNoRouteCoordinatesOnDisk() throws {
    let store = makeStore()
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = (0..<50).map {
      RoutePoint(latitude: 41.0712 + Double($0) * 0.0003, longitude: -39.9387 - Double($0) * 0.0002,
                 accuracy: 7, timestamp: StoreFixtures.date(Double($0) * 5))
    }
    for batch in stride(from: 0, to: route.count, by: 20) {
      try store.appendRoutePoints(Array(route[batch..<min(batch + 20, route.count)]), tripID: trip, maxPoints: 5000)
    }
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.deleteAllHistory()

    try store.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trip_points"), 0)
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA freelist_count"), 0)
    }
    let main = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let walURL = URL(fileURLWithPath: databasePath + "-wal")
    let wal = FileManager.default.fileExists(atPath: walURL.path) ? try Data(contentsOf: walURL) : Data()
    for point in route {
      for value in [point.latitude, point.longitude] {
        let needle = Self.bytes(of: value)
        XCTAssertNil(main.range(of: needle), "route coordinate left in the database file")
        XCTAssertNil(wal.range(of: needle), "route coordinate left in the WAL")
      }
    }
  }

  /// Points removed by thinning do not linger in the WAL or the main file.
  func testThinnedCoordinatesDoNotRemainOnDisk() throws {
    let store = makeStore()
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = (0..<11).map {
      RoutePoint(latitude: 41.0612 + Double($0) * 0.0004, longitude: -39.9512, accuracy: 7, timestamp: StoreFixtures.date(Double($0) * 5))
    }
    XCTAssertTrue(try store.appendRoutePoints(route, tripID: trip, maxPoints: 10).thinned)
    let removed = RouteThinning.positionsToRemove(count: route.count).map { route[$0].latitude }
    let main = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let walURL = URL(fileURLWithPath: databasePath + "-wal")
    let wal = FileManager.default.fileExists(atPath: walURL.path) ? try Data(contentsOf: walURL) : Data()
    for value in removed {
      XCTAssertNil(main.range(of: Self.bytes(of: value)), "thinned coordinate left in the database file")
      XCTAssertNil(wal.range(of: Self.bytes(of: value)), "thinned coordinate left in the WAL")
    }
    XCTAssertEqual(try store.tripRoute(tripID: trip).count, 6)
  }
}
