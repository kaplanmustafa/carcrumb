import XCTest
@testable import CarCrumbDetection

// Runs only on macOS (CI / EAS). Synthetic inputs; recorded field traces go in fixtures/traces.
final class DetectionReducerTests: XCTestCase {
  let reducer = DetectionReducer()
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

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

  func testNormalDriveWithCarLinkParksAtTransitionPoint() {
    let stop = sample(41.0, 29.0, speed: 0, at: 600)
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (1, .carLink(connected: true)),
      (10, .location(sample(41.01, 29.01, speed: 12, at: 10))),
      (600, .location(stop)),
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
    XCTAssertFalse(effects.contains { if case .saveParking = $0 { return true } else { return false } })
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
    XCTAssertTrue(effects.contains(.endTrip(status: .uncertain, endedAt: t0.addingTimeInterval(660))))
    XCTAssertFalse(effects.contains { if case .saveParking = $0 { return true } else { return false } })
  }

  func testUnconfirmedWakeTimesOutToIdle() {
    let (state, effects) = run([
      (0, .wake(.significantLocationChange)),
      (301, .tick),
    ])
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(effects, [.startGPS, .stopGPS])
  }

  func testPoorAccuracyParkIsLowConfidence() {
    let (state, _) = run([
      (0, .carLink(connected: true)),
      (10, .location(sample(41.0, 29.0, speed: 10, at: 10, accuracy: 65))), // garage, GPS degraded
      (20, .motion(.walking)),
      (80, .location(sample(41.0005, 29.0, speed: 1, at: 80))),
    ])
    guard case let .parked(point) = state else { return XCTFail("expected PARKED") }
    XCTAssertEqual(point.confidence, .low)
  }
}
