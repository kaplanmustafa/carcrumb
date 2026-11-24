import XCTest
@testable import CarCrumbDetection

// Runs only on macOS (CI / EAS). Synthetic inputs; recorded field traces go in fixtures/traces.
final class DetectionReducerTests: XCTestCase {
  let reducer = DetectionReducer()
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  func sample(_ lat: Double, _ lon: Double, speed: Double, at seconds: TimeInterval, accuracy: Double = 5) -> LocationSample {
    LocationSample(latitude: lat, longitude: lon, accuracy: accuracy, speed: speed, timestamp: t0.addingTimeInterval(seconds))
  }

  func run(_ events: [(TimeInterval, DetectionEvent)], from start: DetectionState = .idle) -> (DetectionState, [Effect]) {
    var state = start
    var effects: [Effect] = []
    for (s, e) in events {
      let (next, fx) = reducer.reduce(state, e, now: t0.addingTimeInterval(s))
      state = next
      effects += fx
    }
    return (state, effects)
  }

  func parks(_ fx: [Effect]) -> [ParkPoint] {
    fx.compactMap { if case let .saveParking(p) = $0 { return p } else { return nil } }
  }

  /// Drive with car link until a stop at (41.0, 29.0) at t+600; engine off (link drops) at `drop`.
  func driveToStop(linkDropsAt drop: TimeInterval? = 602) -> [(TimeInterval, DetectionEvent)] {
    var events: [(TimeInterval, DetectionEvent)] = [
      (0, .wake(.significantLocationChange)),
      (1, .carLink(connected: true)),
      (10, .location(sample(41.01, 29.01, speed: 12, at: 10))),
      (598, .location(sample(41.0, 29.0001, speed: 2, at: 598))),
      (600, .location(sample(41.0, 29.0, speed: 0, at: 600))),
    ]
    if let drop { events.append((drop, .carLink(connected: false))) }
    return events
  }

  // MARK: Basics

  func testNormalDriveWithCarLinkParksAtTransitionPoint() {
    let stop = sample(41.0, 29.0, speed: 0, at: 600)
    let (state, effects) = run(driveToStop() + [
      (605, .motion(.walking)),
      (660, .location(sample(41.0005, 29.0, speed: 1.2, at: 660))), // ~55 m away
    ])
    guard case let .parked(point) = state else { return XCTFail("expected PARKED, got \(state.name)") }
    XCTAssertEqual(point.location, stop, "park point must be the transition point, not the walked-to point")
    XCTAssertEqual(point.confidence, .high)
    XCTAssertTrue(effects.contains(.saveParking(point)))
    XCTAssertTrue(effects.contains(.setGeofence(center: stop, radius: 150)))
  }

