import XCTest
@testable import CarCrumbDetection

// Trace-level scenarios for the timeout / car link / late walking rules
// (docs/DECISIONS.md, "Kurallar": Park noktası, Park onayı, Zaman aşımları).
// Runs only on macOS CI (`swift test`). All fixtures are synthetic.
//
// `knownGap` tests use strict `XCTExpectFailure`: green while the gap exists, red once the
// reducer is fixed — then drop the wrapper and keep the assertions.
final class ScenarioTimeoutTraceTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  /// <repo>/fixtures/traces, resolved from this file:
  /// <repo>/modules/carcrumb-detection/ios/Tests/ScenarioTimeoutTraceTests.swift
  static let tracesDir: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("fixtures/traces", isDirectory: true)
  }()

  func records(_ name: String) throws -> [TraceRecord] {
    try TraceFormat.decodeLines(Data(contentsOf: Self.tracesDir.appendingPathComponent(name)))
  }

  func replay(_ name: String) throws -> TraceReplayer.Result {
    TraceReplayer().replay(try records(name))
  }

  func parkings(_ fx: [Effect]) -> [ParkPoint] {
    fx.compactMap { if case let .saveParking(p) = $0 { return p } else { return nil } }
  }

  func tripStarts(_ fx: [Effect]) -> [Date] {
    fx.compactMap { if case let .beginTrip(d) = $0 { return d } else { return nil } }
  }

  func tripEnds(_ fx: [Effect]) -> [TripStatus] {
    fx.compactMap { if case let .endTrip(s, _) = $0 { return s } else { return nil } }
  }

  func count(_ effect: Effect, in fx: [Effect]) -> Int {
    fx.filter { $0 == effect }.count
  }

  /// The stop point shared by most fixtures: 41.0 / -40.0, acc 5 m, speed 0, t+600.
  var stop: LocationSample {
    LocationSample(latitude: 41.0, longitude: -40.0, accuracy: 5, speed: 0, timestamp: at(600))
  }

  /// No throwing asserts (XCTUnwrap) inside: an error escaping the block is recorded outside
  /// the expected-failure scope and fails the test.
  func knownGap(_ issue: String, _ body: () -> Void) {
    XCTExpectFailure("KNOWN GAP (reducer): \(issue)", failingBlock: body)
  }

  // MARK: Hard cap: 60 min idling with CarPlay connected

  /// Engine idling, CarPlay connected, GPS reports the same spot at speed 0 every minute.
  /// Last movement t+598 (2 m/s). Trip must stay open until t+598+3600 and end there.
  func testIdle60MinWithCarPlayEndsAtHardCap() throws {
    let all = try records("synthetic_idle_60min_carplay.jsonl")

    let beforeCap = TraceReplayer().replay(all.filter { $0.time < at(598 + 3600) })
    XCTAssertEqual(beforeCap.finalState.name, "DRIVING", "car link on: no end before the hard cap")
    XCTAssertEqual(beforeCap.effects, [.startGPS, .beginTrip(startedAt: t0)])

    let result = TraceReplayer().replay(all)
    XCTAssertEqual(result.transitions.map(\.to), ["MAYBE_DRIVING", "DRIVING", "PARKED"],
                   "never MAYBE_PARKED: no walking was reported")
    XCTAssertEqual(result.transitions.last?.at, at(4200), "first event at or after t+598+3600")
    XCTAssertEqual(count(.stopGPS, in: result.effects), 1)
    XCTAssertTrue(result.effects.contains(.endTrip(status: .confirmed, endedAt: at(598))),
                  "trip end = last movement, not when the cap noticed it")
    let parks = parkings(result.effects)
    XCTAssertEqual(parks.count, 1)
    XCTAssertEqual(parks.first?.location.latitude, 41.0)
    XCTAssertEqual(parks.first?.location.longitude, -40.0)
    XCTAssertEqual(parks.first?.confidence, .low)
    XCTAssertEqual(parks.first?.parkedAt, at(598))
  }

  /// Same idling, but Core Motion flips stationary ↔ automotive every 5 min (engine vibration;
  /// MotionSensor maps automotive+stationary to automotive). GPS speed stays 0 the whole time.
  /// Movement evidence is GPS driving speed only, so the flicker must not reset the 60 min
  /// clock. DECISIONS: "GPS hiçbir durumda süresiz açık kalmaz".
  func testIdleWithAutomotiveFlickerStillHitsHardCap() throws {
    let result = try replay("synthetic_idle_60min_carplay_motion_flicker.jsonl")
    XCTAssertTrue(result.transitions.contains { $0.to == "PARKED" && $0.at <= at(598 + 3600 + 60) },
                  "expected the hard cap at ~t+4198 (no GPS movement since t+598)")
    XCTAssertNotEqual(result.finalState.name, "DRIVING")
  }

  // MARK: MAYBE_PARKED 10 min with car link connected → back to the same trip

  /// Walking reported while sitting in the car with CarPlay on (t+608). Nothing confirms for
  /// 10 min; at the t+1210 tick the link is still connected → DRIVING (same trip, GPS on).
  /// Then the car drives on and parks for real at 40.99 / -40.01 after the link drops.
  func testMaybeParked10MinWithCarLinkReturnsToSameTrip() throws {
    let result = try replay("synthetic_maybe_parked_10min_carlink_on.jsonl")

    XCTAssertEqual(result.transitions.map(\.to),
                   ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "DRIVING", "MAYBE_PARKED", "PARKED"])
    XCTAssertEqual(result.transitions[3].at, at(1210))
    XCTAssertEqual(result.transitions[3].eventType, "tick", "the 10 min timeout, not new movement")
    XCTAssertEqual(tripStarts(result.effects), [t0], "no second trip")
    XCTAssertEqual(count(.stopGPS, in: result.effects), 1, "GPS stays on through the timeout")
    XCTAssertEqual(tripEnds(result.effects), [.confirmed])

    let parks = parkings(result.effects)
    XCTAssertEqual(parks.count, 1, "no park at the first stop")
    let park = try XCTUnwrap(parks.first)
    XCTAssertEqual(park.location.latitude, 40.99, accuracy: 1e-9)
    XCTAssertEqual(park.location.longitude, -40.01, accuracy: 1e-9)
    XCTAssertEqual(park.location.timestamp, at(1800))
    XCTAssertEqual(park.confidence, .high)
  }

  // MARK: Late walking report with walking fixes already far away

  /// Walking delivered at t+645, Core Motion start t+604. Park point = stop fix before t+604.
  func testLateWalking40sParksAtStopPoint() throws {
    let result = try replay("synthetic_late_walking_40s.jsonl")

    let point = ParkPoint(location: stop, confidence: .high, parkedAt: at(600))
    XCTAssertEqual(result.finalState, .parked(point))
    XCTAssertEqual(tripStarts(result.effects), [t0])
    XCTAssertTrue(result.effects.contains(.endTrip(status: .confirmed, endedAt: at(660))))
    XCTAssertEqual(parkings(result.effects), [point])
  }

  /// Walking delivered at t+700, Core Motion start t+604 (96 s late), walking fixes every 10 s.
  /// By then the 60 s ring buffer holds only walking fixes. The stop fix (`lastStopFix`) and the
  /// moving-only anchor keep the pre-transition stop point; walking fixes are never candidates.
  func testLateWalking96sStillParksAtStopPoint() throws {
    let result = try replay("synthetic_late_walking_96s.jsonl")

    XCTAssertEqual(tripStarts(result.effects), [t0])
    XCTAssertEqual(tripEnds(result.effects), [.confirmed])
    XCTAssertEqual(parkings(result.effects).count, 1)
    let park = parkings(result.effects).first
    XCTAssertEqual(park?.location, stop, "park point must be the stop fix before the walking start")
    XCTAssertEqual(park?.confidence, .high, "stop fix taken at standstill, acc 5 m")
  }

  // MARK: Car link drops after the user already walked away (wireless CarPlay range)

  func testCarLinkDropsAfterWalkingAwayStillParksAtStopPoint() throws {
    let result = try replay("synthetic_link_drops_after_walk.jsonl")

    let point = ParkPoint(location: stop, confidence: .high, parkedAt: at(600))
    XCTAssertEqual(result.finalState, .parked(point))
    XCTAssertEqual(tripStarts(result.effects), [t0])
    XCTAssertTrue(result.effects.contains(.endTrip(status: .confirmed, endedAt: at(670))),
                  "confirmed by the link drop, using the far fix from t+660")
    XCTAssertEqual(parkings(result.effects), [point])
  }

  // MARK: Indoor car park: recent entrance fix, then degraded fixes

  /// Entrance fix (acc 6 m, still rolling at 3 m/s) only 20 s before walking, then 65 m /
  /// 120 m indoor fixes. GPS degraded before the car stopped → low (DECISIONS "Park noktası":
  /// order of events, not age).
  func testGarageRecentEntranceThenDegradedIsLowConfidence() throws {
    let result = try replay("synthetic_garage_entrance_recent_then_degraded.jsonl")

    let park = try XCTUnwrap(parkings(result.effects).first)
    XCTAssertEqual(park.location.latitude, 41.0)
    XCTAssertEqual(park.location.longitude, -40.0)
    XCTAssertEqual(park.location.accuracy, 6)
    XCTAssertEqual(park.confidence, .low)
  }
}
