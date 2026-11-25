import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

final class GRDBDetectionStoreRuleTests: TemporaryDirectoryTestCase {
  // Each scenario on a fresh database file.
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  func testKeepsLastThree() throws { try StoreRuleScenarios.keepsLastThree(fresh()) }
  func testSameTripLowDoesNotReplaceHigh() throws { try StoreRuleScenarios.sameTripLowDoesNotReplaceHigh(fresh()) }
  func testSameTripHighReplacesLow() throws { try StoreRuleScenarios.sameTripHighReplacesLow(fresh()) }
  func testLateLowCannotDisplaceNewerHigh() throws { try StoreRuleScenarios.lateLowCannotDisplaceNewerHigh(fresh()) }
  func testNewerLowFromNewTripBecomesCurrent() throws { try StoreRuleScenarios.newerLowFromNewTripBecomesCurrent(fresh()) }
  func testUncertainTripWritesNoParking() throws { try StoreRuleScenarios.uncertainTripWritesNoParking(fresh()) }
  func testTripLifecycle() throws { try StoreRuleScenarios.tripLifecycle(fresh()) }
  func testAbandonOpenTrips() throws { try StoreRuleScenarios.abandonOpenTrips(fresh()) }
  func testTripsNewestFirstWithLimit() throws { try StoreRuleScenarios.tripsNewestFirstWithLimit(fresh()) }
  func testDeleteAllKeepsIDsIncreasing() throws { try StoreRuleScenarios.deleteAllKeepsIDsIncreasing(fresh()) }
}

final class InMemoryDetectionStoreRuleTests: XCTestCase {
  func testSameRulesAsSQLiteStore() throws {
    try StoreRuleScenarios.runAll { InMemoryDetectionStore() }
  }
}

final class GRDBDetectionStoreTests: TemporaryDirectoryTestCase {
  // MARK: Migration / file

