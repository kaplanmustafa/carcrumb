import CoreMotion
import Foundation

/// Core Motion activity source.
///
/// Threading: Core Motion calls our handlers on `callbackQueue`, a private serial
/// OperationQueue (not main, not the engine queue). Handlers only map the value and pass it
/// to `onEvent`, which enqueues onto the engine queue. `start`/`stop` may be called from any
/// thread; CMMotionActivityManager is documented thread-safe for these calls.
///
/// Updates arrive only while the process runs; while IDLE/PARKED the app is suspended and
/// the wake-ups come from Core Location. During MAYBE_DRIVING / DRIVING / MAYBE_PARKED the
/// GPS session keeps the process alive, so walking/automotive transitions are delivered.
final class MotionSensor: @unchecked Sendable {
  var onEvent: (@Sendable (DetectionEvent) -> Void)?

  private let manager = CMMotionActivityManager()
  private let callbackQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "carcrumb.motion"
    q.maxConcurrentOperationCount = 1
    return q
  }()
  private var running = false
  private let lock = NSLock()

  static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
  static var authorizationStatus: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

  /// Starts live updates only if Motion & Fitness is already authorized, so the engine
  /// starting at launch never shows the system prompt by itself (prompts come only from the
  /// permission screens via `requestAuthorization`).
  func startIfAuthorized() {
    guard Self.isAvailable, Self.authorizationStatus == .authorized else { return }
    lock.lock(); defer { lock.unlock() }
    guard !running else { return }
    running = true
    manager.startActivityUpdates(to: callbackQueue) { [weak self] activity in
      guard let activity, let mapped = MotionSensor.map(activity) else { return }
      // startDate = when the activity really began; walking is often reported tens of seconds
      // late and the park point is chosen at this time, not at delivery (DECISIONS "Park noktası").
      self?.onEvent?(.motion(mapped, startedAt: activity.startDate))
    }
  }

  func stop() {
    lock.lock(); defer { lock.unlock() }
    guard running else { return }
    running = false
    manager.stopActivityUpdates()
  }

  /// Triggers the Motion & Fitness prompt with a zero-length history query (Core Motion has
  /// no explicit request API), then starts updates if granted.
  func requestAuthorization(completion: @escaping @Sendable (CMAuthorizationStatus) -> Void) {
    guard Self.isAvailable else { return completion(Self.authorizationStatus) }
    let now = Date()
    manager.queryActivityStarting(from: now, to: now, to: callbackQueue) { [weak self] _, _ in
      let status = MotionSensor.authorizationStatus
      if status == .authorized { self?.startIfAuthorized() }
      completion(status)
    }
  }

  /// History for `DriveStartEstimator`. Core Motion keeps ~7 days; older ranges return
  /// what exists. Called on wake / trip confirmation, not on a hot path.
  func queryHistory(from: Date, to: Date, completion: @escaping @Sendable ([ActivitySpan]) -> Void) {
    guard Self.isAvailable, Self.authorizationStatus == .authorized else { return completion([]) }
    manager.queryActivityStarting(from: from, to: to, to: callbackQueue) { activities, _ in
      let spans = (activities ?? []).compactMap { a -> ActivitySpan? in
        guard let mapped = MotionSensor.map(a) else { return nil }
        return ActivitySpan(start: a.startDate, activity: mapped)
      }
      completion(spans)
    }
  }

  /// CMMotionActivity has independent flags; the reducer wants one activity.
  /// - Low confidence entries are dropped (nil). Core Motion often emits a short low-confidence
  ///   "walking" while the phone is handled in the car, which would open MAYBE_PARKED for nothing.
  ///   This filter sits outside the reducer, so it is not visible in traces: a dropped
  ///   entry is simply not recorded.
  /// - automotive wins over stationary: at a red light both are true and it is still driving
  ///   (docs/DECISIONS.md, "Trafik ile park ayrımı").
  /// - walking/running beat stationary; cycling next; then stationary; else unknown.
  static func map(_ a: CMMotionActivity) -> MotionActivity? {
    if a.confidence == .low { return nil }
    if a.automotive { return .automotive }
    if a.walking { return .walking }
    if a.running { return .running }
    if a.cycling { return .cycling }
    if a.stationary { return .stationary }
    return .unknown
  }
}
