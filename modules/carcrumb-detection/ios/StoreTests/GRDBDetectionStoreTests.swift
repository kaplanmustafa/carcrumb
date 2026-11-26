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
  func testLateLowWithoutTripCannotDisplaceHigh() throws { try StoreRuleScenarios.lateLowWithoutTripCannotDisplaceHigh(fresh()) }
  func testClockSetForwardThenCorrected() throws { try StoreRuleScenarios.clockSetForwardThenCorrected(fresh()) }
  func testAbandonDetachesParking() throws { try StoreRuleScenarios.abandonDetachesParking(fresh()) }
  func testClosedTripLinksParking() throws { try StoreRuleScenarios.closedTripLinksParking(fresh()) }
  func testNewerLowFromNewTripBecomesCurrent() throws { try StoreRuleScenarios.newerLowFromNewTripBecomesCurrent(fresh()) }
  func testUncertainTripWritesNoParking() throws { try StoreRuleScenarios.uncertainTripWritesNoParking(fresh()) }
  func testTripLifecycle() throws { try StoreRuleScenarios.tripLifecycle(fresh()) }
  func testAbandonOpenTrips() throws { try StoreRuleScenarios.abandonOpenTrips(fresh()) }
  func testTripsNewestFirstWithLimit() throws { try StoreRuleScenarios.tripsNewestFirstWithLimit(fresh()) }
  func testTripsFollowWriteOrderAcrossClockChange() throws {
    try StoreRuleScenarios.tripsFollowWriteOrderAcrossClockChange(fresh())
  }
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
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings", "v2_trip_points"])
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
          VALUES (?, 41.0, -40.0, 5, 'high', ?, ?)
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

  /// Reviewer finding 1: trip begun AND ended before the first unlock. The engine calls
  /// `saveClosedTrip` (provisional id) and `saveParking` with that id; both are buffered and
  /// the park is linked to the real trip row at replay.
  func testTripAndParkWhileLockedAreLinkedAtReplay() throws {
    struct Locked: Error {}
    var locked = true
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    XCTAssertThrowsError(try store.beginTrip(startedAt: StoreFixtures.date(0)))
    let provisional = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(0), detectedAt: StoreFixtures.date(0), endedAt: StoreFixtures.date(600), status: .confirmed)
    XCTAssertLessThan(provisional, 0, "provisional id while locked")
    XCTAssertThrowsError(try store.saveParking(StoreFixtures.park(600, .high), tripID: provisional)) {
      XCTAssertEqual($0 as? StoreError, .unavailable)
    }
    XCTAssertEqual(store.pendingWriteCount, 2)

    locked = false
    let trip = try XCTUnwrap(try store.trips(limit: 10).first)
    XCTAssertGreaterThan(trip.id, 0)
    XCTAssertEqual(trip.status, .confirmed)
    XCTAssertEqual(trip.startedAt, StoreFixtures.date(0))
    XCTAssertEqual(trip.endedAt, StoreFixtures.date(600))
    XCTAssertEqual(try store.lastParking()?.tripID, trip.id, "park linked to the replayed trip row")
    XCTAssertEqual(store.pendingWriteCount, 0)
  }

  /// Same, but the trip was uncertain: the replayed park is rejected (rule 1).
  func testUncertainTripWhileLockedRejectsParkAtReplay() throws {
    struct Locked: Error {}
    var locked = true
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    let provisional = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(0), detectedAt: StoreFixtures.date(0), endedAt: StoreFixtures.date(600), status: .uncertain)
    XCTAssertThrowsError(try store.saveParking(StoreFixtures.park(600, .high), tripID: provisional))
    locked = false
    XCTAssertEqual(try store.trips(limit: 10).first?.status, .uncertain)
    XCTAssertNil(try store.lastParking())
  }

  /// The database opens between `saveClosedTrip` (buffered) and `saveParking` (live): the open
  /// replays the trip first, and the live park still resolves the provisional id.
  func testProvisionalIDResolvesAfterOpenInSameBatch() throws {
    struct Locked: Error {}
    var locked = true
    let dir = directory!
    let store = GRDBDetectionStore(directoryProvider: {
      if locked { throw Locked() }
      return dir
    })
    let provisional = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(0), detectedAt: StoreFixtures.date(0), endedAt: StoreFixtures.date(600), status: .confirmed)
    locked = false
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high), tripID: provisional), .inserted)
    let tripID = try XCTUnwrap(try store.trips(limit: 1).first?.id)
    XCTAssertEqual(try store.lastParking()?.tripID, tripID)
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

  /// Security k2: a park removed by the "last 3" pruning (or a same-trip replace) must not
  /// survive in the WAL (nor in the main file: secure_delete).
  func testPrunedAndReplacedCoordinatesDoNotRemainOnDisk() throws {
    let store = makeStore()
    let pruned = 41.0123
    let replaced = 41.0456
    // Same-trip replace: low at `replaced`, then high elsewhere.
    let first = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: first, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.saveParking(StoreFixtures.park(600, .low, lat: replaced), tripID: first)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(610, .high, lat: pruned), tripID: first), .replaced)
    // Three newer parks prune the `pruned` one.
    for (offset, lat) in [(2_000.0, 41.02), (3_000.0, 41.03), (4_000.0, 41.04)] {
      let t = try store.beginTrip(startedAt: StoreFixtures.date(offset - 600))
      try store.endTrip(tripID: t, status: .confirmed, endedAt: StoreFixtures.date(offset))
      XCTAssertEqual(try store.saveParking(StoreFixtures.park(offset, .high, lat: lat), tripID: t), .inserted)
    }
    XCTAssertEqual(try store.recentParkings().map(\.latitude), [41.04, 41.03, 41.02])

    let wal = directory.appendingPathComponent("carcrumb.sqlite-wal")
    let main = directory.appendingPathComponent("carcrumb.sqlite")
    for value in [pruned, replaced] {
      var bits = value.bitPattern.bigEndian // SQLite stores REAL big-endian
      let needle = Data(bytes: &bits, count: 8)
      if FileManager.default.fileExists(atPath: wal.path) {
        XCTAssertNil(try Data(contentsOf: wal).range(of: needle), "removed coordinate left in the WAL")
      }
      XCTAssertNil(try Data(contentsOf: main).range(of: needle), "removed coordinate left in the database file")
    }
    try store.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA journal_size_limit"), 0)
    }
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
    let decide = ParkingPolicy.decide
    XCTAssertEqual(decide(high, 7, .uncertain, nil, nil), .reject(.rejectedUncertainTrip))
    XCTAssertEqual(decide(low, 7, .confirmed, stored(1, .high, at: 50, trip: 7), nil), .reject(.keptHigherConfidence))
    XCTAssertEqual(decide(high, 7, .confirmed, stored(1, .low, at: 50, trip: 7), nil), .replace(existingID: 1))
    XCTAssertEqual(decide(low, 7, .confirmed, stored(1, .low, at: 50, trip: 7), nil), .replace(existingID: 1))
    // Rule 3: only without a trip.
    XCTAssertEqual(decide(low, nil, nil, nil, stored(2, .high, at: 100)), .reject(.keptHigherConfidence))
    XCTAssertEqual(decide(low, nil, nil, nil, stored(2, .high, at: 99)), .insert)
    XCTAssertEqual(decide(low, 7, .confirmed, nil, stored(2, .high, at: 500)), .insert, "another trip's low park is a newer write")
    XCTAssertEqual(decide(high, nil, nil, nil, stored(2, .high, at: 500)), .insert)
  }

  func testRule3ComparesAtMillisecondPrecision() {
    let decide = ParkingPolicy.decide
    // 0.4 ms later is "equal" at storage precision → rejected; 1 ms later → newer.
    XCTAssertEqual(decide(StoreFixtures.park(100.0004, .low), nil, nil, nil, stored(2, .high, at: 100)), .reject(.keptHigherConfidence))
    XCTAssertEqual(decide(StoreFixtures.park(100.001, .low), nil, nil, nil, stored(2, .high, at: 100)), .insert)
    XCTAssertEqual(ParkingPolicy.milliseconds(StoreFixtures.date(100)), ParkingPolicy.milliseconds(StoreFixtures.date(100.0009)))
  }

  func testOrderingIsWriteOrder() {
    XCTAssertTrue(ParkingPolicy.isNewer(stored(2, .low, at: 100), than: stored(1, .high, at: 200)), "id, not parkedAt")
    XCTAssertTrue(ParkingPolicy.isNewer(stored(2, .low, at: 100), than: stored(1, .high, at: 100)), "id, not confidence")
    XCTAssertFalse(ParkingPolicy.isNewer(stored(1, .high, at: 900), than: stored(2, .low, at: 100)))
  }
}
