import Foundation

/// Pure detection state machine: `reduce(state, event, now) -> (state, [Effect])`.
///
/// IDLE → MAYBE_DRIVING → DRIVING → MAYBE_PARKED → PARKED → MAYBE_DRIVING …
/// (Turkish names in docs/DECISIONS.md: Beklemede, OlasiSurus, Surus, OlasiPark, ParkEdildi.)
///
/// Rules (docs/DECISIONS.md, "Algılama mimarisi → Kurallar"):
/// - A stop in traffic is never parking: parking needs walking AND moving
///   `parkConfirmDistance` away from the stop point (minus the sample's accuracy), at walking
///   speed, with the car link disconnected. Duration alone never confirms a high-confidence park.
/// - Park point = last good-accuracy buffered location before the walking start reported by
///   Core Motion (not the last GPS fix, not the time the event arrived). Stale or inaccurate
///   candidates are kept but flagged low confidence.
/// - Timeouts (Karar A/B): MAYBE_PARKED ends after `maybeParkedTimeout` (back to DRIVING if the
///   car link is still connected); DRIVING ends after `drivingStationaryTimeout` without
///   movement once the car link is gone, and after `drivingHardStationaryTimeout` without
///   movement even with the link connected. GPS never stays
///   on without a bound on a stationary phone.
/// - A trip without a car link ends as `uncertain` and writes no parking.
/// - The geofence only changes with a new park (Karar D); the reducer never clears it.
public struct DetectionReducer: Sendable {
  public var config: DetectionConfig

  public init(config: DetectionConfig = DetectionConfig()) {
    self.config = config
  }

  public func reduce(_ state: DetectionState, _ event: DetectionEvent, now: Date) -> (DetectionState, [Effect]) {
    switch state {
    case .idle, .parked:
      return reduceResting(state, event, now: now)
    case let .maybeDriving(since, carLink):
      return reduceMaybeDriving(since: since, carLink: carLink, event, now: now)
    case let .driving(trip):
      return reduceDriving(trip, event, now: now)
    case let .maybeParked(trip, candidate, walkingSince):
      return reduceMaybeParked(trip, candidate: candidate, walkingSince: walkingSince, event, now: now)
    }
  }

  // MARK: IDLE / PARKED → MAYBE_DRIVING

  private func reduceResting(_ state: DetectionState, _ event: DetectionEvent, now: Date) -> (DetectionState, [Effect]) {
    switch event {
    case .wake, .motion(.automotive, _):
      // The engine re-reads the audio route after this startGPS and feeds `.carLink(true)`
      // if a car is already connected (the sensor itself only reports changes).
      return (.maybeDriving(since: now, carLink: false), [.startGPS])
    case .carLink(connected: true):
      return (.maybeDriving(since: now, carLink: true), [.startGPS])
    default:
      return (state, [])
    }
  }

  // MARK: MAYBE_DRIVING

  private func reduceMaybeDriving(since: Date, carLink: Bool, _ event: DetectionEvent, now: Date) -> (DetectionState, [Effect]) {
    let state = DetectionState.maybeDriving(since: since, carLink: carLink)
    switch event {
    case let .location(sample) where sample.speed >= config.drivingSpeed:
      // Speed confirms driving. True start time is refined later from Core Motion history
      // (queryActivityStarting), outside the reducer. No clearGeofence here (Karar D).
      let trip = Trip(startedAt: since, hadCarLink: carLink, buffer: [sample],
                      carLinkConnected: carLink, lastMovingAt: now)
      return (.driving(trip), [.beginTrip(startedAt: since)])
    case let .carLink(connected):
      return (.maybeDriving(since: since, carLink: connected), [])
    default:
      guard now.timeIntervalSince(since) >= config.maybeDrivingTimeout else { return (state, []) }
      return (.idle, [.stopGPS])
    }
  }

  // MARK: DRIVING

