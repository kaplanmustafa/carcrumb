import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

// QA edge cases for route recording (docs/DECISIONS.md "Rota kaydı"). Runs only on macOS CI
// (`swift test`). Synthetic coordinates only (RouteFixtures: 41.0 / -40.0 + a few km north).
//
// Tests using XCTExpectFailure document known gaps (strict: they turn red once fixed — then
// drop the wrapper and keep the assertions).

/// Mirrors `DetectionEngine.reduceAndApply` + `recordRoute`: reduce, apply beginTrip/endTrip to
/// the sampler, then offer a location fix only if the state AFTER reducing it is DRIVING.
private struct EngineRouteMirror {
  var reducer = DetectionReducer()
  var state = DetectionState.idle
  var sampler = RouteSampler()
  var kept: [TimeInterval] = []

  mutating func send(_ offset: TimeInterval, _ event: DetectionEvent) {
    let (next, effects) = reducer.reduce(state, event, now: StoreFixtures.date(offset))
    state = next
    for effect in effects {
      switch effect {
      case .beginTrip: sampler.begin(tripID: 1)
      case .endTrip: sampler.reset()
      default: break
      }
    }
    if case let .location(sample) = event, case .driving = state, sampler.offer(sample, driving: true) {
      kept.append(sample.timestamp.timeIntervalSince(StoreFixtures.t0))
    }
  }
}

final class RouteEngineMirrorTests: XCTestCase {
  /// Traffic with a spurious walking report: walking-speed fixes in MAYBE_PARKED are not route
  /// points; the vehicle-speed fix that sends the reducer back to DRIVING is.
  func testMaybeParkedBackToDrivingKeepsTheVehicleFixOnly() {
    var m = EngineRouteMirror()
    m.send(0, .wake(.significantLocationChange))
    m.send(1, .carLink(connected: true))
    m.send(10, .location(RouteFixtures.sample(north: 0, at: 10, speed: 12)))   // confirms DRIVING, begins trip
    m.send(30, .location(RouteFixtures.sample(north: 300, at: 30, speed: 12)))
    m.send(40, .motion(.walking))                                                // spurious, car link on
    XCTAssertEqual(m.state.name, "MAYBE_PARKED")
    m.send(60, .location(RouteFixtures.sample(north: 340, at: 60, speed: 2)))   // creeping: MAYBE_PARKED
    XCTAssertEqual(m.state.name, "MAYBE_PARKED")
    m.send(80, .location(RouteFixtures.sample(north: 500, at: 80, speed: 8)))   // back to DRIVING
    XCTAssertEqual(m.state.name, "DRIVING")
    m.send(100, .location(RouteFixtures.sample(north: 700, at: 100, speed: 12)))

    XCTAssertEqual(m.kept, [10, 30, 80, 100], "the confirming fix and the resuming fix are route points; the creeping one is not")
    XCTAssertEqual(m.sampler.tripID, 1, "same trip, no new beginTrip")
  }

  /// Back to DRIVING through Core Motion `automotive`: following vehicle fixes are recorded,
  /// walking-speed fixes still are not (also in DRIVING).
  func testAutomotiveResumeAndWalkingSpeedInDriving() {
    var m = EngineRouteMirror()
    m.send(0, .carLink(connected: true))
    m.send(10, .location(RouteFixtures.sample(north: 0, at: 10, speed: 12)))
    m.send(20, .motion(.walking))
    m.send(30, .location(RouteFixtures.sample(north: 20, at: 30, speed: 1.3)))  // MAYBE_PARKED: no
    m.send(40, .motion(.automotive))
    XCTAssertEqual(m.state.name, "DRIVING")
    m.send(50, .location(RouteFixtures.sample(north: 40, at: 50, speed: 1.3)))  // DRIVING, walking speed: no
    m.send(60, .location(RouteFixtures.sample(north: 200, at: 60, speed: 9)))
    XCTAssertEqual(m.kept, [10, 60])
  }