  func testMigrationCreatesSchemaInWALMode() throws {
    let store = makeStore()
    XCTAssertFalse(store.isOpen, "opening is lazy")
    XCTAssertEqual(try store.trips(limit: 1).count, 0)
    XCTAssertTrue(store.isOpen)
    XCTAssertEqual(store.databaseURL?.lastPathComponent, "carcrumb.sqlite")

    try store.read { db in
      XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased(), "wal")
      XCTAssertTrue(try db.tableExists("trips"))
      XCTAssertTrue(try db.tableExists("parkings"))
      let tripColumns = Set(try db.columns(in: "trips").map(\.name))
      XCTAssertEqual(tripColumns, ["id", "startedAt", "detectedAt", "endedAt", "status", "distanceMeters"])
      let parkingColumns = Set(try db.columns(in: "parkings").map(\.name))
      XCTAssertEqual(parkingColumns, ["id", "tripId", "latitude", "longitude", "accuracy", "confidence", "parkedAt", "fixAt"])
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings"])
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("carcrumb.sqlite").path))
  }

  func testReopenKeepsDataAndTripIDsArePersistent() throws {
    var store: GRDBDetectionStore? = makeStore()
    let first = try store!.beginTrip(startedAt: StoreFixtures.date(0))
    try store!.endTrip(tripID: first, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store!.saveParking(StoreFixtures.park(600, .high), tripID: first)
    let open = try store!.beginTrip(startedAt: StoreFixtures.date(1000)) // id kept in state.json
    store = nil // "process death"

    let reopened = makeStore()
    // Migrations run again without effect; data is still there.
    XCTAssertEqual(try reopened.lastParking()?.tripID, first)
    // The persisted id of the open trip still addresses the same row after the relaunch.
    try reopened.endTrip(tripID: open, status: .confirmed, endedAt: StoreFixtures.date(1600))
    XCTAssertEqual(try reopened.trips(limit: 10).first { $0.id == open }?.endedAt, StoreFixtures.date(1600))
    // New ids continue after the old ones.
    XCTAssertGreaterThan(try reopened.beginTrip(startedAt: StoreFixtures.date(2000)), open)
  }

  // MARK: Database-level guard

  func testTriggerRejectsParkingForUncertainTripEvenWithoutPolicy() throws {
    let store = makeStore()
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .uncertain, endedAt: StoreFixtures.date(600))
    let dir = directory!
    let dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("carcrumb.sqlite").path)
    XCTAssertThrowsError(try dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO parkings (tripId, latitude, longitude, accuracy, confidence, parkedAt, fixAt)
          VALUES (?, 41.0, 29.0, 5, 'high', ?, ?)
          """,
        arguments: [trip, StoreFixtures.date(600), StoreFixtures.date(600)])
    })
  }

  // MARK: Locked device (before first unlock)

  func testUnavailableDatabaseDoesNotCrashAndBuffersWrites() throws {
    struct Locked: Error {}
    var locked = true
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })

    // The engine's real sequence for a trip that both began and ended while locked:
    XCTAssertThrowsError(try store.beginTrip(startedAt: StoreFixtures.date(0))) {
      XCTAssertEqual($0 as? StoreError, .unavailable)
    }
    XCTAssertThrowsError(try store.lastParking()) { XCTAssertEqual($0 as? StoreError, .unavailable) }
    // Park without a trip row (beginTrip failed) is buffered.
    XCTAssertThrowsError(try store.saveParking(StoreFixtures.park(600, .high), tripID: nil)) {
      XCTAssertEqual($0 as? StoreError, .unavailable)
    }
    XCTAssertEqual(store.pendingWriteCount, 1)
    XCTAssertFalse(store.isOpen)

    locked = false // first unlock
    // The first successful open replays the buffer before serving the call.
    XCTAssertEqual(try store.lastParking()?.parkedAt, StoreFixtures.date(600))
    XCTAssertEqual(store.pendingWriteCount, 0)
  }

  func testBufferedWritesKeepOrderAndRules() throws {
    struct Locked: Error {}
    var locked = false
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(100))
    // Simulate a store that has not opened yet in a fresh process (same file).
    let relaunched = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    locked = true
    XCTAssertThrowsError(try relaunched.refineTripStart(tripID: trip, startedAt: StoreFixtures.date(10)))
    XCTAssertThrowsError(try relaunched.endTrip(tripID: trip, status: .uncertain, endedAt: StoreFixtures.date(700)))
    // Applied after the endTrip above, so the uncertain rule rejects it at replay.
    XCTAssertThrowsError(try relaunched.saveParking(StoreFixtures.park(700, .high), tripID: trip))
    XCTAssertEqual(relaunched.pendingWriteCount, 3)

    locked = false
    let stored = try XCTUnwrap(try relaunched.trips(limit: 10).first)
    XCTAssertEqual(stored.startedAt, StoreFixtures.date(10))
    XCTAssertEqual(stored.status, .uncertain)
    XCTAssertNil(try relaunched.lastParking())
    _ = store
  }

  func testPendingBufferIsBounded() throws {
    struct Locked: Error {}
    let store = GRDBDetectionStore(directoryProvider: { throw Locked() })
    for i in 0..<(GRDBDetectionStore.maxPendingWrites + 10) {
      _ = try? store.refineTripStart(tripID: Int64(i), startedAt: StoreFixtures.date(0))
    }
    XCTAssertEqual(store.pendingWriteCount, GRDBDetectionStore.maxPendingWrites)
  }

  // MARK: History deletion

  func testDeleteAllHistoryVacuumsAndTruncatesWAL() throws {
    let store = makeStore()
    for i in 0..<20 {
      let trip = try store.beginTrip(startedAt: StoreFixtures.date(Double(i) * 1000))
      try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(Double(i) * 1000 + 600))
      try store.saveParking(StoreFixtures.park(Double(i) * 1000 + 600, .high), tripID: trip)
    }
    try store.deleteAllHistory()

    let wal = directory.appendingPathComponent("carcrumb.sqlite-wal")
    if FileManager.default.fileExists(atPath: wal.path) {
      let size = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber
      XCTAssertEqual(size?.intValue, 0, "checkpoint(TRUNCATE) leaves an empty WAL")
    }
    try store.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trips"), 0)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parkings"), 0)
      // VACUUM leaves no free pages behind.
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA freelist_count"), 0)
    }
    // No coordinate bytes of the deleted rows survive in the main file (synthetic 41.01).
    let data = try Data(contentsOf: directory.appendingPathComponent("carcrumb.sqlite"))
    var lat = 41.01.bitPattern.bigEndian // SQLite stores REAL big-endian
    let needle = Data(bytes: &lat, count: 8)
    XCTAssertNil(data.range(of: needle), "deleted coordinates must not remain in the file")
  }

  func testDeleteAllHistoryDropsBufferedWrites() throws {
    struct Locked: Error {}
    var locked = true
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    _ = try? store.saveParking(StoreFixtures.park(600, .high), tripID: nil)
    XCTAssertEqual(store.pendingWriteCount, 1)
    locked = false
    try store.deleteAllHistory()
    XCTAssertEqual(store.pendingWriteCount, 0)
    XCTAssertNil(try store.lastParking())
  }
}

final class ParkingPolicyTests: XCTestCase {
  private func stored(_ id: Int64, _ confidence: Confidence, at offset: TimeInterval, trip: Int64? = nil) -> StoredParking {
    StoredParking(id: id, tripID: trip, point: StoreFixtures.park(offset, confidence))
  }

  func testDecisions() {
    let low = StoreFixtures.park(100, .low)
    let high = StoreFixtures.park(100, .high)
    XCTAssertEqual(ParkingPolicy.decide(high, tripStatus: .uncertain, sameTrip: nil, newestHighParkedAt: nil), .reject(.rejectedUncertainTrip))
    XCTAssertEqual(ParkingPolicy.decide(low, tripStatus: .confirmed, sameTrip: stored(1, .high, at: 50, trip: 7), newestHighParkedAt: nil), .reject(.keptHigherConfidence))
    XCTAssertEqual(ParkingPolicy.decide(high, tripStatus: .confirmed, sameTrip: stored(1, .low, at: 50, trip: 7), newestHighParkedAt: nil), .replace(existingID: 1))
    XCTAssertEqual(ParkingPolicy.decide(low, tripStatus: .confirmed, sameTrip: stored(1, .low, at: 50, trip: 7), newestHighParkedAt: nil), .replace(existingID: 1))
    XCTAssertEqual(ParkingPolicy.decide(low, tripStatus: nil, sameTrip: nil, newestHighParkedAt: StoreFixtures.date(100)), .reject(.keptHigherConfidence))
    XCTAssertEqual(ParkingPolicy.decide(low, tripStatus: nil, sameTrip: nil, newestHighParkedAt: StoreFixtures.date(99)), .insert)
    XCTAssertEqual(ParkingPolicy.decide(high, tripStatus: nil, sameTrip: nil, newestHighParkedAt: StoreFixtures.date(500)), .insert)
  }

  func testOrderingPrefersNewestThenHigh() {
    XCTAssertTrue(ParkingPolicy.isNewer(stored(1, .low, at: 200), than: stored(2, .high, at: 100)))
    XCTAssertTrue(ParkingPolicy.isNewer(stored(1, .high, at: 100), than: stored(2, .low, at: 100)))
    XCTAssertTrue(ParkingPolicy.isNewer(stored(2, .low, at: 100), than: stored(1, .low, at: 100)))
  }
}
