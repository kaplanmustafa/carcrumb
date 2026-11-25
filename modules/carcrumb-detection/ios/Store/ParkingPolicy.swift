import Foundation
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

/// Parking history rules (docs/DECISIONS.md, "Hata dengesi"), as a pure decision shared by
/// `GRDBDetectionStore` and `InMemoryDetectionStore` so both behave identically.
///
/// ## Rules
/// 1. **Uncertain trip → no parking.** The reducer never emits a park for an `uncertain`
///    trip; the store rejects one anyway (defence in depth, e.g. a buffered write replayed
///    after the trip was closed as uncertain).
/// 2. **Same trip: low never replaces high.** One park row per trip. A second park for the
///    same trip replaces the row, unless the stored one is `high` and the new one is `low`
///    (then the high row is kept untouched).
/// 3. **A late low park cannot displace a newer-or-equal high park.** A `low` park whose
///    `parkedAt` is not after the newest `high` park is rejected (out-of-order write, e.g. a
///    restored/closed old trip).
/// 4. **Keep the last 3** park rows (by `parkedAt`, then id). Older rows are deleted.
///
/// ## "Current" park (getLastParking) = the newest row by `parkedAt`
/// A newer park, even a `low` one, comes from a newer *confirmed* trip (uncertain trips write
/// nothing), which proves the car moved: the older high-confidence point is then provably
/// stale, so showing it as "Arabam nerede" would send the user to an empty spot. "Low does not
/// overwrite high" is therefore enforced where a low write would really destroy better
/// information about the *same* parking event (rules 2 and 3), not across trips. The UI shows
/// the confidence of the current park, and the previous parks (incl. the older high one) stay
/// available through `recentParkings()` as alternatives. Ties on `parkedAt` prefer `high`.
public enum ParkingPolicy {
  public static let keepCount = 3

  public enum Decision: Equatable, Sendable {
    case insert
    /// Replace the existing park row of the same trip (its id).
    case replace(existingID: Int64)
    case reject(ParkingWriteOutcome)
  }

  /// - Parameters:
  ///   - tripStatus: status of the referenced trip; nil = no trip, unknown trip, or still open.
  ///   - sameTrip: the stored park of the same trip, if any.
  ///   - newestHighParkedAt: `parkedAt` of the newest stored `high` park (any trip), if any.
  public static func decide(
    _ point: ParkPoint,
    tripStatus: StoredTripStatus?,
    sameTrip: StoredParking?,
    newestHighParkedAt: Date?
  ) -> Decision {
    if tripStatus == .uncertain { return .reject(.rejectedUncertainTrip) }
    if let sameTrip {
      if sameTrip.confidence == .high, point.confidence == .low {
        return .reject(.keptHigherConfidence)
      }
      return .replace(existingID: sameTrip.id)
    }
    if point.confidence == .low, let newestHighParkedAt, point.parkedAt <= newestHighParkedAt {
      return .reject(.keptHigherConfidence)
    }
    return .insert
  }

  /// Sort used for "current" and for pruning: newest first, high before low on ties, then id.
  public static func isNewer(_ a: StoredParking, than b: StoredParking) -> Bool {
    if a.parkedAt != b.parkedAt { return a.parkedAt > b.parkedAt }
    if a.confidence != b.confidence { return a.confidence == .high }
    return a.id > b.id
  }
}