  private func reduceDriving(_ trip: Trip, _ event: DetectionEvent, now: Date) -> (DetectionState, [Effect]) {
    var trip = trip
    switch event {
    case let .location(sample):
      append(sample, to: &trip)
      if sample.speed >= config.movingSpeed { trip.lastMovingAt = now }

    case let .carLink(connected):
      trip.carLinkConnected = connected
      if connected { trip.hadCarLink = true }

    case let .motion(activity, startedAt):
      trip.lastActivity = activity
      switch activity {
      case .automotive:
        trip.lastMovingAt = now
      case .walking, .running:
        let transition = startedAt ?? now
        guard let candidate = pickCandidate(trip, transitionAt: transition) else {
          // No location at all yet: cannot pick a park point. Stay driving; the stationary
          // timeout still bounds GPS.
          return checkDrivingTimeout(trip, now: now)
        }
        let next = DetectionState.maybeParked(trip: trip, candidate: candidate, walkingSince: transition)
        // A late walking report: the buffer may already hold walking samples far enough away.
        if let latest = trip.buffer.last, latest.timestamp > transition,
           confirmsParking(latest, trip: trip, candidate: candidate) {
          return finishTrip(trip, candidate: candidate, walkingSince: transition, now: now)
        }
        // The walking start may lie in the past; the timeout counts from it.
        if now.timeIntervalSince(transition) >= config.maybeParkedTimeout {
          // Car link still connected: not a park (Karar C); stay in DRIVING.
          if trip.carLinkConnected { return checkDrivingTimeout(trip, now: now) }
          return maybeParkedTimedOut(trip, candidate: candidate, walkingSince: transition)
        }
        return (next, [])
      default:
        break
      }

    case .wake, .tick:
      break
    }
    return checkDrivingTimeout(trip, now: now)
  }

  /// Karar B: no movement for `drivingStationaryTimeout` and no car link → trip over, park at
  /// the stop point with low confidence (phone left in the car; never saw walking).
  /// Hard cap: no movement for `drivingHardStationaryTimeout` ends the trip even with the car
  /// link still connected (engine idling, CarPlay left on), so GPS is never on without bound.
  private func checkDrivingTimeout(_ trip: Trip, now: Date) -> (DetectionState, [Effect]) {
    let stationaryFor = now.timeIntervalSince(trip.lastMovingAt)
    let linkLostTimeout = !trip.carLinkConnected && stationaryFor >= config.drivingStationaryTimeout
    let hardTimeout = stationaryFor >= config.drivingHardStationaryTimeout
    guard linkLostTimeout || hardTimeout else { return (.driving(trip), []) }
    return closeAtStopPoint(trip)
  }

