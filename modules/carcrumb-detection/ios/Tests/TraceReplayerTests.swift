import XCTest
@testable import CarCrumbDetection

// Runs only on macOS (CI `swift test`). Fixtures are synthetic unless the file name says otherwise.
final class TraceReplayerTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// <repo>/fixtures/traces, resolved from this file:
  /// <repo>/modules/carcrumb-detection/ios/Tests/TraceReplayerTests.swift
  static let tracesDir: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("fixtures/traces", isDirectory: true)
  }()

  func loadTrace(_ name: String) throws -> Data {
    try Data(contentsOf: Self.tracesDir.appendingPathComponent(name))
  }

  // MARK: Fixture replay

  func testSyntheticNormalDriveParksAtTransitionPoint() throws {
    let result = try TraceReplayer().replay(jsonLines: loadTrace("synthetic_normal_drive.jsonl"))

    XCTAssertEqual(result.transitions.map(\.to), ["MAYBE_DRIVING", "DRIVING", "MAYBE_PARKED", "PARKED"])
    guard case let .parked(point) = result.finalState else {
      return XCTFail("expected PARKED, got \(result.finalState.name)")
    }
    let stop = LocationSample(latitude: 41.0, longitude: -40.0, accuracy: 5, speed: 0, timestamp: t0.addingTimeInterval(600))
    XCTAssertEqual(point.location, stop, "park point = buffered point at automotive → walking, not the walked-to point")
    XCTAssertEqual(point.confidence, .high)
    XCTAssertEqual(result.effects, [
      .startGPS,
      .beginTrip(startedAt: t0),
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: t0.addingTimeInterval(660)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  // MARK: Format

  func testRoundTripAllEventKinds() throws {
    let sample = LocationSample(latitude: 41.0, longitude: -40.0, accuracy: 5, speed: 3.5, timestamp: t0)
    let records = [
      TraceRecord(time: t0, event: .wake(.geofenceExit)),
      TraceRecord(time: t0.addingTimeInterval(1), event: .motion(.automotive)),
      TraceRecord(time: t0.addingTimeInterval(2), event: .location(sample)),
      TraceRecord(time: t0.addingTimeInterval(3), event: .carLink(connected: true)),
      TraceRecord(time: t0.addingTimeInterval(4), event: .tick),
      TraceRecord(time: t0.addingTimeInterval(5), event: .motion(.walking, startedAt: t0.addingTimeInterval(-20))),
      TraceRecord(time: t0.addingTimeInterval(6), restore: PersistedDetectionState(
        state: .maybeDriving(since: t0, carLink: true), savedAt: t0, tripID: 3, lastTripEndedAt: t0)),
    ]
    var data = Data()
    for r in records { data.append(try TraceFormat.encodeLine(r)) }
    XCTAssertEqual(data.filter { $0 == 0x0A }.count, records.count, "one record per line")
    XCTAssertEqual(try TraceFormat.decodeLines(data), records)
  }

  /// Security: a PARKED / IDLE restore must not copy coordinates into the trace.
  func testRestingRestoreRecordHasNoCoordinates() throws {
    let s = LocationSample(latitude: 41.123456, longitude: 29.654321, accuracy: 5, speed: 0, timestamp: t0)
    let parked = DetectionState.parked(ParkPoint(location: s, confidence: .high, parkedAt: t0))
    let record = TraceRecord(time: t0.addingTimeInterval(100), restore: PersistedDetectionState(state: parked, savedAt: t0))
    XCTAssertEqual(record.payload, .restoreResting(stateName: "PARKED", savedAt: t0))
    let line = String(decoding: try TraceFormat.encodeLine(record), as: UTF8.self)
    XCTAssertFalse(line.contains("41.123456"))
    XCTAssertFalse(line.contains("29.654321"))
    XCTAssertFalse(line.contains("latitude"))
    XCTAssertEqual(try TraceFormat.decodeLines(Data(line.utf8)), [record])
  }

  func testOpenTripRestoreRecordIsFull() {
    let s = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let persisted = PersistedDetectionState(state: .driving(Trip(startedAt: t0, hadCarLink: true, buffer: [s])), savedAt: t0)
    XCTAssertEqual(TraceRecord(time: t0, restore: persisted).payload, .restore(persisted))
  }

  /// Replay: a resting restore keeps the replay's own PARKED state (with its point) and emits
  /// nothing; from an open-trip state (inconsistent trace) it continues from IDLE.
  func testReplayOfRestingRestore() {
    let s = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let parked = DetectionState.parked(ParkPoint(location: s, confidence: .high, parkedAt: t0))
    let record = TraceRecord(time: t0.addingTimeInterval(100), restore: PersistedDetectionState(state: parked, savedAt: t0))
    let kept = TraceReplayer().replay([record], from: parked)
    XCTAssertEqual(kept.finalState, parked)
    XCTAssertEqual(kept.effects, [])
    XCTAssertEqual(TraceReplayer().replay([record], from: .maybeDriving(since: t0, carLink: false)).finalState, .idle)
    XCTAssertEqual(TraceReplayer().replay([record]).finalState, .idle)
  }

  /// Traces recorded before `startedAt` existed still decode (startedAt = nil).
  func testMotionWithoutStartedAtDecodes() throws {
    let text = "{\"event\":{\"activity\":\"walking\",\"type\":\"motion\"},\"t\":1800000605}\n"
    let records = try TraceFormat.decodeLines(Data(text.utf8))
    XCTAssertEqual(records.first?.event, .motion(.walking, startedAt: nil))
  }

  func testMotionStartedAtIsWrittenOnlyWhenPresent() throws {
    let without = try TraceFormat.encodeLine(TraceRecord(time: t0, event: .motion(.automotive)))
    XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("startedAt"))
    let with = try TraceFormat.encodeLine(TraceRecord(time: t0, event: .motion(.automotive, startedAt: t0)))
    XCTAssertTrue(String(decoding: with, as: UTF8.self).contains("\"startedAt\":1800000000"))
  }

  func testDecodeToleratesBlankLinesAndCRLF() throws {
    let text = "{\"event\":{\"type\":\"tick\"},\"t\":1800000000}\r\n\r\n{\"event\":{\"type\":\"tick\"},\"t\":1800000001}\n"
    let records = try TraceFormat.decodeLines(Data(text.utf8))
    XCTAssertEqual(records.count, 2)
  }

  func testInvalidLineReportsLineNumber() {
    let text = "{\"event\":{\"type\":\"tick\"},\"t\":1800000000}\n{\"event\":{\"type\":\"teleport\"},\"t\":1}\n"
    XCTAssertThrowsError(try TraceFormat.decodeLines(Data(text.utf8))) { error in
      XCTAssertEqual(error as? TraceFormatError, .invalidLine(2, "not a valid trace record"))
    }
  }

  func testDetectionStateRoundTrips() throws {
    let s = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let states: [DetectionState] = [
      .idle,
      .maybeDriving(since: t0, carLink: true),
      .driving(Trip(startedAt: t0, hadCarLink: true, buffer: [s])),
      .maybeParked(trip: Trip(startedAt: t0, hadCarLink: false, buffer: [s]), candidate: s, walkingSince: t0),
      .parked(ParkPoint(location: s, confidence: .low, parkedAt: t0)),
    ]
    let enc = TraceFormat.makeEncoder()
    let dec = TraceFormat.makeDecoder()
    for state in states {
      XCTAssertEqual(try dec.decode(DetectionState.self, from: enc.encode(state)), state)
    }
  }
}

final class DriveStartEstimatorTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

  func testFindsStartOfAutomotiveRunAcrossRedLight() {
    let history = [
      ActivitySpan(start: at(0), activity: .walking),
      ActivitySpan(start: at(300), activity: .automotive), // real start
      ActivitySpan(start: at(600), activity: .stationary), // 60 s red light
      ActivitySpan(start: at(660), activity: .automotive),
    ]
    XCTAssertEqual(DriveStartEstimator.estimateStart(history: history, detectedAt: at(900)), at(300))
  }

  func testLongWalkBreaksTheRun() {
    let history = [
      ActivitySpan(start: at(0), activity: .automotive), // previous trip
      ActivitySpan(start: at(600), activity: .walking), // 30 min walk
      ActivitySpan(start: at(2400), activity: .automotive),
    ]
    XCTAssertEqual(DriveStartEstimator.estimateStart(history: history, detectedAt: at(2500)), at(2400))
  }

  func testNoAutomotiveNearDetectionReturnsNil() {
    let history = [
      ActivitySpan(start: at(0), activity: .automotive),
      ActivitySpan(start: at(100), activity: .walking),
    ]
    XCTAssertNil(DriveStartEstimator.estimateStart(history: history, detectedAt: at(1000)))
    XCTAssertNil(DriveStartEstimator.estimateStart(history: [], detectedAt: at(1000)))
  }

  func testQueryWindowIsBoundedByTwoHoursAndLastTripEnd() {
    let detected = at(10_000)
    XCTAssertEqual(DriveStartEstimator.queryStart(detectedAt: detected, lastTripEndedAt: nil), at(10_000 - 7200))
    XCTAssertEqual(DriveStartEstimator.queryStart(detectedAt: detected, lastTripEndedAt: at(9000)), at(9000))
    XCTAssertEqual(DriveStartEstimator.queryStart(detectedAt: detected, lastTripEndedAt: at(100)), at(10_000 - 7200))
  }
}

