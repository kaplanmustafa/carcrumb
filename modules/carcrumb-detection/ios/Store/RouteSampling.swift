import Foundation
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

// Trip route recording (docs/DECISIONS.md v1: "yolculuk geçmişi (rota, süre, mesafe)").
// Pure value types and functions: Foundation only, no CoreLocation, no clock, no I/O, so
// they are tested with `swift test`. The engine feeds them on its serial queue and writes
// the result through `DetectionStore.appendRoutePoints`.
//
// Privacy: route points are raw coordinates. Never log them, never send them over the
// network; they go to SQLite and, for display only, to JS (`getTripRoute`).

/// One stored point of a trip route. Contains raw coordinates: never log it.
public struct RoutePoint: Equatable, Codable, Sendable {
  public var latitude: Double
  public var longitude: Double
  /// Horizontal accuracy (m) of the fix.
  public var accuracy: Double
  /// Fix time (`LocationSample.timestamp`).
  public var timestamp: Date

  public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.accuracy = accuracy
    self.timestamp = timestamp
  }

  public init(_ sample: LocationSample) {
    self.init(latitude: sample.latitude, longitude: sample.longitude, accuracy: sample.accuracy, timestamp: sample.timestamp)
  }

  /// Haversine, same formula as `LocationSample.distance(to:)` (one implementation).
  public func distance(to other: RoutePoint) -> Double {
    asSample.distance(to: other.asSample)
  }

  private var asSample: LocationSample {
    LocationSample(latitude: latitude, longitude: longitude, accuracy: accuracy, speed: -1, timestamp: timestamp)
  }
}

/// Tunables of route recording. Provisional, like `DetectionConfig`; field data decides.
public struct RouteSamplingConfig: Equatable, Sendable {
  /// Fixes worse than this (m) are not route points. 30 m: `liveUpdates(.automotiveNavigation)`
  /// on an open road reports ~5–15 m; 30 m still accepts urban canyons but drops the
  /// 65 m+ Wi-Fi / cell fixes that would draw zig-zags and inflate the distance. Looser than
  /// the park point's `goodAccuracy` (20 m) on purpose: a route only needs the road, not a spot.
  public var maxAccuracy: Double = 30
  /// A point is kept when it is at least this far (m) from the last kept point, OR ...
  /// 25 m: below the 30 m accuracy limit two fixes can differ by noise alone; summing noise
  /// inflates the haversine distance (jitter), so closer fixes are skipped. 25 m still follows
  /// city corners (a 90° turn is not cut by more than a few metres).
  public var minDistance: Double = 25
  /// ... at least this long (s) after it. Only matters when the reported speed and the
  /// position delta disagree (with the vehicle-speed rule below, 15 s at > 2.5 m/s is already
  /// > 37 m): it keeps a point every 15 s in a slow crawl with jittery positions instead of
  /// none. 15 s = the engine's tick / persist period.
  public var minInterval: TimeInterval = 15
  /// Only fixes faster than this (m/s) while DRIVING are route points. Same threshold as the
  /// reducer's movement evidence (`DetectionConfig.maxWalkingSpeed`, docs/DECISIONS.md
  /// "Park noktası": vehicle speed > ~2.5 m/s). Keeps the walk to / from the car (walking is
  /// often reported by Core Motion tens of seconds late, while the state is still DRIVING)
  /// and GPS drift at standstill out of the route, so the route ends where the park point is
  /// chosen. Unknown speed (< 0) is not vehicle speed.
  public var minVehicleSpeed: Double = DetectionConfig().maxWalkingSpeed
  /// Upper bound of stored points per trip. When an append exceeds it, the stored route is
  /// thinned to about half (every second point; first and last kept) and the sampler doubles
  /// its spacing, so the density stays uniform along the trip instead of the tail being cut
  /// off. 5000 points ≈ 125 km at 25 m spacing; ~250 KB per trip in SQLite; one MapKit
  /// polyline and one bridge payload of that size are cheap. A 500 km trip ends with ~2500–5000
  /// points at 100–200 m spacing, still enough to draw roads at trip zoom.
  public var maxPointsPerTrip: Int = 5000
  /// Pending points are written in one transaction when this many are collected ...
  /// (≈ 20–60 s of driving; one transaction instead of 20 fsyncs.)
  public var flushBatchSize: Int = 20
  /// ... or when the oldest pending point is this old (s), so a process death (jetsam) loses
  /// at most about a minute of route. The trip end always flushes.
  public var maxPendingAge: TimeInterval = 60
  /// A fix older than the last kept point by MORE than this (s) means the device clock was
  /// set back (manual change, wrong RTC corrected), not a late / out-of-order delivery: the
  /// spacing reference is reset and recording continues from that fix. Without it every fix
  /// until the clock catches up (up to the size of the jump) would be "older than the last
  /// kept point" and dropped. 60 s: NTP corrections are a few seconds and keep the strict
  /// "newer than the last kept point" rule (they only cost those seconds); a `liveUpdates`
  /// fix is not delivered a minute late while the loop runs.
  public var maxClockStepBack: TimeInterval = 60

