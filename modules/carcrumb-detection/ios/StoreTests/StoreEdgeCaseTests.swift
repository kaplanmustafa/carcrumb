import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

// QA edge cases for the store rules (docs/DECISIONS.md, "Hata dengesi" and
// "Geçmişi silme kontrol listesi"). Runs only on macOS CI (`swift test`).
//
// No open known gaps: the clock-change and pruned-insert gaps were fixed (write-order rules)
// and their tests now assert directly. A new gap would use strict `XCTExpectFailure`.

/// Same scenarios against both stores (SQL ordering must match `ParkingPolicy.isNewer`).
enum StoreEdgeScenarios {
  private static func confirmedTrip(_ store: DetectionStore, at offset: TimeInterval) throws -> Int64 {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(offset - 600))
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(offset))
    return trip
  }

  /// Parks with the same `parkedAt` from different trips: order is write order (the newer row
  /// is current, whatever the confidence); a tied trip-less low is rejected (rule 3).
  static func equalParkedAtTies(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try confirmedTrip(store, at: 600)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high, lat: 41.02), tripID: a), .inserted, file: file, line: line)
    let b = try confirmedTrip(store, at: 600)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .low, lat: 41.03), tripID: b), .inserted,
                   "another confirmed trip's low park is a newer write (rule 3 is trip-less only)", file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.03, "tie on parkedAt: newer row first, even if low", file: file, line: line)

    let c = try confirmedTrip(store, at: 600)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high, lat: 41.04), tripID: c), .inserted, file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.04, "tie on parkedAt and confidence: newer row first", file: file, line: line)
    XCTAssertEqual(try store.recentParkings().map(\.latitude), [41.04, 41.03, 41.02], file: file, line: line)

    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .low, lat: 41.05), tripID: nil), .keptHigherConfidence,
                   "trip-less low with parkedAt equal to the latest high is rejected (rule 3)", file: file, line: line)
    XCTAssertEqual(try store.recentParkings().map(\.latitude), [41.04, 41.03, 41.02], file: file, line: line)
  }

  /// Pruning keeps the newest 3 by write order (row id), not by `parkedAt` (the device clock
  /// can jump); across trips a newer low may push an older high out (by design).
  static func pruningIsByWriteOrder(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    for offset in [3000.0, 1000, 2000] {
      try store.saveParking(StoreFixtures.park(offset, .high), tripID: try confirmedTrip(store, at: offset))
    }
    try store.saveParking(StoreFixtures.park(4000, .high), tripID: try confirmedTrip(store, at: 4000))
    XCTAssertEqual(try store.recentParkings().map(\.parkedAt), [4000, 2000, 1000].map(StoreFixtures.date),
                   "the 4th park evicts the first written (3000), not the oldest by parkedAt (1000)", file: file, line: line)

    for offset in [5000.0, 6000, 7000] {
      XCTAssertEqual(try store.saveParking(StoreFixtures.park(offset, .low), tripID: try confirmedTrip(store, at: offset)),
                     .inserted, file: file, line: line)
    }
    let recent = try store.recentParkings()
    XCTAssertEqual(recent.map(\.parkedAt), [7000, 6000, 5000].map(StoreFixtures.date), file: file, line: line)
    XCTAssertEqual(recent.map(\.confidence), [.low, .low, .low], file: file, line: line)
  }

  /// "Geçmişi silme" while a trip is open (engine resets to IDLE, but in-flight calls with the
  /// old id can still arrive, e.g. a Core Motion refinement completion).
  static func deleteWhileTripOpen(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let open = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.deleteAllHistory()

    try store.refineTripStart(tripID: open, startedAt: StoreFixtures.date(-300))
    try store.endTrip(tripID: open, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.abandonOpenTrips(except: open)
    try store.abandonOpenTrips(except: nil)
    XCTAssertEqual(try store.trips(limit: 10).count, 0, "no deleted trip is resurrected", file: file, line: line)

    if try store.saveParking(StoreFixtures.park(600, .high), tripID: open).wasWritten {
      XCTAssertNil(try store.lastParking()?.tripID, "a stale trip id must not become a trip reference", file: file, line: line)
    }
    XCTAssertEqual(try store.trips(limit: 10).count, 0, file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try equalParkedAtTies(make())
    try pruningIsByWriteOrder(make())
    try deleteWhileTripOpen(make())
  }
}

final class GRDBStoreEdgeCaseTests: TemporaryDirectoryTestCase {
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  func testEqualParkedAtTies() throws { try StoreEdgeScenarios.equalParkedAtTies(fresh()) }
  func testPruningIsByWriteOrder() throws { try StoreEdgeScenarios.pruningIsByWriteOrder(fresh()) }
  func testDeleteWhileTripOpen() throws { try StoreEdgeScenarios.deleteWhileTripOpen(fresh()) }

  // MARK: Migration

  /// Migrator run again on an already migrated file (every launch does this) and a second
  /// time on the same connection: no error, nothing re-applied, data and id sequence kept.
  func testMigrationRunsTwiceWithoutEffect() throws {
    let store = makeStore()
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.saveParking(StoreFixtures.park(600, .high), tripID: trip)

    let path = directory.appendingPathComponent(GRDBDetectionStore.fileName).path
    let other = try DatabaseQueue(path: path)
    try StoreSchema.migrator.migrate(other)
    try StoreSchema.migrator.migrate(other)
    try other.read { db in
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings", "v2_trip_points"])
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trips"), 1)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parkings"), 1)
      XCTAssertTrue(try StoreSchema.migrator.hasCompletedMigrations(db))
    }
    try other.close()

    let reopened = makeStore()
    XCTAssertEqual(try reopened.lastParking()?.tripID, trip)
    XCTAssertGreaterThan(try reopened.beginTrip(startedAt: StoreFixtures.date(1000)), trip)
    try reopened.read { db in
      XCTAssertEqual(try StoreSchema.migrator.appliedIdentifiers(db), ["v1_trips_parkings", "v2_trip_points"])
    }
  }

  // MARK: Buffer overflow (locked device)

  /// More than `maxPendingWrites` buffered writes: the OLDEST are dropped, the rest replay in
  /// order. Documents the consequence: a dropped `endTrip` leaves the trip open (it is closed
  /// as `uncertain` by `abandonOpenTrips` at a later launch).
  func testBufferOverflowDropsOldestAndReplaysRestInOrder() throws {
    struct Locked: Error {}
    var locked = false
    let dir = directory!
    let provider: () throws -> URL = {
      if locked { throw Locked() }
      return dir
    }
    let trip = try GRDBDetectionStore(directoryProvider: provider).beginTrip(startedAt: StoreFixtures.date(0))

    let relaunched = GRDBDetectionStore(directoryProvider: provider)
    locked = true
    XCTAssertThrowsError(try relaunched.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600)))
    for i in 0..<(GRDBDetectionStore.maxPendingWrites - 1) {
      _ = try? relaunched.refineTripStart(tripID: 1_000_000 + Int64(i), startedAt: StoreFixtures.date(0)) // no-ops
    }
    XCTAssertThrowsError(try relaunched.saveParking(StoreFixtures.park(900, .high), tripID: nil))
    XCTAssertEqual(relaunched.pendingWriteCount, GRDBDetectionStore.maxPendingWrites)

    locked = false
    XCTAssertEqual(try relaunched.lastParking()?.parkedAt, StoreFixtures.date(900), "newest write kept")
    let stored = try XCTUnwrap(try relaunched.trips(limit: 10).first { $0.id == trip })
    XCTAssertNil(stored.status, "oldest write (endTrip) dropped")
    XCTAssertEqual(relaunched.pendingWriteCount, 0)
  }

  // MARK: Clock changes (formerly known gaps, fixed: order is write order)

  /// The device clock goes back (manual change / wrong RTC after reboot) between two trips.
  /// The newest written confirmed park gets an older `parkedAt` and is still "current":
  /// DECISIONS "en son park = en yeni onaylı kayıt".
  func testClockSetBackNewestWrittenParkIsCurrent() throws {
    let store = makeStore()
    let a = try store.beginTrip(startedAt: StoreFixtures.date(9_400))
    try store.endTrip(tripID: a, status: .confirmed, endedAt: StoreFixtures.date(10_000))
    try store.saveParking(StoreFixtures.park(10_000, .high, lat: 41.02), tripID: a)
    // Clock moved back ~1.4 h; the user drives again and parks elsewhere.
    let b = try store.beginTrip(startedAt: StoreFixtures.date(4_400))
    try store.endTrip(tripID: b, status: .confirmed, endedAt: StoreFixtures.date(5_000))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(5_000, .high, lat: 41.03), tripID: b), .inserted)

    XCTAssertEqual(try store.lastParking()?.latitude, 41.03)
  }

  /// The device clock is ahead (wrong time) for one trip and corrected before the next:
  /// the future-dated park neither stays "current" nor blocks the next one.
  func testClockSetForwardNewestWrittenParkIsCurrent() throws {
    let store = makeStore()
    let a = try store.beginTrip(startedAt: StoreFixtures.date(86_400 + 9_400))
    try store.endTrip(tripID: a, status: .confirmed, endedAt: StoreFixtures.date(86_400 + 10_000))
    try store.saveParking(StoreFixtures.park(86_400 + 10_000, .high, lat: 41.02), tripID: a) // clock 1 day ahead
    // Clock corrected; the user drives again and parks elsewhere (low confidence).
    let b = try store.beginTrip(startedAt: StoreFixtures.date(9_400))
    try store.endTrip(tripID: b, status: .confirmed, endedAt: StoreFixtures.date(10_000))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(10_000, .low, lat: 41.03), tripID: b), .inserted)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.03)
    XCTAssertEqual(try store.recentParkings().map(\.latitude), [41.03, 41.02])
  }

  /// A park older (by `parkedAt`) than the 3 kept ones used to be inserted and pruned in the
  /// same transaction yet reported as `.inserted`. With write-order pruning a new row is always
  /// kept; the store also checks the row after pruning. Outcome and stored data must agree.
  func testInsertedOutcomeMeansParkIsStored() throws {
    let store = makeStore()
    for offset in [10_000.0, 11_000, 12_000] {
      let t = try store.beginTrip(startedAt: StoreFixtures.date(offset - 600))
      try store.endTrip(tripID: t, status: .confirmed, endedAt: StoreFixtures.date(offset))
      try store.saveParking(StoreFixtures.park(offset, .high), tripID: t)
    }
    let late = try store.beginTrip(startedAt: StoreFixtures.date(4_400))
    try store.endTrip(tripID: late, status: .confirmed, endedAt: StoreFixtures.date(5_000))
    let outcome = try store.saveParking(StoreFixtures.park(5_000, .high, lat: 41.06), tripID: late)
    let stored = try store.recentParkings().contains { $0.tripID == late }

    XCTAssertEqual(try store.recentParkings().count, 3)
    XCTAssertEqual(outcome, .inserted)
    XCTAssertEqual(outcome.wasWritten, stored)
    XCTAssertEqual(try store.lastParking()?.tripID, late, "newest write is current despite the older parkedAt")
  }
}

final class InMemoryStoreEdgeCaseTests: XCTestCase {
  func testSameEdgeCasesAsSQLiteStore() throws {
    try StoreEdgeScenarios.runAll { InMemoryDetectionStore() }
  }
}