final class StateRestorePolicyTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func testParkedRestoresWithoutEffects() {
    let s = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let parked = DetectionState.parked(ParkPoint(location: s, confidence: .high, parkedAt: t0))
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: parked, savedAt: t0), now: t0.addingTimeInterval(86_400))
    XCTAssertEqual(state, parked)
    XCTAssertEqual(fx, [])
  }

  func testFreshDrivingResumesGPS() {
    let driving = DetectionState.driving(Trip(startedAt: t0, hadCarLink: true))
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: driving, savedAt: t0, tripID: 7), now: t0.addingTimeInterval(60))
    XCTAssertEqual(state, driving)
    XCTAssertEqual(fx, [.startGPS])
  }

  func testStaleDrivingClosesTripAsUncertainWithoutParking() {
    let driving = DetectionState.driving(Trip(startedAt: t0, hadCarLink: true))
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: driving, savedAt: t0), now: t0.addingTimeInterval(3600))
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(fx, [.endTrip(status: .uncertain, endedAt: t0)])
  }

  /// Karar E: stale DRIVING whose car link had already dropped and whose last fix was
  /// stationary → low park at the stop point (never high), no stopGPS in a fresh process.
  /// (Updated for the stop model: "stopped" is `stoppedAt`, trip end = `stoppedAt`.)
  func testStaleDrivingAfterLinkLossParksLowAtStopPoint() {
    let stop = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0.addingTimeInterval(50))
    let trip = Trip(startedAt: t0, hadCarLink: true, buffer: [stop], carLinkConnected: false,
                    lastMovingAt: t0.addingTimeInterval(40), stoppedAt: t0.addingTimeInterval(50), lastStopFix: stop)
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: .driving(trip), savedAt: t0.addingTimeInterval(60)), now: t0.addingTimeInterval(3600))
    let point = ParkPoint(location: stop, confidence: .low, parkedAt: t0.addingTimeInterval(50))
    XCTAssertEqual(state, .parked(point))
    XCTAssertEqual(fx, [
      .endTrip(status: .confirmed, endedAt: t0.addingTimeInterval(50)),
      .saveParking(point),
      .setGeofence(center: stop, radius: 150),
    ])
  }

  func testStaleMaybeParkedWithCarLinkParksLowWhateverTheAge() {
    let c = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let mp = DetectionState.maybeParked(trip: Trip(startedAt: t0, hadCarLink: true, buffer: [c]),
                                        candidate: c, walkingSince: t0.addingTimeInterval(5))
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: mp, savedAt: t0.addingTimeInterval(10)), now: t0.addingTimeInterval(7 * 86_400))
    let point = ParkPoint(location: c, confidence: .low, parkedAt: t0)
    XCTAssertEqual(state, .parked(point))
    XCTAssertTrue(fx.contains(.saveParking(point)))
    XCTAssertTrue(fx.contains(.endTrip(status: .confirmed, endedAt: t0.addingTimeInterval(5))))
    XCTAssertFalse(fx.contains(.stopGPS))
  }

  func testStaleMaybeParkedWithoutCarLinkIsUncertain() {
    let c = LocationSample(latitude: 41, longitude: 29, accuracy: 5, speed: 0, timestamp: t0)
    let mp = DetectionState.maybeParked(trip: Trip(startedAt: t0, hadCarLink: false, buffer: [c]),
                                        candidate: c, walkingSince: t0.addingTimeInterval(5))
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: mp, savedAt: t0.addingTimeInterval(10)), now: t0.addingTimeInterval(3600))
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(fx, [.endTrip(status: .uncertain, endedAt: t0.addingTimeInterval(5))])
  }

  func testStaleMaybeDrivingFallsBackToIdle() {
    let (state, fx) = StateRestorePolicy.restore(
      PersistedDetectionState(state: .maybeDriving(since: t0, carLink: false), savedAt: t0),
      now: t0.addingTimeInterval(3600))
    XCTAssertEqual(state, .idle)
    XCTAssertEqual(fx, [])
  }

  func testMissingOrUnknownVersionStartsIdle() {
    XCTAssertEqual(StateRestorePolicy.restore(nil, now: t0).0, .idle)
    let future = PersistedDetectionState(state: .idle, savedAt: t0, version: 99)
    XCTAssertEqual(StateRestorePolicy.restore(future, now: t0).0, .idle)
  }
}