  public init() {}
}

/// Chooses route points from the engine's location samples and collects them for a batched
/// write. Pure state; the engine owns one and calls it on its serial queue.
///
/// Rules (in order), see `RouteSamplingConfig` for the values and reasons:
/// 1. only while a trip row exists (`begin(tripID:)`) and the state after reducing the fix is
///    DRIVING (`driving: true`): MAYBE_DRIVING (no trip row yet), MAYBE_PARKED (walking) and
///    PARKED fixes are never route points. A MAYBE_PARKED fix at vehicle speed sends the
///    reducer back to DRIVING, so it is offered as DRIVING (traffic, not a park);
/// 2. vehicle speed (> `minVehicleSpeed`);
/// 3. valid accuracy (>= 0) not worse than `maxAccuracy`;
/// 4. newer than the last kept point (out-of-order fixes are dropped), unless it is more
///    than `maxClockStepBack` older: then the clock was set back, the reference is reset and
///    the fix is kept (`shouldFlush` writes the pending batch right away, so one batch never
///    mixes the two clocks);
/// 5. `minDistance` OR `minInterval` from the last kept point (both scaled by `spacingScale`).
///
/// A locked database (before the first unlock) is NOT handled here by buffering: the engine
/// only begins the sampler when `beginTrip` wrote a row, so such a trip has no route.
public struct RouteSampler: Equatable, Sendable {
  public let config: RouteSamplingConfig
  /// Trip the pending points belong to; nil = not recording.
  public private(set) var tripID: Int64?
  /// Points chosen but not written yet, oldest first.
  public private(set) var pending: [RoutePoint] = []
  /// Last chosen point (pending or written); the spacing rules compare against it.
  public private(set) var lastKept: RoutePoint?
  /// 1, doubled at every thinning of the stored route (`didThin`). Restored after a relaunch
  /// from the store (`DetectionStore.routeThinCount`), so a long trip keeps its density.
  public private(set) var spacingScale: Double = 1
  /// A backwards clock jump was detected since the last `takePending`: flush now.
  public private(set) var clockSetBack = false

  public init(config: RouteSamplingConfig = RouteSamplingConfig()) {
    self.config = config
  }

  /// Starts recording a trip; drops anything of a previous one. `thinCount`: how often the
  /// trip's stored route was already thinned (a trip restored after a relaunch; 0 for a new
  /// trip), so the spacing continues where the previous process left it.
  public mutating func begin(tripID: Int64, thinCount: Int = 0) {
    self = RouteSampler(config: config)
    self.tripID = tripID
    didThin(times: thinCount)
  }

  /// Stops recording; pending points are dropped (flush first if they must be written).
  public mutating func reset() {
    self = RouteSampler(config: config)
  }

  /// Returns true if `sample` was taken as a route point.
  @discardableResult
  public mutating func offer(_ sample: LocationSample, driving: Bool) -> Bool {
    guard tripID != nil, driving else { return false }
    guard sample.speed > config.minVehicleSpeed else { return false }
    guard sample.accuracy >= 0, sample.accuracy <= config.maxAccuracy else { return false }
    guard sample.latitude.isFinite, sample.longitude.isFinite,
          abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else { return false }
    let point = RoutePoint(sample)
    if let last = lastKept, last.timestamp.timeIntervalSince(point.timestamp) > config.maxClockStepBack {
      // Clock set back (rule 4): reset the reference, keep this fix, flush the old batch.
      clockSetBack = true
    } else if let last = lastKept {
      guard point.timestamp > last.timestamp else { return false }
      let farEnough = point.distance(to: last) >= config.minDistance * spacingScale
      let longEnough = point.timestamp.timeIntervalSince(last.timestamp) >= config.minInterval * spacingScale
      guard farEnough || longEnough else { return false }
    }
    pending.append(point)
    lastKept = point
    return true
  }

  /// True when the pending points should be written now: batch full, a backwards clock jump
  /// was detected, or the oldest pending point is `maxPendingAge` old. The age is measured
  /// both against `now` (the engine's clock) and against the newest pending fix; the larger
  /// wins. So when the engine clock is behind the fix timestamps, the span of the pending
  /// fixes still triggers the flush and a jetsam loses about `maxPendingAge` of route at most.
  public func shouldFlush(now: Date) -> Bool {
    guard tripID != nil, let oldest = pending.first, let newest = pending.last else { return false }
    if pending.count >= config.flushBatchSize || clockSetBack { return true }
    let age = max(now.timeIntervalSince(oldest.timestamp), newest.timestamp.timeIntervalSince(oldest.timestamp))
    return age >= config.maxPendingAge
  }

