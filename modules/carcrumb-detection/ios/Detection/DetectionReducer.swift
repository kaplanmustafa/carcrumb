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
/// - Movement evidence is a GPS fix at vehicle speed (> `maxWalkingSpeed`, slow traffic included); driving confirmation separately needs `drivingSpeed`. Walking speed and a bare Core Motion
///   `automotive` (idling engine vibration) do not reset the stationary clock.
/// - Park point = last good-accuracy fix at or before the walking start reported by Core Motion,
///   taken from the ring buffer, the stop point (`lastStopFix`) and the moving-only anchor.
///   A walking fix is never a candidate.
/// - Park confidence is decided by the order of events, not by age: a good fix taken with the
///   car standing still is high even if GPS went silent afterwards (user sat in the car); a
///   fix taken while still moving (GPS degraded / lost before the car stopped) is low.
/// - Timeouts (Karar A/B + hard cap): MAYBE_PARKED ends after `maybeParkedTimeout` (back to
///   DRIVING if the car link is still connected); DRIVING ends after
///   `drivingStationaryTimeout` without movement once the car link is gone, and after
///   `drivingHardStationaryTimeout` without movement even with the link connected.
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
                      carLinkConnected: carLink, lastMovingAt: now,
                      lastStopFix: isGoodFix(sample) ? sample : nil, lastApproachFix: sample)
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
      ingest(sample, into: &trip, now: now)

    case let .carLink(connected):
      trip.carLinkConnected = connected
      if connected { trip.hadCarLink = true }

    case let .motion(activity, startedAt):
      trip.lastActivity = activity
      if activity == .walking || activity == .running {
        let transition = startedAt ?? now
        guard let candidate = pickCandidate(trip, transitionAt: transition) else {
          // No vehicle fix at all yet: cannot pick a park point. Stay driving; the stationary
          // timeouts still bound GPS.
          return checkDrivingTimeout(trip, now: now)
        }
        // A late walking report: the buffer may already hold walking fixes far enough away.
        if let latest = trip.buffer.last, latest.timestamp > transition,
           confirmsParking(latest, trip: trip, candidate: candidate) {
          return finishTrip(trip, candidate: candidate, now: now)
        }
        // The walking start may lie in the past; the timeout counts from it.
        if now.timeIntervalSince(transition) >= config.maybeParkedTimeout {
          // Car link still connected: not a park (Karar C); stay in DRIVING.
          if trip.carLinkConnected { return checkDrivingTimeout(trip, now: now) }
          return maybeParkedTimedOut(trip, candidate: candidate, walkingSince: transition)
        }
        return (.maybeParked(trip: trip, candidate: candidate, walkingSince: transition), [])
      }
      // `automotive` alone is not movement evidence (idling vibration flips it).

    case .wake, .tick:
      // Wake is not movement evidence either (SLC/visit are coarse and fire at standstill);
      // the engine re-syncs the car link level before reducing a wake instead.
      break
    }
    return checkDrivingTimeout(trip, now: now)
  }

  /// Karar B: no movement for `drivingStationaryTimeout` and no car link → trip over, park at
  /// the stop point with low confidence (phone left in the car; never saw walking).
  /// Hard cap: no movement for `drivingHardStationaryTimeout` ends the trip even with the car
  /// link still connected (engine idling, CarPlay left on), so GPS is never on without bound.
  private func checkDrivingTimeout(_ trip: Trip, now: Date) -> (DetectionState, [Effect]) {
    let stationaryFor = now.timeIntervalSince(trip.stationarySince)
    let linkLostTimeout = !trip.carLinkConnected && stationaryFor >= config.drivingStationaryTimeout
    let hardTimeout = stationaryFor >= config.drivingHardStationaryTimeout
    guard linkLostTimeout || hardTimeout else { return (.driving(trip), []) }
    return closeAtStopPoint(trip)
  }

  /// Ends a DRIVING trip whose end was not observed (stationary timeouts, stale restore):
  /// `confirmed` + low park at the stop point with car link, `uncertain` without.
  /// Trip end = when the car stopped, not the time we noticed.
  func closeAtStopPoint(_ trip: Trip) -> (DetectionState, [Effect]) {
    let endedAt = trip.stationarySince
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

  /// Where the car stopped: the tracked stop fix, else the latest vehicle fix we still know.
  private func stopPoint(_ trip: Trip) -> LocationSample? {
    trip.lastStopFix ?? pickCandidate(trip, transitionAt: .distantFuture)
  }

  // MARK: MAYBE_PARKED

  private func reduceMaybeParked(
    _ trip: Trip, candidate: LocationSample, walkingSince: Date, _ event: DetectionEvent, now: Date
  ) -> (DetectionState, [Effect]) {
    var trip = trip
    switch event {
    case .motion(.automotive, _):
      // Core Motion says we are in a vehicle again (traffic, fuel stop): back to the same
      // trip. Not movement evidence for the stationary clock.
      trip.lastActivity = .automotive
      return checkDrivingTimeout(trip, now: now)

    case let .location(sample):
      // The user is walking: fixes may be pedestrian standstills, so they never update the
      // stop point here (only driving speed resets it).
      ingest(sample, into: &trip, now: now, trackStop: false)
      if sample.speed >= config.drivingSpeed {
        return (.driving(trip), [])
      }
      if confirmsParking(sample, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, now: now)
      }

    case let .carLink(connected):
      trip.carLinkConnected = connected
      if connected { trip.hadCarLink = true }
      // Link dropped after the user already walked away: confirm with the latest sample.
      if !connected, let latest = trip.buffer.last, latest.timestamp > walkingSince,
         confirmsParking(latest, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, now: now)
      }

    case let .motion(activity, _):
      trip.lastActivity = activity
      if activity == .walking || activity == .running, let latest = trip.buffer.last,
         latest.timestamp > walkingSince, confirmsParking(latest, trip: trip, candidate: candidate) {
        return finishTrip(trip, candidate: candidate, now: now)
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

  /// Karar A: no confirmation within `maybeParkedTimeout` of the walking start (car link not
  /// connected; the reducer handles the connected case before calling this).
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

  private func finishTrip(_ trip: Trip, candidate: LocationSample, now: Date) -> (DetectionState, [Effect]) {
    guard trip.hadCarLink else {
      // Bus / taxi / someone else's car: keep the trip as "uncertain", write no parking.
      return (.idle, [.stopGPS, .endTrip(status: .uncertain, endedAt: now)])
    }
    let point = ParkPoint(location: candidate, confidence: confidence(of: candidate), parkedAt: candidate.timestamp)
    return (.parked(point), [
      .stopGPS,
      .endTrip(status: .confirmed, endedAt: now),
      .saveParking(point),
      .setGeofence(center: candidate, radius: config.geofenceRadius),
    ])
  }

  // MARK: Motion / stop tracking

  /// Appends a fix and updates the movement / stop bookkeeping.
  private func ingest(_ sample: LocationSample, into trip: inout Trip, now: Date, trackStop: Bool = true) {
    append(sample, to: &trip)
    let standstill = isStandstillFix(sample)
    defer { if !standstill { trip.lastApproachFix = sample } }

    if isVehicleSpeed(sample) {
      // Moving (slow traffic included): any previous stop (red light, jam) is over, and the
      // stationary clock restarts. Provisional stop point = latest good vehicle fix.
      trip.lastMovingAt = now
      trip.stoppedAt = nil
      if isGoodFix(sample) {
        trip.lastStopFix = sample
      } else if trip.lastStopFix.map(isStandstillFix) ?? false {
        trip.lastStopFix = nil // the old standstill is stale; no good vehicle fix to replace it
      }
      return
    }
    // At or below walking speed (or unknown speed): not movement evidence.
    if trip.stoppedAt == nil { trip.stoppedAt = now }
    guard trackStop, standstill else { return }
    // First accepted standstill wins; later in-car GPS drift does not move the stop point.
    guard !(trip.lastStopFix.map(isStandstillFix) ?? false) else { return }
    // Only where the car plausibly is: near the last non-standstill fix. A standstill fix
    // far from it (GPS lost in a car park, phone later on a desk) is not the car.
    if let approach = trip.lastApproachFix, sample.distance(to: approach) >= config.parkConfirmDistance {
      return
    }
    trip.lastStopFix = sample
    // Walking-speed fixes (stoppedSpeed < speed <= maxWalkingSpeed) never become the stop point.
  }

  // MARK: Park point selection

  func isGoodFix(_ s: LocationSample) -> Bool {
    s.accuracy >= 0 && s.accuracy <= config.goodAccuracy
  }

  /// Good accuracy, car standing still.
  func isStandstillFix(_ s: LocationSample) -> Bool {
    isGoodFix(s) && s.speed >= 0 && s.speed <= config.stoppedSpeed
  }

  /// Faster than walking: the fix was taken in a moving vehicle.
  func isVehicleSpeed(_ s: LocationSample) -> Bool {
    s.speed > config.maxWalkingSpeed
  }

  /// Order of events, not age (DECISIONS "Park noktası"): high only for a good fix taken with
  /// the car standing still. A candidate taken while still moving means GPS degraded or was
  /// lost before the car stopped (indoor car park) → low.
  func confidence(of candidate: LocationSample) -> Confidence {
    isStandstillFix(candidate) ? .high : .low
  }

  /// Park candidate for an automotive → walking transition at `transitionAt`, from the buffer,
  /// the stop fix and the moving-only anchor:
  /// 1. the last good-accuracy fix at or before the transition,
  /// 2. else the most accurate fix before it (confidence will be low),
  /// 3. else the stop fix, else the anchor (both vehicle fixes, even if after the transition).
  /// Fixes after the transition are never picked from the buffer: they are walking fixes.
  func pickCandidate(_ trip: Trip, transitionAt: Date) -> LocationSample? {
    var pool: [LocationSample] = []
    for s in [trip.anchor, trip.lastStopFix].compactMap({ $0 }) + trip.buffer where !pool.contains(s) {
      pool.append(s)
    }
    pool.sort { $0.timestamp < $1.timestamp }
    let before = pool.filter { $0.timestamp <= transitionAt }
    if let good = before.last(where: isGoodFix) { return good }
    let valid = before.filter { $0.accuracy >= 0 }
    // Latest among equally accurate fixes.
    if let best = valid.reversed().min(by: { $0.accuracy < $1.accuracy }) { return best }
    if let any = before.last { return any }
    return trip.lastStopFix ?? trip.anchor
  }

  /// Ring buffer of `bufferWindow` seconds. The newest evicted good fix taken at vehicle speed
  /// becomes the anchor; standstill and walking fixes never move it.
  private func append(_ sample: LocationSample, to trip: inout Trip) {
    let cutoff = sample.timestamp.addingTimeInterval(-config.bufferWindow)
    let all = trip.buffer + [sample]
    let evicted = all.filter { $0.timestamp < cutoff }
    trip.buffer = all.filter { $0.timestamp >= cutoff }
    if let newest = evicted.last(where: { isGoodFix($0) && isVehicleSpeed($0) }),
       trip.anchor.map({ newest.timestamp >= $0.timestamp }) ?? true {
      trip.anchor = newest
    }
  }
}
