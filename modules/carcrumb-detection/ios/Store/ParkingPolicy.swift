import Foundation
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

/// Parking history rules (docs/DECISIONS.md, "Hata dengesi"), as a pure decision shared by
/// `GRDBDetectionStore` and `InMemoryDetectionStore` so both behave identically.
///
/// ## Order = write order (row id), never the device clock
/// "Current" park and the "keep last 3" pruning follow the order in which parks were written
/// (AUTOINCREMENT id), not `parkedAt`. The device clock can jump (manual change, wrong time
/// after a reboot, time zone / NTP corrections); write order cannot. The user-approved rule is
/// "Arabam nerede = en yeni onaylı kayıt" (DECISIONS, 25 Nov 2026): the newest *written* park.
/// A replaced park (rule 2) is re-inserted, so it also becomes the newest row.
///
/// ## Rules
/// 1. **Uncertain trip → no parking.** The reducer never emits a park for an `uncertain`
///    trip; the store rejects one anyway (defence in depth, e.g. a buffered write replayed
///    after the trip was closed as uncertain). A trigger enforces it in SQLite too.
/// 2. **Same trip: low never replaces high.** One park row per trip. A second park for the
///    same trip replaces the row, unless the stored one is `high` and the new one is `low`
///    (then the high row is kept untouched).
/// 3. **A low park without a trip cannot displace the latest high park it is not newer
///    than.** Only for `tripID == nil` (e.g. a write whose trip row is unknown): with a trip,
///    rule 2 covers the same parking event, and a park from another confirmed trip is newer
///    evidence by construction (write order). Compared at millisecond precision (what SQLite
///    keeps), so a value that round-trips through the database compares equal.
/// 4. **Keep the last 3** park rows by write order. Older rows are deleted.
///
/// ## Why a newer low park is "current" across trips
/// A newer park, even a `low` one, comes from a newer *confirmed* trip (uncertain trips write
/// nothing), which proves the car moved: the older high-confidence point is then stale. The UI
/// shows the confidence of the current park, and the previous parks (incl. an older high one)
/// stay available through `recentParkings()` as alternatives.
public enum ParkingPolicy {
  public static let keepCount = 3

  public enum Decision: Equatable, Sendable {
    case insert
    /// Replace the existing park row of the same trip (its id): delete it, insert a new row.
    case replace(existingID: Int64)
    case reject(ParkingWriteOutcome)
  }

  /// - Parameters:
  ///   - tripID: resolved trip of the new park (nil = none / unknown trip).
  ///   - tripStatus: status of that trip; nil = no trip, or still open.
  ///   - sameTrip: the stored park of the same trip, if any.
  ///   - latestHigh: the most recently written stored `high` park (any trip), if any.
  public static func decide(
    _ point: ParkPoint,
    tripID: Int64?,
    tripStatus: StoredTripStatus?,
    sameTrip: StoredParking?,
    latestHigh: StoredParking?
  ) -> Decision {
    if tripStatus == .uncertain { return .reject(.rejectedUncertainTrip) }
    if let sameTrip {
      if sameTrip.confidence == .high, point.confidence == .low {
        return .reject(.keptHigherConfidence)
      }
      return .replace(existingID: sameTrip.id)
    }
    if tripID == nil, point.confidence == .low, let latestHigh,
       milliseconds(point.parkedAt) <= milliseconds(latestHigh.parkedAt) {
      return .reject(.keptHigherConfidence)
    }
    return .insert
  }

  /// Write order: higher id = written later. SQL twin: `GRDBDetectionStore.newestFirst`.
  public static func isNewer(_ a: StoredParking, than b: StoredParking) -> Bool {
    a.id > b.id
  }

  /// SQLite keeps dates at millisecond precision; compare at that precision on both sides.
  /// Floor (not nearest): for any stored value s derived from x (whether the storage
  /// truncates or rounds), floor(x) <= s, and floor is idempotent on whole milliseconds, so
  /// "equal before storage" never turns into "newer" after a round trip. The tiny epsilon
  /// absorbs Double error on a stored whole millisecond (e.g. ...599.9999 for ...600).
  static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000 + 0.001).rounded(.down))
  }
}
