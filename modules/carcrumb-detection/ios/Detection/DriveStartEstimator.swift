import Foundation

/// One entry of the Core Motion activity history, reduced to what the estimator needs.
/// The Sensors layer maps `CMMotionActivity` (startDate + flags + confidence) into this.
public struct ActivitySpan: Equatable, Codable, Sendable {
  public var start: Date
  public var activity: MotionActivity

  public init(start: Date, activity: MotionActivity) {
    self.start = start
    self.activity = activity
  }
}

/// Finds the real start of the current drive from motion history
/// (docs/DECISIONS.md: "Uyanınca queryActivityStarting ile son 7 günün hareket kaydından
/// sürüşün gerçek başlangıcı geriye dönük bulunur").
///
/// Not part of the reducer: the reducer emits `.beginTrip(startedAt: since)` with the wake time;
/// the engine then queries history and corrects the stored trip's start via
/// `DetectionStore.refineTripStart`. Kept pure here so it is testable with `swift test`.
public enum DriveStartEstimator {
  /// Core Motion keeps ~7 days of history, but a drive does not start hours before the wake
  /// that detected it; a short window keeps the query cheap and avoids gluing an old trip's
  /// automotive run onto this one. The engine further bounds it by the last trip's end.
  public static let defaultLookback: TimeInterval = 2 * 3600

  /// Query window for the engine: from max(detectedAt - lookback, lastTripEndedAt) to detectedAt.
  public static func queryStart(detectedAt: Date, lastTripEndedAt: Date?, lookback: TimeInterval = DriveStartEstimator.defaultLookback) -> Date {
    let earliest = detectedAt.addingTimeInterval(-lookback)
    guard let lastTripEndedAt, lastTripEndedAt > earliest, lastTripEndedAt < detectedAt else { return earliest }
    return lastTripEndedAt
  }

  /// - Parameters:
  ///   - history: activity entries, any order. Each lasts until the next entry's start.
  ///   - detectedAt: when the reducer started the trip (wake / first automotive time).
  ///   - maxInterruption: non-automotive gaps (stationary/unknown at a light, short walk at a
  ///     fuel stop) up to this length do not break the drive.
  ///   - maxLookback: upper bound on how far back the start may move.
  /// - Returns: start of the automotive run that reaches `detectedAt`, or nil if the history
  ///   does not show one (then the caller keeps `detectedAt`).
  public static func estimateStart(
    history: [ActivitySpan],
    detectedAt: Date,
    maxInterruption: TimeInterval = 120,
    maxLookback: TimeInterval = DriveStartEstimator.defaultLookback
  ) -> Date? {
    let earliest = detectedAt.addingTimeInterval(-maxLookback)
    let spans = history
      .filter { $0.start <= detectedAt && $0.start >= earliest }
      .sorted { $0.start < $1.start }
    guard !spans.isEmpty else { return nil }

    var runStart: Date?
    // End of the span after the one being examined (walking backwards). The newest span
    // lasts until detectedAt.
    var spanEnd = detectedAt
    // Accumulated non-automotive time since the most recent automotive span seen so far.
    var interruption: TimeInterval = 0

    for span in spans.reversed() {
      let duration = max(0, spanEnd.timeIntervalSince(span.start))
      if span.activity == .automotive {
        runStart = span.start
        interruption = 0
      } else {
        interruption += duration
        if interruption > maxInterruption { break }
      }
      spanEnd = span.start
    }
    return runStart
  }
}
