import Foundation

// Route retention (docs/DECISIONS.md, "Rota saklama süresi"): route points of trips that
// ended before the limit are deleted (+ WAL truncate); the trip row itself (dates, duration,
// distance, status) stays. Foundation only (no CoreLocation, no I/O besides UserDefaults in
// `RouteRetentionSettings`), so it is tested with `swift test`.

/// User setting. Raw values are the JS bridge values (`getRouteRetention` /
/// `setRouteRetention`, src/CarCrumbDetection.types.ts `RouteRetention`) and the stored
/// UserDefaults value: never rename them.
public enum RouteRetention: String, CaseIterable, Sendable {
  case threeMonths
  case twelveMonths
  case forever

  /// docs/DECISIONS.md: 12 months unless the user chose otherwise.
  public static let `default`: RouteRetention = .twelveMonths

  /// Trips that ended before this instant lose their route; nil = keep forever.
  /// Calendar months (Gregorian, UTC: independent of the device time zone, so the same
  /// instant always gives the same limit), not a fixed number of days, rounded down to the
  /// start of that UTC day. The rounding keeps the limit monotonic: month-end clamping
  /// (31 May → 28/29 Feb) would otherwise make it step back by hours as `now` advances.
  public func cutoff(now: Date) -> Date? {
    let months: Int
    switch self {
    case .threeMonths: months = 3
    case .twelveMonths: months = 12
    case .forever: return nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(byAdding: .month, value: -months, to: now).map { calendar.startOfDay(for: $0) }
  }
}

/// When the periodic purge runs (besides engine start and a setting change, which always run).
public enum RoutePurgeSchedule {
  /// At most once a day.
  public static let interval: TimeInterval = 24 * 60 * 60

  /// Due when it never ran, a day has passed, or the clock is now before the last run (clock
  /// set back: the stored time is meaningless, so running once more is the safe side).
  public static func isDue(lastRun: Date?, now: Date) -> Bool {
    guard let lastRun else { return true }
    let elapsed = now.timeIntervalSince(lastRun)
    return elapsed < 0 || elapsed >= interval
  }
}

/// The setting and the last purge time in `UserDefaults` (no app group: only the app process
/// reads it). The engine reads it on its queue also when iOS relaunches the app in the
/// background without JS, so the setting cannot live on the JS side. No coordinates here.
/// `UserDefaults` is thread-safe; the engine still only writes on its serial queue.
public final class RouteRetentionSettings: @unchecked Sendable {
  public static let retentionKey = "carcrumb.routeRetention"
  public static let lastPurgeKey = "carcrumb.routeRetention.lastPurgeAt"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unknown / missing stored value → the default (12 months).
  public var retention: RouteRetention {
    get { defaults.string(forKey: Self.retentionKey).flatMap(RouteRetention.init(rawValue:)) ?? .default }
    set { defaults.set(newValue.rawValue, forKey: Self.retentionKey) }
  }

  public var lastPurgeAt: Date? {
    get { defaults.object(forKey: Self.lastPurgeKey) as? Date }
    set { defaults.set(newValue, forKey: Self.lastPurgeKey) }
  }
}
