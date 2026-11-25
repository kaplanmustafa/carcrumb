import Foundation

/// What happened when history deletion tried to remove the park geofence (CLMonitor
/// condition `lastPark`). Produced by `LocationSensor.clearGeofenceVerified()`.
public enum GeofenceClearResult: String, Equatable, Sendable {
  /// The monitor is open and no longer lists the condition.
  case removed
  /// The monitor is open but still lists the condition after the removal.
  case stillPresent
  /// The monitor could not be opened (typically no location permission: konumsuz mod), or
  /// the engine has no location sensor.
  case monitorUnavailable
}

/// Pure decision for the geofence step of "Geçmişi sil" (docs/DECISIONS.md checklist).
///
/// The app must stay usable without location permission (CLAUDE.md: konumsuz mod), so a
/// missing monitor is not a failure:
/// - Without a monitor there is nothing this process can remove, and no condition can be
///   added either (every `setGeofence` goes through the same monitor), so there is nothing
///   left that deletion could leave behind from this app's side.
/// - If authorization is not `authorizedAlways` / `authorizedWhenInUse` (e.g. revoked after
///   a park was written), a condition still registered with CLMonitor is inert: Core Location
///   delivers no events and no relaunch for it. It is removed at the next deletion or
///   replaced at the next park once permission is back.
/// Only a monitor that is open and still lists `lastPark` after the removal is a failure:
/// then a coordinate-bearing condition provably survived the deletion.
public enum GeofenceClearPolicy {
  public static func succeeded(_ result: GeofenceClearResult) -> Bool {
    switch result {
    case .removed, .monitorUnavailable: return true
    case .stillPresent: return false
    }
  }
}
