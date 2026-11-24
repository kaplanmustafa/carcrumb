import XCTest
@testable import CarCrumbDetection

// Mandatory QA scenario set replayed through `TraceReplayer` (macOS CI, `swift test`).
// All fixtures here are synthetic (file name prefix `synthetic_`); real field traces from the
// DEBUG trace recorder should be added next to them and replayed with the same assertions.
//
// Tests wrapped in `knownGap` document behaviour the reducer does not implement yet. They use
// strict `XCTExpectFailure`, so CI stays green while the gap exists and turns red as soon as the
// reducer is fixed — then remove the wrapper and keep the test as a regular regression test.
// No open gaps at the moment (the five original ones were fixed with Karar A–E); the helper is
// kept for the next one.
final class ScenarioTraceTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  /// <repo>/fixtures/traces, resolved from this file:
  /// <repo>/modules/carcrumb-detection/ios/Tests/ScenarioTraceTests.swift
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

  // MARK: Effect helpers

  func parkings(_ fx: [Effect]) -> [ParkPoint] {
    fx.compactMap { if case let .saveParking(p) = $0 { return p } else { return nil } }
  }

  func tripStarts(_ fx: [Effect]) -> [Date] {
    fx.compactMap { if case let .beginTrip(d) = $0 { return d } else { return nil } }
  }

  func tripEnds(_ fx: [Effect]) -> [TripStatus] {
    fx.compactMap { if case let .endTrip(s, _) = $0 { return s } else { return nil } }
  }

  func geofences(_ fx: [Effect]) -> Int {
    fx.filter { if case .setGeofence = $0 { return true } else { return false } }.count
  }

  /// No throwing asserts (XCTUnwrap) inside: an error escaping the block is recorded outside
  /// the expected-failure scope and fails the test.
  func knownGap(_ issue: String, _ body: () -> Void) {
    XCTExpectFailure("KNOWN GAP (reducer): \(issue)", failingBlock: body)
  }

  // MARK: Traffic light + 2 min stop-and-go jam → one trip, no parking until the real park

  func testTrafficLightAndJamDoNotSplitTripOrPark() throws {
    let result = try replay("synthetic_traffic_light_and_jam.jsonl")

    XCTAssertEqual(result.transitions.map(\.to), ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "PARKED"])
    XCTAssertTrue(result.transitions.filter { $0.to == "MAYBE_PARKED" || $0.to == "PARKED" }.allSatisfy { $0.at >= at(600) },
                  "red light / jam must not move towards parking")
    let stop = LocationSample(latitude: 41.0, longitude: 29.0, accuracy: 5, speed: 0, timestamp: at(600))
    let point = ParkPoint(location: stop, confidence: .high, parkedAt: at(600))
    XCTAssertEqual(result.finalState, .parked(point))
    XCTAssertEqual(result.effects, [
      .startGPS,
      .beginTrip(startedAt: t0),
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: at(660)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  /// Core Motion occasionally reports `walking` in stop-and-go traffic. The car link is still
  /// connected and the car creeps (~2 m/s, below `drivingSpeed`) > 40 m from the stop point.
  /// Karar C: no park confirmation while the car link is connected.
  func testSpuriousWalkingInJamDoesNotPark() throws {
    let result = try replay("synthetic_traffic_jam_false_walking.jsonl")
    XCTAssertEqual(tripStarts(result.effects), [t0], "jam must not split the trip")
    XCTAssertEqual(tripEnds(result.effects), [.confirmed])
    let parks = parkings(result.effects)
    XCTAssertEqual(parks.count, 1)
    XCTAssertEqual(parks.first?.location.latitude, 41.0)
    XCTAssertEqual(parks.first?.location.longitude, 29.0)
  }

  // MARK: Fuel stop, ~5 min, get out and back in → one trip

  func testFuelStopGetOutAndBackInIsOneTrip() throws {
    let result = try replay("synthetic_fuel_stop_get_out.jsonl")

    XCTAssertEqual(result.transitions.map(\.to),
                   ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "DRIVING", "MAYBE_PARKED", "PARKED"])
    let stop = LocationSample(latitude: 41.0, longitude: 29.0, accuracy: 5, speed: 0, timestamp: at(900))
    let point = ParkPoint(location: stop, confidence: .high, parkedAt: at(900))
    XCTAssertEqual(result.finalState, .parked(point))
    XCTAssertEqual(result.effects, [
      .startGPS,
      .beginTrip(startedAt: t0),
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: at(960)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ], "fuel stop must not stop GPS, end the trip or save a park at the pump")
  }

  // MARK: Bus / taxi (no car link) → trip kept as uncertain, no parking

  func testBusWithoutCarLinkIsUncertainWithoutParking() throws {
    let result = try replay("synthetic_bus_no_carlink.jsonl")

    XCTAssertEqual(result.transitions.map(\.to), ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "IDLE"],
                   "bus stops (stationary) must not leave DRIVING")
    XCTAssertEqual(result.finalState, .idle)
    XCTAssertEqual(result.effects, [
      .startGPS,
      .beginTrip(startedAt: t0),
      .stopGPS,
      .endTrip(status: .uncertain, endedAt: at(960)),
    ])
    XCTAssertTrue(parkings(result.effects).isEmpty)
    XCTAssertEqual(geofences(result.effects), 0)
  }

  func testTaxiIsTripWithoutParking() throws {
    let result = try replay("synthetic_taxi_no_carlink.jsonl")

    XCTAssertEqual(result.finalState, .idle)
    XCTAssertEqual(tripStarts(result.effects), [t0])
    XCTAssertEqual(tripEnds(result.effects), [.uncertain])
    XCTAssertTrue(parkings(result.effects).isEmpty)
    XCTAssertEqual(geofences(result.effects), 0)
  }

  /// Driver connects CarPlay and waits > 5 min before moving (warm-up, car park queue).
  /// MAYBE_DRIVING times out to IDLE. When the car finally moves, the engine re-reads the audio
  /// route after `startGPS` and feeds the current level as `.carLink(true)` (recorded in the
  /// trace at t+400), so the trip is still confirmed although the link never changed.
  func testCarLinkConnectedBeforeLongWaitStillConfirmsTrip() throws {
    let result = try replay("synthetic_carlink_before_long_wait.jsonl")
    XCTAssertEqual(tripEnds(result.effects), [.confirmed])
    XCTAssertEqual(parkings(result.effects).count, 1)
  }

  /// Same trace without the engine's re-read: documents that the reducer alone cannot know
  /// the level after IDLE, so the engine side of the fix is load-bearing.
  func testCarLinkLevelIsLostWithoutEngineReread() throws {
    let all = try records("synthetic_carlink_before_long_wait.jsonl")
    let withoutReread = all.filter { !($0.time == at(400) && $0.event == .carLink(connected: true)) }
    XCTAssertEqual(withoutReread.count, all.count - 1)
    XCTAssertEqual(tripEnds(TraceReplayer().replay(withoutReread).effects), [.uncertain])
  }

  // MARK: Indoor car park (GPS degraded / lost) → last reliable point + low confidence flag

  func testGarageWithDegradedGPSIsLowConfidence() throws {
    let result = try replay("synthetic_garage_gps_degraded.jsonl")

    XCTAssertEqual(tripEnds(result.effects), [.confirmed])
    let parks = parkings(result.effects)
    XCTAssertEqual(parks.count, 1)
    XCTAssertEqual(parks.first?.confidence, .low)
    XCTAssertFalse(parks.contains { $0.confidence == .high })
  }

  /// Buffer is entrance fix (acc 6 m) followed by drifting indoor fixes (65 m, 120 m).
  /// The park point must be the last reliable fix (acc 6 m), not `buffer.last` (acc 120 m).
  func testGarageWithDegradedGPSParksAtLastReliableFix() throws {
    let result = try replay("synthetic_garage_gps_degraded.jsonl")
    let park = parkings(result.effects).first
    XCTAssertEqual(park?.location.latitude, 41.0)
    XCTAssertEqual(park?.location.longitude, 29.0)
    XCTAssertEqual(park?.location.accuracy, 6)
    XCTAssertEqual(park?.confidence, .low, "indoor degradation must still flag low confidence")
  }

  func testGarageWithGPSLostKeepsLastFix() throws {
    let result = try replay("synthetic_garage_gps_lost.jsonl")

    let park = try XCTUnwrap(parkings(result.effects).first)
    XCTAssertEqual(park.location.latitude, 41.0)
    XCTAssertEqual(park.location.longitude, 29.0)
    XCTAssertEqual(park.location.timestamp, at(600))
  }

  /// GPS is gone for 100 s before walking starts (car kept driving down the ramps). The last fix
  /// was taken while the car was still moving (3 m/s) and GPS was lost before it stopped → low.
  func testGarageWithGPSLostIsLowConfidence() throws {
    let result = try replay("synthetic_garage_gps_lost.jsonl")
    XCTAssertEqual(parkings(result.effects).first?.confidence, .low)
  }

  /// Car stops at t+600 (good fix, speed 0), the user sits in the car for 90 s with GPS silent,
  /// engine off at t+686, walks from t+690. GPS went silent AFTER the car stopped, so the park
  /// is high confidence (DECISIONS "Park noktası": order of events, not age).
  func testSittingInCar90sWithSilentGPSIsHighConfidence() throws {
    let result = try replay("synthetic_sit_in_car_90s.jsonl")
    let stop = LocationSample(latitude: 41.0, longitude: 29.0, accuracy: 5, speed: 0, timestamp: at(600))
    let point = ParkPoint(location: stop, confidence: .high, parkedAt: at(600))
    XCTAssertEqual(result.finalState, .parked(point))
    XCTAssertEqual(result.transitions.map(\.to), ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "PARKED"])
    XCTAssertEqual(result.effects, [
      .startGPS,
      .beginTrip(startedAt: t0),
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: at(750)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  // MARK: Phone left in the car → no walking, parking late but correct

  func testPhoneLeftInCarNeverParksAtAWrongPoint() throws {
    let result = try replay("synthetic_phone_left_in_car.jsonl")
    for park in parkings(result.effects) {
      XCTAssertEqual(park.location.latitude, 41.0)
      XCTAssertEqual(park.location.longitude, 29.0)
    }
  }

  /// Car link drops at t+610, the phone then reports the same spot at speed 0 for 15 min and
  /// never sees walking. Karar B: 15 min without movement + no car link ends the trip with a
  /// low-confidence park at the stop point, and GPS is stopped.
  func testPhoneLeftInCarEventuallyParksAtStopPoint() throws {
    let result = try replay("synthetic_phone_left_in_car.jsonl")
    XCTAssertNotEqual(result.finalState.name, "DRIVING")
    XCTAssertTrue(result.effects.contains(.stopGPS))
    XCTAssertEqual(tripEnds(result.effects), [.confirmed])
    let park = parkings(result.effects).first
    XCTAssertEqual(park?.location.latitude, 41.0)
    XCTAssertEqual(park?.location.longitude, 29.0)
    XCTAssertEqual(park?.confidence, .low)
    // Trip end = last movement (t+598, 2 m/s), not when the timeout noticed it.
    XCTAssertTrue(result.effects.contains(.endTrip(status: .confirmed, endedAt: at(598))))
  }

  // MARK: App terminated, relaunched by significant location change → no data lost

  /// Persist → JSON → restore, the way the engine does it across process death.
  func restoreAfterKill(_ state: DetectionState, savedAt: Date, relaunchAt: Date) throws -> (DetectionState, [Effect]) {
    let persisted = PersistedDetectionState(state: state, savedAt: savedAt, tripID: 1)
    let data = try TraceFormat.makeEncoder().encode(persisted)
    let decoded = try TraceFormat.makeDecoder().decode(PersistedDetectionState.self, from: data)
    return StateRestorePolicy.restore(decoded, now: relaunchAt)
  }

  func testKilledWhileDrivingAndWokenBySLCLosesNothing() throws {
    let all = try records("synthetic_normal_drive.jsonl")
    let full = TraceReplayer().replay(all)

    // Killed right after the t+300 fix (DRIVING), relaunched by SLC at t+590.
    let killIndex = try XCTUnwrap(all.firstIndex { $0.time > at(300) })
    let before = TraceReplayer().replay(Array(all[..<killIndex]))
    XCTAssertEqual(before.finalState.name, "DRIVING")

    let (restored, restoreFx) = try restoreAfterKill(before.finalState, savedAt: at(300), relaunchAt: at(590))
    XCTAssertEqual(restored, before.finalState)
    XCTAssertEqual(restoreFx, [.startGPS])

    let after = TraceReplayer().replay(
      [TraceRecord(time: at(590), event: .wake(.significantLocationChange))] + all[killIndex...],
      from: restored)

    XCTAssertEqual(after.finalState, full.finalState)
    XCTAssertEqual(before.effects + after.effects, full.effects, "no second trip, same park")
    XCTAssertTrue(tripStarts(after.effects).isEmpty, "SLC wake in DRIVING must not open a new trip")
  }

  func testKilledWhileMaybeParkedResumesAndParksAtTransitionPoint() throws {
    let all = try records("synthetic_normal_drive.jsonl")
    let full = TraceReplayer().replay(all)

    // Killed after walking started (t+620 tick), relaunched at t+650; the t+630 fix is lost.
    let killIndex = try XCTUnwrap(all.firstIndex { $0.time > at(620) })
    let before = TraceReplayer().replay(Array(all[..<killIndex]))
    XCTAssertEqual(before.finalState.name, "MAYBE_PARKED")

    let (restored, restoreFx) = try restoreAfterKill(before.finalState, savedAt: at(620), relaunchAt: at(650))
    XCTAssertEqual(restoreFx, [.startGPS])

    let rest = all[killIndex...].filter { $0.time >= at(650) }
    let after = TraceReplayer().replay(
      [TraceRecord(time: at(650), event: .wake(.significantLocationChange))] + rest,
      from: restored)

    XCTAssertEqual(after.finalState, full.finalState)
    XCTAssertEqual(parkings(after.effects), parkings(full.effects))
  }

  func testKilledLongerThanResumeWindowClosesTripAsUncertain() throws {
    let all = try records("synthetic_normal_drive.jsonl")
    let killIndex = try XCTUnwrap(all.firstIndex { $0.time > at(300) })
    let before = TraceReplayer().replay(Array(all[..<killIndex]))

    let (restored, fx) = try restoreAfterKill(before.finalState, savedAt: at(300), relaunchAt: at(300 + 20 * 60))
    XCTAssertEqual(restored, .idle)
    XCTAssertEqual(fx, [.endTrip(status: .uncertain, endedAt: at(300))], "trip row is closed, not dropped")
    XCTAssertTrue(parkings(fx).isEmpty)
  }

  /// Karar E: MAYBE_PARKED with car link, relaunched long after → low park at the candidate,
  /// trip confirmed at the walking start. No stopGPS (fresh process has no GPS session).
  func testKilledWhileMaybeParkedLongerThanResumeWindowParksLow() throws {
    let all = try records("synthetic_normal_drive.jsonl")
    let killIndex = try XCTUnwrap(all.firstIndex { $0.time > at(620) })
    let before = TraceReplayer().replay(Array(all[..<killIndex]))
    XCTAssertEqual(before.finalState.name, "MAYBE_PARKED")

    let (restored, fx) = try restoreAfterKill(before.finalState, savedAt: at(620), relaunchAt: at(620 + 3600))
    let stop = LocationSample(latitude: 41.0, longitude: 29.0, accuracy: 5, speed: 0, timestamp: at(600))
    let point = ParkPoint(location: stop, confidence: .low, parkedAt: at(600))
    XCTAssertEqual(restored, .parked(point))
    XCTAssertEqual(fx, [
      .endTrip(status: .confirmed, endedAt: at(604)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  /// The engine records restores in the trace; replaying such a trace gives the same result
  /// as the uninterrupted run.
  func testRestoreRecordInTraceReplays() throws {
    let all = try records("synthetic_normal_drive.jsonl")
    let full = TraceReplayer().replay(all)
    let killIndex = try XCTUnwrap(all.firstIndex { $0.time > at(620) })
    let before = TraceReplayer().replay(Array(all[..<killIndex]))

    let persisted = PersistedDetectionState(state: before.finalState, savedAt: at(620), tripID: 1)
    var trace = Data()
    for r in all[..<killIndex] { trace.append(try TraceFormat.encodeLine(r)) }
    trace.append(try TraceFormat.encodeLine(TraceRecord(time: at(650), restore: persisted)))
    trace.append(try TraceFormat.encodeLine(TraceRecord(time: at(650), event: .wake(.significantLocationChange))))
    for r in all[killIndex...] where r.time >= at(650) { trace.append(try TraceFormat.encodeLine(r)) }

    let result = try TraceReplayer().replay(jsonLines: trace)
    XCTAssertEqual(result.finalState, full.finalState)
    XCTAssertEqual(result.effects.filter { $0 != .startGPS }, full.effects.filter { $0 != .startGPS })
    XCTAssertEqual(result.effects.filter { $0 == .startGPS }.count, 2, "restore re-emits startGPS")
  }
}
