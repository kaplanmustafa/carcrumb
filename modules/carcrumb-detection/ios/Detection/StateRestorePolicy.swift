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

  public init(state: DetectionState, savedAt: Date, tripID: Int64? = nil, version: Int = PersistedDetectionState.currentVersion) {
    self.version = version
    self.state = state
    self.savedAt = savedAt
    self.tripID = tripID
  }
}

/// Pure decision for what to do with a persisted state at launch. Lives outside the reducer
/// on purpose: it is not a sensor event, and the reducer stays unchanged.
///
/// - IDLE / PARKED: restore as-is (geofence is persisted by CLMonitor itself).
/// - GPS states saved recently (< `maxResumeAge`): restore and re-emit `.startGPS`, because
///   a fresh process has no live location stream / background activity session.
/// - MAYBE_DRIVING too old: back to IDLE (the 5 min confirmation window has long passed).
/// - DRIVING / MAYBE_PARKED too old: the trip was interrupted and we can no longer pick a
///   trustworthy park point (the ring buffer is stale; the car may have moved on).
///   Close it as `uncertain` at the last known time and write no parking — same rule as a
///   trip without car link: better no park point than a wrong one.
public enum StateRestorePolicy {
  public static let defaultMaxResumeAge: TimeInterval = 15 * 60

  public static func restore(
    _ persisted: PersistedDetectionState?,
    now: Date,
    maxResumeAge: TimeInterval = defaultMaxResumeAge
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
    case .driving, .maybeParked:
      if fresh { return (persisted.state, [.startGPS]) }
      return (.idle, [.endTrip(status: .uncertain, endedAt: persisted.savedAt)])
    }
  }
}