  /// Hands the pending points to the writer (they are gone from the sampler even if the
  /// write fails: a failed batch is dropped, not retried, so the route only has gaps).
  public mutating func takePending() -> [RoutePoint] {
    defer {
      pending.removeAll()
      clockSetBack = false
    }
    return pending
  }

  /// The store thinned this trip's route `times` times (`RouteAppendResult.thinCount`; one
  /// append far above the cap can halve it more than once): halve future density each time.
  /// Capped at 2^20 so a corrupt count cannot overflow the spacing.
  public mutating func didThin(times: Int = 1) {
    guard times > 0 else { return }
    spacingScale *= Double(1 << min(times, 20))
  }
}

/// Result of `DetectionStore.appendRoutePoints`.
public struct RouteAppendResult: Equatable, Sendable {
  /// Points stored for the trip after the write (and thinning).
  public var storedCount: Int
  /// How many times the route was halved in the same transaction (0: not thinned). More
  /// than 1 when one append lands far above `maxPointsPerTrip`.
  public var thinCount: Int

  /// The route exceeded `maxPointsPerTrip` and was thinned in the same transaction.
  public var thinned: Bool { thinCount > 0 }

  public init(storedCount: Int, thinCount: Int) {
    self.storedCount = storedCount
    self.thinCount = thinCount
  }
}

public enum RouteThinning {
  /// Positions (0-based, in route order) to delete so that about half of `count` points
  /// remain: every second point, the first and the last always kept (the route keeps its
  /// real start and end). Empty for fewer than 3 points.
  public static func positionsToRemove(count: Int) -> [Int] {
    guard count >= 3 else { return [] }
    return Array(stride(from: 1, to: count - 1, by: 2))
  }

  /// Applies `positionsToRemove` until at most `maxCount` remain. Pure twin of the store's
  /// SQL thinning (used by the in-memory store and tests).
  public static func thin<T>(_ points: [T], maxCount: Int) -> (points: [T], thinned: Bool) {
    let (result, passes) = thinCounting(points, maxCount: maxCount)
    return (result, passes > 0)
  }

  /// `thin`, also returning how many halvings were applied.
  public static func thinCounting<T>(_ points: [T], maxCount: Int) -> (points: [T], passes: Int) {
    var result = points
    var passes = 0
    while result.count > max(2, maxCount) {
      let remove = Set(positionsToRemove(count: result.count))
      result = result.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
      passes += 1
    }
    return (result, passes)
  }

  /// Thinnings already applied to a stored route, from the `seq` of its first two points.
  ///
  /// `seq` is assigned contiguously (MAX + 1; a dropped batch never takes a seq), and every
  /// thinning removes position 1 and keeps positions 0 and 2 of a uniformly thinned head, so
  /// the gap between the first two stored seqs doubles at each thinning: gap = 2^thinCount.
  /// Restores `RouteSampler.spacingScale` after a relaunch without persisting it separately.
  public static func thinCount(firstSeq: Int64, secondSeq: Int64) -> Int {
    let gap = secondSeq - firstSeq
    guard gap > 1 else { return 0 }
    return Int64.bitWidth - 1 - gap.leadingZeroBitCount // floor(log2(gap))
  }
}

public enum RouteDistance {
  /// Distance (m) added by appending `points` after `previous` (the trip's last stored point,
  /// nil for the first batch): the bridge segment plus the segments inside the batch. nil
  /// when there is no segment at all (the distance stays unknown, not 0). The store sums these
  /// at write time, BEFORE any thinning, so the trip distance does not shrink when a long
  /// route is thinned (a thinned polyline cuts corners).
  public static func increment(after previous: RoutePoint?, appending points: [RoutePoint]) -> Double? {
    meters((previous.map { [$0] } ?? []) + points)
  }

  /// Distance written when a trip is closed (both stores): the accumulated total, or the
  /// stored route's sum when that is larger. With a complete total the sum is never larger
  /// (a thinned polyline is never longer than the one it came from); it only wins for a
  /// route begun by a build without the running total. nil only when both are nil.
  public static func closing(accumulated: Double?, routeSum: Double?) -> Double? {
    switch (accumulated, routeSum) {
    case let (a?, r?): return max(a, r)
    case let (a?, nil): return a
    case let (nil, r?): return r
    case (nil, nil): return nil
    }
  }

  /// Driven distance (m): haversine sum over consecutive points in route order. nil for
  /// fewer than 2 points (no route, e.g. a trip written while the database was locked): the
  /// distance is unknown, not zero.
  public static func meters(_ points: [RoutePoint]) -> Double? {
    guard points.count >= 2 else { return nil }
    var total = 0.0
    for i in 1..<points.count {
      total += points[i - 1].distance(to: points[i])
    }
    return total
  }
}