  /// The real park ends the trip: no fix after it is a route point, and the next trip starts clean.
  func testParkEndsRecording() {
    var m = EngineRouteMirror()
    m.send(0, .carLink(connected: true))
    m.send(10, .location(RouteFixtures.sample(north: 0, at: 10, speed: 12)))
    m.send(598, .location(RouteFixtures.sample(north: 3000, at: 598, speed: 2)))
    m.send(600, .location(RouteFixtures.sample(north: 3001, at: 600, speed: 0)))
    m.send(602, .carLink(connected: false))
    m.send(605, .motion(.walking))
    m.send(660, .location(RouteFixtures.sample(north: 3060, at: 660, speed: 1.2)))
    XCTAssertEqual(m.state.name, "PARKED")
    XCTAssertNil(m.sampler.tripID)
    XCTAssertEqual(m.kept, [10], "stop and walk fixes are below vehicle speed")
  }
}

final class RouteSamplerClockTests: XCTestCase {
  private func sampler() -> RouteSampler {
    var s = RouteSampler()
    s.begin(tripID: 1)
    return s
  }

  /// A small backwards correction (NTP) only costs the corrected seconds.
  func testSmallClockCorrectionLosesOnlyThoseSeconds() {
    var s = sampler()
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 100), driving: true))
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 200, at: 98), driving: true), "2 s back: older than the last kept fix")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 400, at: 101), driving: true))
  }

  /// Clock set back 1 h while driving (manual change / wrong RTC corrected): every new fix
  /// is "older than the last kept point", so the route stops for the next hour of driving.
  func testClockSetBackOneHourKeepsRecording() {
    var s = sampler()
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 3_600), driving: true))
    var accepted = 0
    for i in 1...60 { // 10 min of driving after the jump, 150 m every 10 s
      let offset = Double(i) * 10
      if s.offer(RouteFixtures.sample(north: Double(i) * 150, at: offset), driving: true) { accepted += 1 }
    }
    XCTExpectFailure("KNOWN GAP (RouteSampler): rule 4 drops every fix after a backwards clock jump") {
      XCTAssertGreaterThan(accepted, 0)
    }
  }

  /// `shouldFlush` doc: "the age uses fix timestamps when `now` is earlier". With the engine
  /// clock behind the fixes and fewer than `flushBatchSize` points spanning > 60 s, it should
  /// flush (otherwise a jetsam loses more than a minute); the code only compares with `now`.
  func testAgeFlushWhenEngineClockIsBehindTheFixes() {
    var s = sampler()
    for i in 0..<4 {
      XCTAssertTrue(s.offer(RouteFixtures.sample(north: Double(i) * 300, at: Double(i) * 30), driving: true))
    }
    XCTAssertEqual(s.pending.count, 4)
    XCTAssertTrue(s.shouldFlush(now: StoreFixtures.date(90)), "engine clock in step: 90 s old")
    let behind = s.shouldFlush(now: StoreFixtures.date(-5_000))
    XCTExpectFailure("KNOWN GAP (RouteSampler.shouldFlush): implementation does not match its doc comment") {
      XCTAssertTrue(behind)
    }
  }
}

/// Same scenarios against both stores.
enum RouteEdgeScenarios {
  /// One append far above the cap is thinned until it fits (more than one halving), but the
  /// result only says `thinned: true` once, so the engine doubles the sampler spacing once.
  static func appendFarAboveCap(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = RouteFixtures.straightRoute(25)
    let result = try store.appendRoutePoints(route, tripID: trip, maxPoints: 10)
    XCTAssertEqual(result, RouteAppendResult(storedCount: 7, thinned: true), "25 → 13 → 7", file: file, line: line)
    let stored = try store.tripRoute(tripID: trip)
    XCTAssertEqual(stored.first, route.first, file: file, line: line)
    XCTAssertEqual(stored.last, route.last, file: file, line: line)
    XCTAssertEqual(stored.map(\.timestamp), stored.map(\.timestamp).sorted(), "route order kept", file: file, line: line)
  }

