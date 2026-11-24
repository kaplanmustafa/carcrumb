import Foundation

/// What the engine persists so detection survives the app being terminated
/// (jetsam, force-quit, reboot) and relaunched in the background by a location event.
public struct PersistedDetectionState: Equatable, Codable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var state: DetectionState
  public var savedAt: Date
  /// Store id of the open trip (DRIVING / MAYBE_PARKED), so endTrip after a relaunch
  /// closes the right row.
  public var tripID: Int64?
  /// End of the last closed trip. Bounds the Core Motion history query for the real start of
  /// the next trip. Optional: absent in files written by older builds.
  public var lastTripEndedAt: Date?

  public init(
    state: DetectionState,
    savedAt: Date,
    tripID: Int64? = nil,
    lastTripEndedAt: Date? = nil,
    version: Int = PersistedDetectionState.currentVersion
  ) {
    self.version = version
    self.state = state
    self.savedAt = savedAt
    self.tripID = tripID
    self.lastTripEndedAt = lastTripEndedAt
  }
}

/// Pure decision for what to do with a persisted state at launch. Lives outside the reducer
/// on purpose: it is not a sensor event. It reuses the reducer's closing rules so a restored
/// trip ends exactly like a live one would.
///
/// - IDLE / PARKED: restore as-is (geofence is persisted by CLMonitor itself).
/// - GPS states saved recently (< `maxResumeAge`): restore and re-emit `.startGPS`, because
///   a fresh process has no live location stream / background activity session. A resumed
///   MAYBE_PARKED is still bounded by the reducer's 10 min timeout (Karar A).
/// - MAYBE_DRIVING too old: back to IDLE (the confirmation window has long passed).
/// - MAYBE_PARKED too old (Karar E): with car link → closed as `confirmed` with a
///   low-confidence park at the candidate, whatever the age; without → `uncertain`, no park.
/// - DRIVING too old (Karar E, "at most low"): the ring buffer is stale and the car may have
///   driven on, so a park is written only when the saved trip already looked like the end of
///   a drive (car link had dropped and the car had stopped); it is then low confidence
///   at the stop point. Otherwise `uncertain` at the save time, no park.
public enum StateRestorePolicy {
  public static let defaultMaxResumeAge: TimeInterval = 15 * 60

  public static func restore(
    _ persisted: PersistedDetectionState?,
    now: Date,
    maxResumeAge: TimeInterval = defaultMaxResumeAge,
    reducer: DetectionReducer = DetectionReducer()
  ) -> (DetectionState, [Effect]) {
    guard let persisted, persisted.version == PersistedDetectionState.currentVersion else {
      return (.idle, [])
    }
    let age = now.timeIntervalSince(persisted.savedAt)
    let fresh = age >= 0 && age < maxResumeAge

    switch persisted.state {
    case .idle, .parked:
      return (persisted.state, [])
    case .maybeDriving:
      return fresh ? (persisted.state, [.startGPS]) : (.idle, [])
    case .driving(let trip):
      if fresh { return (persisted.state, [.startGPS]) }
      // The car had stopped (a fix below driving speed after the last movement) when the state was saved.
      if trip.hadCarLink, !trip.carLinkConnected, trip.stoppedAt != nil {
        return withoutStopGPS(reducer.closeAtStopPoint(trip))
      }
      return (.idle, [.endTrip(status: .uncertain, endedAt: persisted.savedAt)])
    case let .maybeParked(trip, candidate, walkingSince):
      if fresh { return (persisted.state, [.startGPS]) }
      return withoutStopGPS(reducer.maybeParkedTimedOut(trip, candidate: candidate, walkingSince: walkingSince))
    }
  }

  /// A relaunched process has no GPS session to stop.
  private static func withoutStopGPS(_ result: (DetectionState, [Effect])) -> (DetectionState, [Effect]) {
    (result.0, result.1.filter { $0 != .stopGPS })
  }
}