  func testTrafficStopDoesNotPark() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (1, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (20, .location(sample(41.0001, 29.0, speed: 0, at: 20))),
      (21, .motion(.stationary)),
      (140, .tick), // 2 min standstill
      (141, .location(sample(41.0002, 29.0, speed: 8, at: 141))),
    ])
    XCTAssertEqual(state.name, "DRIVING")
    XCTAssertTrue(parks(effects).isEmpty)
  }

  func testWalkingBackToCarResumesTrip() {
    let (state, _) = run([
      (0, .wake(.visit)),
      (1, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (20, .motion(.walking)), // fuel station: get out
      (30, .location(sample(41.0001, 29.0, speed: 0.5, at: 30))), // ~11 m, below threshold
      (300, .motion(.automotive)),
    ])
    XCTAssertEqual(state.name, "DRIVING")
  }

  func testTripWithoutCarLinkIsUncertainAndWritesNoParking() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (600, .motion(.walking)),
      (660, .location(sample(41.0005, 29.0, speed: 1.2, at: 660))),
    ])
    XCTAssertEqual(state, .idle)
    XCTAssertTrue(effects.contains(.endTrip(status: .uncertain, endedAt: at(660))))
    XCTAssertTrue(parks(effects).isEmpty)
  }

  func testUnconfirmedWakeTimesOutToIdle() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (301, .tick),
    ])
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(effects, [.startGPS, .stopGPS])
  }

  /// Behaviour change (Karar C): the car link now has to drop before a park is confirmed,
  /// hence the `.carLink(false)` at t+15; the walk-away sample is farther (accuracy margin).
  func testPoorAccuracyParkIsLowConfidence() {
    let (state, _) = run([
      (0, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10, accuracy: 65))), // garage, GPS degraded
      (15, .carLink(connected: false)),
      (20, .motion(.walking)),
      (80, .location(sample(41.0006, 29.0, speed: 1, at: 80))), // ~67 m, minus 5 m accuracy
    ])
    guard case let .parked(point) = state else { return XCTFail("expected PARKED, got \(state.name)") }
    XCTAssertEqual(point.confidence, .low)
  }

  // MARK: Karar D – geofence

  func testDrivingEntryDoesNotClearGeofence() {
    let s = sample(41.0, 29.0, speed: 0, at: 0)
    let parked = DetectionState.parked(ParkPoint(location: s, confidence: .high, parkedAt: t0))
    let (state, effects) = run([
      (100, .wake(.geofenceExit)),
      (110, .location(sample(41.01, 29.01, speed: 12, at: 110))),
    ], from: parked)
    XCTAssertEqual(state.name, "DRIVING")
    XCTAssertEqual(effects, [.startGPS, .beginTrip(startedAt: at(100))])
  }

  // MARK: Park point selection

  func testLateWalkingReportUsesCoreMotionStartDate() {
    let stop = sample(41.0, 29.0, speed: 0, at: 600)
    let (state, _) = run(driveToStop() + [
      (610, .location(sample(41.00004, 29.0, speed: 1.2, at: 610, accuracy: 6))),
      (618, .location(sample(41.0001, 29.0, speed: 1.3, at: 618, accuracy: 6))),
      (619, .motion(.walking, startedAt: at(604))), // reported 15 s late
    ])
    guard case let .maybeParked(_, candidate, walkingSince) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(candidate, stop, "last good fix before the walking start, not the newest fix")
    XCTAssertEqual(walkingSince, at(604))
  }

  func testLateWalkingReportAlreadyFarAwayConfirmsImmediately() {
    let (state, effects) = run(driveToStop() + [
      (640, .location(sample(41.0005, 29.0, speed: 1.3, at: 640, accuracy: 6))), // ~55 m
      (641, .motion(.walking, startedAt: at(604))),
    ])
    XCTAssertEqual(state.name, "PARKED")
    XCTAssertEqual(parks(effects).first?.location, sample(41.0, 29.0, speed: 0, at: 600))
  }

  func testStaleCandidateIsLowConfidence() {
    let (state, _) = run([
      (0, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (100, .carLink(connected: false)),
      (110, .motion(.walking)), // last fix 100 s before walking: GPS lost
      (170, .location(sample(41.0006, 29.0, speed: 1, at: 170))),
    ])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.location.timestamp, at(10))
    XCTAssertEqual(point.confidence, .low)
  }

  func testOnlyInaccurateFixesPickMostAccurateWithLowConfidence() {
    let (state, _) = run([
      (0, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10, accuracy: 40))),
      (12, .location(sample(41.0001, 29.0, speed: 3, at: 12, accuracy: 90))),
      (13, .carLink(connected: false)),
      (14, .motion(.walking)),
      (80, .location(sample(41.0008, 29.0, speed: 1, at: 80))),
    ])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.location.accuracy, 40)
    XCTAssertEqual(point.confidence, .low)
  }

  // MARK: Karar C – park confirmation

  func testNoParkWhileCarLinkConnectedThenConfirmsWhenItDrops() {
    let walked = driveToStop(linkDropsAt: nil) + [
      (605, .motion(.walking)),
      (660, .location(sample(41.0005, 29.0, speed: 1.2, at: 660))),
    ]
    let (connected, fx1) = run(walked)
    XCTAssertEqual(connected.name, "MAYBE_PARKED")
    XCTAssertTrue(parks(fx1).isEmpty)

    let (state, fx2) = run(walked + [(670, .carLink(connected: false))])
    XCTAssertEqual(state.name, "PARKED")
    XCTAssertTrue(fx2.contains(.endTrip(status: .confirmed, endedAt: at(670))))
  }

  func testCarSpeedSampleDoesNotConfirm() {
    let (state, _) = run(driveToStop() + [
      (605, .motion(.walking)),
      (660, .location(sample(41.0005, 29.0, speed: 3.5, at: 660))),
    ])
    XCTAssertEqual(state.name, "MAYBE_PARKED")
  }

  func testAccuracyMarginIsSubtracted() {
    // ~44 m away but 10 m accuracy → 34 m < 40 m.
    let (state, _) = run(driveToStop() + [
      (605, .motion(.walking)),
      (660, .location(sample(41.0004, 29.0, speed: 1.2, at: 660, accuracy: 10))),
    ])
    XCTAssertEqual(state.name, "MAYBE_PARKED")
  }

  func testLastActivityMustBeWalking() {
    let (state, _) = run(driveToStop() + [
      (605, .motion(.walking)),
      (630, .motion(.stationary)),
      (660, .location(sample(41.0005, 29.0, speed: 1.2, at: 660))),
    ])
    XCTAssertEqual(state.name, "MAYBE_PARKED")
  }

  // MARK: Karar A – MAYBE_PARKED timeout

  func testMaybeParkedTimeoutWithCarLinkParksLow() {
    let (state, effects) = run(driveToStop() + [
      (605, .motion(.walking)),
      (900, .tick),
      (1205, .tick),
    ])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.confidence, .low)
    XCTAssertEqual(point.location, sample(41.0, 29.0, speed: 0, at: 600))
    XCTAssertEqual(Array(effects.suffix(4)), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: at(605)),
      .saveParking(point),
      .setGeofence(center: point.location, radius: 150),
    ])
  }

  /// Car link still connected when the 10 min run out: no park, same trip back in DRIVING
  /// (no second beginTrip, GPS stays on); the hard cap ends it later at the stop point.
  func testMaybeParkedTimeoutWithCarLinkConnectedReturnsToDriving() {
    let events = driveToStop(linkDropsAt: nil) + [
      (605, .motion(.walking)),
      (1205, .tick),
    ]
    let (state, effects) = run(events)
    XCTAssertEqual(state.name, "DRIVING")
    XCTAssertTrue(parks(effects).isEmpty)
    XCTAssertEqual(effects, [.startGPS, .beginTrip(startedAt: t0)], "no stopGPS, no endTrip, no new trip")

    let (later, laterFx) = run(events + [(598 + 3600, .tick)])
    XCTAssertEqual(later.name, "PARKED")
    XCTAssertEqual(parks(laterFx).first?.confidence, .low)
    XCTAssertTrue(laterFx.contains(.endTrip(status: .confirmed, endedAt: at(598))))
  }

  /// Late walking report whose start is already > 10 min ago, link still connected: stays DRIVING.
  func testLateWalkingPastTimeoutWithCarLinkConnectedStaysDriving() {
    let (state, effects) = run(driveToStop(linkDropsAt: nil) + [
      (1300, .motion(.walking, startedAt: at(604))),
    ])
    XCTAssertEqual(state.name, "DRIVING")
    XCTAssertTrue(parks(effects).isEmpty)
  }

  func testMaybeParkedTimeoutWithoutCarLinkIsUncertain() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (20, .motion(.walking)),
      (620, .tick),
    ])
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(Array(effects.suffix(2)), [.stopGPS, .endTrip(status: .uncertain, endedAt: at(20))])
    XCTAssertTrue(parks(effects).isEmpty)
  }

  // MARK: Karar B – DRIVING stationary timeout

  /// Behaviour change (hard cap): was a 3600 s tick; at 60 min the trip now ends, so the last
  /// tick that must keep DRIVING is one second earlier.
  func testDrivingStationaryWithCarLinkConnectedKeepsDriving() {
    let (state, _) = run(driveToStop(linkDropsAt: nil) + [(598 + 3599, .tick)])
    XCTAssertEqual(state.name, "DRIVING", "car still connected (engine on): not a park before the hard cap")
  }

  // MARK: Hard cap – DRIVING 60 min without movement, car link connected or not

  func testDrivingHardTimeoutWithCarLinkConnectedParksLowAtStopPoint() {
    let (state, effects) = run(driveToStop(linkDropsAt: nil) + [(598 + 3600, .tick)])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    let stop = sample(41.0, 29.0, speed: 0, at: 600)
    XCTAssertEqual(point, ParkPoint(location: stop, confidence: .low, parkedAt: at(598)))
    XCTAssertEqual(Array(effects.suffix(4)), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: at(598)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  /// (Stop model: the clock and the trip end start at the first fix below driving speed, t+20.)
  func testDrivingHardTimeoutWithoutCarLinkIsUncertain() {
    // Karar B would end a link-less trip at 15 min; lift it to reach the hard-cap branch alone.
    var config = DetectionConfig()
    config.drivingStationaryTimeout = 2 * 3600
    let r = DetectionReducer(config: config)
    let events: [(TimeInterval, DetectionEvent)] = [
      (0, .wake(.significantLocationChange)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (20, .location(sample(41.0, 29.0, speed: 0, at: 20))),
      (20 + 3599, .tick),
    ]
    var state = DetectionState.idle
    for (s, e) in events { state = r.reduce(state, e, now: at(s)).0 }
    XCTAssertEqual(state.name, "DRIVING", "one second before the hard cap")
    let (final, fx) = r.reduce(state, .tick, now: at(20 + 3600))
    XCTAssertEqual(final, .idle)
    XCTAssertEqual(fx, [.stopGPS, .endTrip(status: .uncertain, endedAt: at(20))])
  }

  func testDrivingStationaryWithoutCarLinkParksLowAtStopPoint() {
    let (before, _) = run(driveToStop() + [(598 + 899, .tick)])
    XCTAssertEqual(before.name, "DRIVING")
    let (state, effects) = run(driveToStop() + [(598 + 900, .tick)])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.confidence, .low)
    XCTAssertEqual(point.location, sample(41.0, 29.0, speed: 0, at: 600))
    XCTAssertTrue(effects.contains(.stopGPS))
    XCTAssertTrue(effects.contains(.endTrip(status: .confirmed, endedAt: at(598))))
  }

  /// Behaviour change: trip end = when the car stopped (t+20), was the last fast fix (t+10).
  func testDrivingStationaryWithoutAnyCarLinkIsUncertain() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10))),
      (20, .location(sample(41.0, 29.0, speed: 0, at: 20))),
      (920, .tick),
    ])
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(Array(effects.suffix(2)), [.stopGPS, .endTrip(status: .uncertain, endedAt: at(20))])
  }

  // MARK: Movement evidence = GPS driving speed only

  func testAutomotiveFlickerDoesNotResetStationaryClock() {
    var events = driveToStop(linkDropsAt: nil)
    for m in stride(from: 900.0, through: 4100, by: 300) {
      events.append((m, .motion(.automotive)))
      events.append((m + 150, .motion(.stationary)))
    }
    events.append((598 + 3600, .tick))
    let (state, effects) = run(events)
    XCTAssertEqual(state.name, "PARKED", "idling vibration must not keep GPS on past the hard cap")
    XCTAssertTrue(effects.contains(.endTrip(status: .confirmed, endedAt: at(598))))
  }

  func testWakeAndWalkingSpeedAreNotMovement() {
    let (state, _) = run(driveToStop() + [
      (700, .wake(.significantLocationChange)),
      (800, .location(sample(41.0, 29.0, speed: 2.0, at: 800))), // creeping / walking speed
      (900, .wake(.visit)),
      (598 + 900, .tick),
    ])
    XCTAssertEqual(state.name, "PARKED", "Karar B still counts from the stop at t+598")
  }

  func testDrivingSpeedResetsStopAndClock() {
    let (state, _) = run(driveToStop() + [
      (700, .location(sample(41.002, 29.002, speed: 8, at: 700))),
      (598 + 900, .tick), // would have fired without the t+700 movement
    ])
    guard case let .driving(trip) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(trip.lastMovingAt, at(700))
    XCTAssertNil(trip.stoppedAt)
    XCTAssertNil(trip.lastStopFix)
  }

  // MARK: Stop point

  func testStopPointIsFirstStandstillFixNotLaterDrift() {
    let (state, _) = run(driveToStop(linkDropsAt: nil) + [
      (660, .location(sample(41.00003, 29.0, speed: 0.2, at: 660))),
      (720, .location(sample(41.00006, 29.0, speed: 0.1, at: 720))),
    ])
    guard case let .driving(trip) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(trip.lastStopFix, sample(41.0, 29.0, speed: 0, at: 600))
    XCTAssertEqual(trip.stoppedAt, at(598))
  }

  /// Walking report 96 s late: the ring buffer holds only walking fixes; the stop fix survives
  /// (anchor only advances to vehicle-speed fixes), so the park point is still the stop.
  func testVeryLateWalkingStillUsesStopFix() {
    var events = driveToStop()
    for i in 1...10 {
      let s = 600 + Double(i) * 10
      events.append((s, .location(sample(41.0 + Double(i) * 0.0001, 29.0, speed: 1.2, at: s, accuracy: 6))))
    }
    events.append((700, .motion(.walking, startedAt: at(604))))
    let (state, effects) = run(events)
    XCTAssertEqual(state.name, "PARKED")
    XCTAssertEqual(parks(effects).first?.location, sample(41.0, 29.0, speed: 0, at: 600))
    XCTAssertEqual(parks(effects).first?.confidence, .high)
  }

  // MARK: Park confidence by order of events

  func testSittingInCarAfterStopKeepsHighConfidence() {
    let (state, _) = run(driveToStop(linkDropsAt: 680) + [
      // GPS silent for 90 s while the user sits in the car, then walks away.
      (692, .motion(.walking, startedAt: at(690))),
      (750, .location(sample(41.0005, 29.0, speed: 1.2, at: 750))),
    ])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.location, sample(41.0, 29.0, speed: 0, at: 600))
    XCTAssertEqual(point.confidence, .high)
  }

  func testGPSDegradedBeforeStopIsLowEvenIfRecent() {
    let (state, _) = run([
      (0, .carLink(connected: true)),
      (10, .location(sample(41.01, 29.01, speed: 12, at: 10))),
      (630, .location(sample(41.0, 29.0, speed: 3, at: 630, accuracy: 6))), // still rolling
      (640, .location(sample(41.0003, 29.0004, speed: 1, at: 640, accuracy: 65))),
      (645, .carLink(connected: false)),
      (650, .motion(.walking)),
      (760, .location(sample(41.0012, 29.0, speed: 1.2, at: 760, accuracy: 10))),
    ])
    guard case let .parked(point) = state else { return XCTFail("got \(state.name)") }
    XCTAssertEqual(point.location.timestamp, at(630))
    XCTAssertEqual(point.confidence, .low)
  }

  // MARK: Car link level

  func testCarLinkLevelSurvivesMaybeDrivingTimeoutWhenEngineReFeedsIt() {
    let (state, effects) = run([
      (0, .carLink(connected: true)),
      (300, .tick), // MAYBE_DRIVING timeout → IDLE
      (400, .motion(.automotive)),
      (400, .carLink(connected: true)), // engine re-reads the route after startGPS
      (420, .location(sample(41.01, 29.01, speed: 10, at: 420))),
    ])
    guard case let .driving(trip) = state else { return XCTFail("got \(state.name)") }
    XCTAssertTrue(trip.hadCarLink)
    XCTAssertTrue(trip.carLinkConnected)
    XCTAssertEqual(effects, [.startGPS, .stopGPS, .startGPS, .beginTrip(startedAt: at(400))])
  }

  // MARK: Persistence compatibility

  func testTripDecodesStateWrittenByOlderBuild() throws {
    let json = #"{"startedAt":1800000000,"hadCarLink":true,"buffer":[{"latitude":41,"longitude":29,"accuracy":5,"speed":0,"timestamp":1800000100}]}"#
    let trip = try TraceFormat.makeDecoder().decode(Trip.self, from: Data(json.utf8))
    XCTAssertTrue(trip.carLinkConnected, "unknown level defaults to hadCarLink (no premature timeout)")
    XCTAssertEqual(trip.lastMovingAt, at(100))
    XCTAssertNil(trip.lastActivity)
    XCTAssertNil(trip.anchor)
  }
}