  /// Thinning, then history deletion, then the engine's stale trip id: nothing is written,
  /// and a new trip's route starts from scratch.
  static func thinThenDeleteThenStaleAppend(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    XCTAssertTrue(try store.appendRoutePoints(RouteFixtures.straightRoute(15), tripID: trip, maxPoints: 10).thinned, file: file, line: line)
    try store.deleteAllHistory()
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(15, from: 200), tripID: trip, maxPoints: 10),
                   RouteAppendResult(storedCount: 0, thinned: false), file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: trip), [], file: file, line: line)

    let next = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    let route = RouteFixtures.straightRoute(3, from: 1000)
    try store.appendRoutePoints(route, tripID: next, maxPoints: 10)
    XCTAssertEqual(try store.tripRoute(tripID: next), route, file: file, line: line)
  }

  /// A trip closed as uncertain keeps its route and distance (route ≠ park).
  static func uncertainTripKeepsRoute(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.appendRoutePoints(RouteFixtures.straightRoute(4), tripID: trip, maxPoints: 5000)
    try store.endTrip(tripID: trip, status: .uncertain, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try store.tripRoute(tripID: trip).count, 4, file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line), 300, accuracy: 0.01,
                   file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try appendFarAboveCap(make())
    try thinThenDeleteThenStaleAppend(make())
    try uncertainTripKeepsRoute(make())
  }
}

final class InMemoryRouteEdgeCaseTests: XCTestCase {
  func testSameEdgeCasesAsSQLiteStore() throws {
    try RouteEdgeScenarios.runAll { InMemoryDetectionStore() }
  }
}

final class GRDBRouteEdgeCaseTests: TemporaryDirectoryTestCase {
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  func testAppendFarAboveCap() throws { try RouteEdgeScenarios.appendFarAboveCap(fresh()) }
  func testThinThenDeleteThenStaleAppend() throws { try RouteEdgeScenarios.thinThenDeleteThenStaleAppend(fresh()) }
  func testUncertainTripKeepsRoute() throws { try RouteEdgeScenarios.uncertainTripKeepsRoute(fresh()) }

  /// Relaunch in the middle of a trip, the engine's way: a new store on the same file and a
  /// restored sampler (`begin(tripID:)`, pending points of the dead process lost). The route
  /// continues with contiguous `seq`, in time order, and the distance covers both parts.
  func testRelaunchWithRestoredSamplerContinuesRoute() throws {
    var store: GRDBDetectionStore? = makeStore()
    let trip = try store!.beginTrip(startedAt: StoreFixtures.date(0))
    var sampler = RouteSampler()
    sampler.begin(tripID: trip)
    for i in 0..<5 { sampler.offer(RouteFixtures.sample(north: Double(i) * 100, at: Double(i) * 10), driving: true) }
    try store!.appendRoutePoints(sampler.takePending(), tripID: trip, maxPoints: 5000)
    sampler.offer(RouteFixtures.sample(north: 500, at: 50), driving: true) // pending, lost with the process
    store = nil

    let relaunched = makeStore()
    var restored = RouteSampler()
    restored.begin(tripID: trip)
    for i in 6..<9 { restored.offer(RouteFixtures.sample(north: Double(i) * 100, at: Double(i) * 10), driving: true) }
    try relaunched.appendRoutePoints(restored.takePending(), tripID: trip, maxPoints: 5000)

    try relaunched.read { db in
      XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT seq FROM trip_points WHERE tripId = ? ORDER BY seq", arguments: [trip]),
                     Array(0..<8))
    }
    let route = try relaunched.tripRoute(tripID: trip)
    XCTAssertEqual(route.map(\.timestamp), route.map(\.timestamp).sorted())
    try relaunched.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try XCTUnwrap(try relaunched.trips(limit: 1).first?.distanceMeters), 800, accuracy: 0.01,
                   "0–400 m, gap of the lost point, 600–800 m: the gap is bridged by one segment")
  }
}
