import Foundation
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

/// Synthetic coordinates only (CLAUDE.md: 41.0±0.1 / -40.0±0.1 box, open Atlantic).
enum StoreFixtures {
  static let t0 = Date(timeIntervalSince1970: 1_790_000_000) // whole seconds: SQLite keeps ms

  static func park(_ offset: TimeInterval, _ confidence: Confidence, lat: Double = 41.01, lon: Double = -39.99) -> ParkPoint {
    let at = t0.addingTimeInterval(offset)
    return ParkPoint(
      location: LocationSample(latitude: lat, longitude: lon, accuracy: 8, speed: 0, timestamp: at.addingTimeInterval(-5)),
      confidence: confidence,
      parkedAt: at)
  }

  static func date(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }
}

/// Fresh temporary directory per test, removed in tearDown.
class TemporaryDirectoryTestCase: XCTestCase {
  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("carcrumb-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func makeStore() -> GRDBDetectionStore {
    let dir = directory!
    return GRDBDetectionStore(directoryProvider: { dir })
  }
}

/// Runs the same rule scenarios against both stores so they cannot drift apart.
enum StoreRuleScenarios {
  static func keepsLastThree(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    for i in 0..<5 {
      let trip = try store.beginTrip(startedAt: StoreFixtures.date(Double(i) * 1000))
      try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(Double(i) * 1000 + 600))
      XCTAssertEqual(try store.saveParking(StoreFixtures.park(Double(i) * 1000 + 600, .high), tripID: trip), .inserted, file: file, line: line)
    }
    let recent = try store.recentParkings()
    XCTAssertEqual(recent.map(\.parkedAt), [4600, 3600, 2600].map(StoreFixtures.date), file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.parkedAt, StoreFixtures.date(4600), file: file, line: line)
  }

  static func sameTripLowDoesNotReplaceHigh(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high, lat: 41.02), tripID: trip), .inserted, file: file, line: line)
    // Later low write for the same trip (e.g. a timeout path) must not replace the high one.
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(900, .low, lat: 41.03), tripID: trip), .keptHigherConfidence, file: file, line: line)
    let current = try XCTUnwrap(try store.lastParking(), file: file, line: line)
    XCTAssertEqual(current.confidence, .high, file: file, line: line)
    XCTAssertEqual(current.latitude, 41.02, file: file, line: line)
    XCTAssertEqual(try store.recentParkings().count, 1, file: file, line: line)
  }

  static func sameTripHighReplacesLow(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .low, lat: 41.02), tripID: trip), .inserted, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(620, .high, lat: 41.04), tripID: trip), .replaced, file: file, line: line)
    let all = try store.recentParkings()
    XCTAssertEqual(all.count, 1, file: file, line: line)
    XCTAssertEqual(all.first?.confidence, .high, file: file, line: line)
    XCTAssertEqual(all.first?.latitude, 41.04, file: file, line: line)
    XCTAssertEqual(all.first?.tripID, trip, file: file, line: line)
  }

  /// Rule 3 only applies without a trip: a trip-less low park not newer than the latest high
  /// one is rejected; a low park of another confirmed trip is a newer write and is kept.
  static func lateLowWithoutTripCannotDisplaceHigh(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: a, status: .confirmed, endedAt: StoreFixtures.date(1000))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(1000, .high, lat: 41.02), tripID: a), .inserted, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(500, .low), tripID: nil), .keptHigherConfidence, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(1000, .low), tripID: nil), .keptHigherConfidence, file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.02, file: file, line: line)
    // Sub-millisecond difference is equality at storage precision (rule 3, ms comparison).
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(1000.0004, .low), tripID: nil), .keptHigherConfidence, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(1001, .low, lat: 41.03), tripID: nil), .inserted, file: file, line: line)

    let b = try store.beginTrip(startedAt: StoreFixtures.date(100))
    try store.endTrip(tripID: b, status: .confirmed, endedAt: StoreFixtures.date(500))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(500, .low, lat: 41.04), tripID: b), .inserted, file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.04, "newest write is current", file: file, line: line)
  }

  /// Device clock jumped forward for one trip, then was corrected: write order still decides.
  static func clockSetForwardThenCorrected(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try store.beginTrip(startedAt: StoreFixtures.date(99_400))
    try store.endTrip(tripID: a, status: .confirmed, endedAt: StoreFixtures.date(100_000))
    try store.saveParking(StoreFixtures.park(100_000, .high, lat: 41.02), tripID: a) // clock ~1 day ahead
    let b = try store.beginTrip(startedAt: StoreFixtures.date(4_400))
    try store.endTrip(tripID: b, status: .confirmed, endedAt: StoreFixtures.date(5_000))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(5_000, .low, lat: 41.03), tripID: b), .inserted,
                   "a low park of a newer trip is not blocked by a future-dated high one", file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.03, file: file, line: line)
    // Two more parks: pruning drops the future-dated one, the oldest write.
    for (offset, lat) in [(6_000.0, 41.05), (7_000.0, 41.06)] {
      let t = try store.beginTrip(startedAt: StoreFixtures.date(offset - 600))
      try store.endTrip(tripID: t, status: .confirmed, endedAt: StoreFixtures.date(offset))
      try store.saveParking(StoreFixtures.park(offset, .high, lat: lat), tripID: t)
    }
    XCTAssertEqual(try store.recentParkings().map(\.latitude), [41.06, 41.05, 41.03], file: file, line: line)
  }

  /// A park attached to a trip that is later abandoned (closed `uncertain`) is kept but
  /// detached: an uncertain trip has no park.
  static func abandonDetachesParking(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let open = try store.beginTrip(startedAt: StoreFixtures.date(0)) // its endTrip was lost
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high), tripID: open), .inserted, file: file, line: line)
    try store.abandonOpenTrips(except: nil)
    XCTAssertEqual(try store.trips(limit: 10).first?.status, .uncertain, file: file, line: line)
    let park = try XCTUnwrap(try store.lastParking(), file: file, line: line)
    XCTAssertNil(park.tripID, file: file, line: line)
  }

  /// `saveClosedTrip` with the database available: a closed trip row, and its park links to it.
  static func closedTripLinksParking(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let id = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(0), detectedAt: StoreFixtures.date(0), endedAt: StoreFixtures.date(600), status: .confirmed)
    XCTAssertGreaterThan(id, 0, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high), tripID: id), .inserted, file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.tripID, id, file: file, line: line)
    let trip = try XCTUnwrap(try store.trips(limit: 1).first, file: file, line: line)
    XCTAssertEqual(trip.status, .confirmed, file: file, line: line)
    XCTAssertEqual(trip.endedAt, StoreFixtures.date(600), file: file, line: line)

    let uncertain = try store.saveClosedTrip(
      startedAt: StoreFixtures.date(1000), detectedAt: StoreFixtures.date(1000), endedAt: StoreFixtures.date(1600), status: .uncertain)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(1600, .high), tripID: uncertain), .rejectedUncertainTrip, file: file, line: line)
  }

  static func newerLowFromNewTripBecomesCurrent(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: a, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.saveParking(StoreFixtures.park(600, .high, lat: 41.02), tripID: a)
    let b = try store.beginTrip(startedAt: StoreFixtures.date(5000))
    try store.endTrip(tripID: b, status: .confirmed, endedAt: StoreFixtures.date(5600))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(5600, .low, lat: 41.05), tripID: b), .inserted, file: file, line: line)
    // The car drove away from the high point, so the newer (low) park is current; the high
    // one stays available as an alternative.
    let recent = try store.recentParkings()
    XCTAssertEqual(recent.map(\.confidence), [.low, .high], file: file, line: line)
    XCTAssertEqual(try store.lastParking()?.latitude, 41.05, file: file, line: line)
  }

  static func uncertainTripWritesNoParking(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .uncertain, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .high), tripID: trip), .rejectedUncertainTrip, file: file, line: line)
    XCTAssertEqual(try store.saveParking(StoreFixtures.park(600, .low), tripID: trip), .rejectedUncertainTrip, file: file, line: line)
    XCTAssertNil(try store.lastParking(), file: file, line: line)
  }

  static func tripLifecycle(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(300))
    try store.refineTripStart(tripID: trip, startedAt: StoreFixtures.date(100))
    try store.refineTripStart(tripID: trip, startedAt: StoreFixtures.date(200)) // later: ignored
    try store.refineTripStart(tripID: 999_999, startedAt: StoreFixtures.date(0)) // unknown: ignored
    var open = try XCTUnwrap(try store.trips(limit: 10).first, file: file, line: line)
    XCTAssertNil(open.status, file: file, line: line)
    XCTAssertNil(open.endedAt, file: file, line: line)
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(900))
    open = try XCTUnwrap(try store.trips(limit: 10).first, file: file, line: line)
    XCTAssertEqual(open.startedAt, StoreFixtures.date(100), file: file, line: line)
    XCTAssertEqual(open.detectedAt, StoreFixtures.date(300), file: file, line: line)
    XCTAssertEqual(open.endedAt, StoreFixtures.date(900), file: file, line: line)
    XCTAssertEqual(open.status, .confirmed, file: file, line: line)
    XCTAssertNil(open.distanceMeters, file: file, line: line)
  }

  static func abandonOpenTrips(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let orphan = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let current = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    try store.abandonOpenTrips(except: current)
    let trips = try store.trips(limit: 10)
    let o = try XCTUnwrap(trips.first { $0.id == orphan }, file: file, line: line)
    let c = try XCTUnwrap(trips.first { $0.id == current }, file: file, line: line)
    XCTAssertEqual(o.status, .uncertain, file: file, line: line)
    XCTAssertEqual(o.endedAt, StoreFixtures.date(0), file: file, line: line)
    XCTAssertNil(c.status, file: file, line: line)
    try store.abandonOpenTrips(except: nil)
    XCTAssertEqual(try store.trips(limit: 10).first { $0.id == current }?.status, .uncertain, file: file, line: line)
  }

  static func tripsNewestFirstWithLimit(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let ids = try (0..<4).map { try store.beginTrip(startedAt: StoreFixtures.date(Double($0) * 100)) }
    XCTAssertEqual(try store.trips(limit: 2).map(\.id), [ids[3], ids[2]], file: file, line: line)
    XCTAssertEqual(try store.trips(limit: 0).count, 0, file: file, line: line)
  }

  static func deleteAllKeepsIDsIncreasing(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    try store.saveParking(StoreFixtures.park(600, .high), tripID: trip)
    try store.deleteAllHistory()
    XCTAssertEqual(try store.trips(limit: 10).count, 0, file: file, line: line)
    XCTAssertNil(try store.lastParking(), file: file, line: line)
    // Ids are never reused: a stale id from before the deletion cannot hit a new trip.
    let next = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    XCTAssertGreaterThan(next, trip, file: file, line: line)
    try store.endTrip(tripID: trip, status: .uncertain, endedAt: StoreFixtures.date(2000)) // stale: no-op
    XCTAssertNil(try store.trips(limit: 10).first?.status, file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try keepsLastThree(make())
    try sameTripLowDoesNotReplaceHigh(make())
    try sameTripHighReplacesLow(make())
    try lateLowWithoutTripCannotDisplaceHigh(make())
    try clockSetForwardThenCorrected(make())
    try abandonDetachesParking(make())
    try closedTripLinksParking(make())
    try newerLowFromNewTripBecomesCurrent(make())
    try uncertainTripWritesNoParking(make())
    try tripLifecycle(make())
    try abandonOpenTrips(make())
    try tripsNewestFirstWithLimit(make())
    try deleteAllKeepsIDsIncreasing(make())
  }
}