  /// Ends a DRIVING trip whose end was not observed (stationary timeout, stale restore):
  /// `confirmed` + low park at the stop point with car link, `uncertain` without.
  /// Trip end = last movement, not the time we noticed.
  func closeAtStopPoint(_ trip: Trip) -> (DetectionState, [Effect]) {
    let endedAt = trip.lastMovingAt
    guard trip.hadCarLink, let stop = stopPoint(trip) else {
      return (.idle, [.stopGPS, .endTrip(status: trip.hadCarLink ? .confirmed : .uncertain, endedAt: endedAt)])
    }
    let point = ParkPoint(location: stop, confidence: .low, parkedAt: endedAt)
    return (.parked(point), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: endedAt),
      .saveParking(point),
      .setGeofence(center: stop, radius: config.geofenceRadius),
    ])
  }

  /// Where the car stopped: the latest good fix we still know, else the most accurate one.
  private func stopPoint(_ trip: Trip) -> LocationSample? {
    pickCandidate(trip, transitionAt: .distantFuture)
  }

  // MARK: MAYBE_PARKED

  private func reduceMaybeParked(
    _ trip: Trip, candidate: LocationSample, walkingSince: Date, _ event: DetectionEvent, now: Date
  ) -> (DetectionState, [Effect]) {
    var trip = trip
    switch event {
    case .motion(.automotive, _):
      // Moving again (traffic, fuel stop): back to the same trip.
      trip.lastActivity = .automotive
      trip.lastMovingAt = now
      return (.driving(trip), [])

    case let .location(sample):
      append(sample, to: &trip)
      if sample.speed >= config.drivingSpeed {
        trip.lastMovingAt = now
        return (.driving(trip), [])
      }
      if confirmsParking(sample, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, walkingSince: walkingSince, now: now)
      }

    case let .carLink(connected):
      trip.carLinkConnected = connected
      if connected { trip.hadCarLink = true }
      // Link dropped after the user already walked away: confirm with the latest sample.
      if !connected, let latest = trip.buffer.last, latest.timestamp > walkingSince,
         confirmsParking(latest, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, walkingSince: walkingSince, now: now)
      }

    case let .motion(activity, _):
      trip.lastActivity = activity
      if activity == .walking || activity == .running, let latest = trip.buffer.last,
         latest.timestamp > walkingSince, confirmsParking(latest, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, walkingSince: walkingSince, now: now)
      }

    case .wake, .tick:
      break
    }

    if now.timeIntervalSince(walkingSince) >= config.maybeParkedTimeout {
      // Car link still connected after 10 min: no park (Karar C); back to the same trip in
      // DRIVING. Karar B and the hard cap bound GPS from there.
      if trip.carLinkConnected { return checkDrivingTimeout(trip, now: now) }
      return maybeParkedTimedOut(trip, candidate: candidate, walkingSince: walkingSince)
    }
    return (.maybeParked(trip: trip, candidate: candidate, walkingSince: walkingSince), [])
  }

  /// Karar C: last activity walking/running, walking speed, far enough after subtracting the
  /// sample's accuracy, and the car link no longer connected.
  private func confirmsParking(_ sample: LocationSample, trip: Trip, candidate: LocationSample) -> Bool {
    guard trip.lastActivity == .walking || trip.lastActivity == .running else { return false }
    guard !trip.carLinkConnected else { return false }
    // Negative speed = unknown: cannot rule out a creeping car, so it does not confirm
    // (the MAYBE_PARKED timeout still ends the trip).
    guard sample.speed >= 0, sample.speed <= config.maxWalkingSpeed else { return false }
    let margin = max(sample.accuracy, 0)
    return sample.distance(to: candidate) - margin >= config.parkConfirmDistance
  }

  /// Karar A: no confirmation within `maybeParkedTimeout` of the walking start.
  /// With car link: confirmed + low park at the candidate. Without: uncertain, no park.
  func maybeParkedTimedOut(_ trip: Trip, candidate: LocationSample, walkingSince: Date) -> (DetectionState, [Effect]) {
    guard trip.hadCarLink else {
      return (.idle, [.stopGPS, .endTrip(status: .uncertain, endedAt: walkingSince)])
    }
    let point = ParkPoint(location: candidate, confidence: .low, parkedAt: candidate.timestamp)
    return (.parked(point), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: walkingSince),
      .saveParking(point),
      .setGeofence(center: candidate, radius: config.geofenceRadius),
    ])
  }

  private func finishTrip(_ trip: Trip, candidate: LocationSample, walkingSince: Date, now: Date) -> (DetectionState, [Effect]) {
    guard trip.hadCarLink else {
      // Bus / taxi / someone else's car: keep the trip as "uncertain", write no parking.
      return (.idle, [.stopGPS, .endTrip(status: .uncertain, endedAt: now)])
    }
    let point = ParkPoint(location: candidate, confidence: confidence(of: candidate, walkingSince: walkingSince),
                          parkedAt: candidate.timestamp)
    return (.parked(point), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: now),
      .saveParking(point),
      .setGeofence(center: candidate, radius: config.geofenceRadius),
    ])
  }

  // MARK: Park point selection

  func isGoodFix(_ s: LocationSample) -> Bool {
    s.accuracy >= 0 && s.accuracy <= config.goodAccuracy
  }

  /// High only for a good-accuracy fix taken at most `maxCandidateAge` before the walking start.
  func confidence(of candidate: LocationSample, walkingSince: Date) -> Confidence {
    let age = walkingSince.timeIntervalSince(candidate.timestamp)
    return isGoodFix(candidate) && age >= 0 && age <= config.maxCandidateAge ? .high : .low
  }

  /// Park candidate for an automotive → walking transition at `transitionAt`:
  /// 1. the last good-accuracy fix at or before the transition (buffer + anchor),
  /// 2. else the most accurate fix before it (confidence will be low),
  /// 3. else the earliest known fix (all fixes are after the transition; low confidence).
  func pickCandidate(_ trip: Trip, transitionAt: Date) -> LocationSample? {
    let pool = (trip.anchor.map { [$0] } ?? []) + trip.buffer
    let before = pool.filter { $0.timestamp <= transitionAt }
    if let good = before.last(where: isGoodFix) { return good }
    let valid = before.filter { $0.accuracy >= 0 }
    // Latest among equally accurate fixes.
    if let best = valid.reversed().min(by: { $0.accuracy < $1.accuracy }) { return best }
    if let any = before.last { return any }
    return pool.first
  }

  /// Ring buffer of `bufferWindow` seconds. The newest good fix that falls out becomes the anchor.
  private func append(_ sample: LocationSample, to trip: inout Trip) {
    let cutoff = sample.timestamp.addingTimeInterval(-config.bufferWindow)
    let all = trip.buffer + [sample]
    let evicted = all.filter { $0.timestamp < cutoff }
    trip.buffer = all.filter { $0.timestamp >= cutoff }
    if let newest = evicted.last(where: isGoodFix),
       trip.anchor.map({ newest.timestamp >= $0.timestamp }) ?? true {
      trip.anchor = newest
    }
  }
}
