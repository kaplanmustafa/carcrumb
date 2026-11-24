import Foundation

/// Pure detection state machine: `reduce(state, event, now) -> (state, [Effect])`.
///
/// IDLE → MAYBE_DRIVING → DRIVING → MAYBE_PARKED → PARKED → MAYBE_DRIVING …
/// (Turkish names in docs/DECISIONS.md: Beklemede, OlasiSurus, Surus, OlasiPark, ParkEdildi.)
///
/// Rules (docs/DECISIONS.md, "Algılama mimarisi"):
/// - A stop in traffic is never parking: parking needs walking AND moving
///   `parkConfirmDistance` away from the stop point. Duration alone decides nothing.
/// - Park point = buffered location at the automotive → walking transition, not the last GPS fix.
/// - A trip without a car link ends as `uncertain` and writes no parking.
public struct DetectionReducer: Sendable {
  public var config: DetectionConfig

  public init(config: DetectionConfig = DetectionConfig()) {
    self.config = config
  }

  public func reduce(_ state: DetectionState, _ event: DetectionEvent, now: Date) -> (DetectionState, [Effect]) {
    switch (state, event) {

    // MARK: IDLE / PARKED → MAYBE_DRIVING
    case (.idle, .wake), (.idle, .motion(.automotive)):
      return (.maybeDriving(since: now, carLink: false), [.startGPS])
    case (.idle, .carLink(connected: true)):
      return (.maybeDriving(since: now, carLink: true), [.startGPS])

    case (.parked, .wake), (.parked, .motion(.automotive)):
      return (.maybeDriving(since: now, carLink: false), [.startGPS])
    case (.parked, .carLink(connected: true)):
      return (.maybeDriving(since: now, carLink: true), [.startGPS])

    // MARK: MAYBE_DRIVING
    case let (.maybeDriving(since, carLink), .location(sample)):
      if sample.speed >= config.drivingSpeed {
        // Speed confirms driving. True start time is refined later from
        // CMMotionActivityManager history (queryActivityStarting), outside the reducer.
        let trip = Trip(startedAt: since, hadCarLink: carLink, buffer: [sample])
        return (.driving(trip), [.clearGeofence, .beginTrip(startedAt: since)])
      }
      return timeoutCheck(since: since, now: now) ?? (state, [])
    case let (.maybeDriving(since, _), .carLink(connected: connected)):
      return (.maybeDriving(since: since, carLink: connected), [])
    case let (.maybeDriving(since, _), _):
      return timeoutCheck(since: since, now: now) ?? (state, [])

    // MARK: DRIVING
    case (.driving(var trip), .location(let sample)):
      trip.buffer = appendToBuffer(trip.buffer, sample)
      return (.driving(trip), [])
    case (.driving(var trip), .carLink(connected: true)):
      trip.hadCarLink = true
      return (.driving(trip), [])
    case let (.driving(trip), .motion(.walking)), let (.driving(trip), .motion(.running)):
      guard let candidate = trip.buffer.last else {
        // No location yet: cannot pick a park point. Stay driving until we have one.
        return (state, [])
      }
      return (.maybeParked(trip: trip, candidate: candidate, walkingSince: now), [])

    // MARK: MAYBE_PARKED
    case let (.maybeParked(trip, _, _), .motion(.automotive)):
      // Moving again (traffic, fuel stop): back to the same trip.
      return (.driving(trip), [])
    case let (.maybeParked(trip, candidate, _), .location(sample)):
      if sample.speed >= config.drivingSpeed {
        var resumed = trip
        resumed.buffer = appendToBuffer(trip.buffer, sample)
        return (.driving(resumed), [])
      }
      if sample.distance(to: candidate) >= config.parkConfirmDistance {
        return finishTrip(trip, candidate: candidate, now: now)
      }
      return (state, [])
    case (.maybeParked(var trip, let candidate, let since), .carLink(connected: true)):
      trip.hadCarLink = true
      return (.maybeParked(trip: trip, candidate: candidate, walkingSince: since), [])

    default:
      return (state, [])
    }
  }

  // MARK: Helpers

  private func timeoutCheck(since: Date, now: Date) -> (DetectionState, [Effect])? {
    guard now.timeIntervalSince(since) >= config.maybeDrivingTimeout else { return nil }
    return (.idle, [.stopGPS])
  }

  private func appendToBuffer(_ buffer: [LocationSample], _ sample: LocationSample) -> [LocationSample] {
    let cutoff = sample.timestamp.addingTimeInterval(-config.bufferWindow)
    return (buffer + [sample]).filter { $0.timestamp >= cutoff }
  }

  private func finishTrip(_ trip: Trip, candidate: LocationSample, now: Date) -> (DetectionState, [Effect]) {
    guard trip.hadCarLink else {
      // Bus / taxi / someone else's car: keep the trip as "uncertain", write no parking.
      return (.idle, [.stopGPS, .endTrip(status: .uncertain, endedAt: now)])
    }
    let accurate = candidate.accuracy >= 0 && candidate.accuracy <= config.goodAccuracy
    let point = ParkPoint(location: candidate, confidence: accurate ? .high : .low, parkedAt: candidate.timestamp)
    return (.parked(point), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: now),
      .saveParking(point),
      .setGeofence(center: candidate, radius: config.geofenceRadius),
    ])
  }
}
