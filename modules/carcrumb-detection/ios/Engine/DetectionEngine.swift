import CoreLocation
import CoreMotion
import Foundation
import os

/// Runs the detection state machine against live sensors.
///
/// ## Threading (who runs where)
/// - `queue` (serial, "app.carcrumb.detection.engine", utility QoS) is the single execution
///   context for detection: every event → `DetectionReducer.reduce` → effect application,
///   state persistence, trace recording, store writes and the tick timer. All mutable engine
///   state below is touched only on this queue (`dispatchPrecondition` checks it in DEBUG).
///   A serial queue (not an actor) on purpose: `process` has no suspension points, so events
///   are handled strictly one at a time in arrival (FIFO) order, with no actor reentrancy.
/// - Main thread / main actor: `LocationSensor` (CLLocationManager needs a run-loop thread;
///   CLMonitor + liveUpdates loops are main-actor Tasks). Effects that touch it are sent with
///   `DispatchQueue.main.async`, which is FIFO, so startGPS/stopGPS/setGeofence keep order.
/// - Core Motion handlers: private OperationQueue "carcrumb.motion"; they only enqueue here.
/// - Audio route notifications: AVAudioSession's posting thread; they only enqueue here.
/// - JS bridge: reads `stateName` through a lock (never blocks on `queue`), and receives
///   state changes through observers invoked on `queue`.
///
/// ## Lifecycle
/// `start()` is called from `DetectionAppDelegateSubscriber` in
/// `application(_:didFinishLaunchingWithOptions:)`, i.e. before React Native/JS exists, also
/// when iOS relaunches the terminated app in the background for a location event (`.location`
/// launch key). The module's `OnCreate` calls it too (idempotent) as a safety net.
public final class DetectionEngine: @unchecked Sendable {
  public static let shared = DetectionEngine(store: InMemoryDetectionStore())

  let queue = DispatchQueue(label: "app.carcrumb.detection.engine", qos: .utility)

  // Only coordinates-free values are logged: state names, event types, effect names.
  // `os.Logger` spelled out: ExpoModulesCore also exports a `Logger` type.
  private let log = os.Logger(subsystem: "app.carcrumb", category: "detection")

  // MARK: Queue-confined state
  private let reducer = DetectionReducer()
  private var state: DetectionState = .idle
  private var tripID: Int64?
  /// End of the last closed trip; bounds the Core Motion history query of the next one.
  private var lastTripEndedAt: Date?
  private let store: DetectionStore
  private let stateFile = StateFile()
  private let recorder = TraceRecorder()
  private var lastPersistAt: Date?
  private var tickTimer: DispatchSourceTimer?
  private var observers: [UUID: @Sendable (String) -> Void] = [:]

  /// Active states are persisted at most this often within the same state (the trip's
  /// ring buffer changes every second while driving).
  private let persistInterval: TimeInterval = 15
  /// Period of `.tick` in every GPS state (MAYBE_DRIVING / DRIVING / MAYBE_PARKED), so the
  /// reducer's timeouts fire even when no sensor data arrives (Karar A/B).
  private let tickInterval: TimeInterval = 15

  // MARK: Main-thread-confined
  private var location: LocationSensor? // created/used on main only

  // MARK: Thread-safe
  private let motion = MotionSensor()
  private let carLink = CarLinkSensor()
  private let snapshotLock = NSLock()
  private var _stateName = "IDLE"
  private var _started = false

  init(store: DetectionStore) {
    self.store = store
  }

  /// Current state name for synchronous reads from JS (no coordinates).
  public var stateName: String {
    snapshotLock.lock(); defer { snapshotLock.unlock() }
    return _stateName
  }

  public var isStarted: Bool {
    snapshotLock.lock(); defer { snapshotLock.unlock() }
    return _started
  }

  // MARK: Start

  /// Idempotent. Must run on the main thread (creates CLLocationManager / CLMonitor).
  @MainActor
  public func start() {
    snapshotLock.lock()
    if _started { snapshotLock.unlock(); return }
    _started = true
    snapshotLock.unlock()

    // 1. Restore first. Enqueued before any sensor can enqueue an event, so FIFO guarantees
    //    the wake event that relaunched us is reduced against the restored state.
    //    Trace housekeeping goes first: release builds delete any traces/ left on disk.
    queue.async {
      self.recorder.prepare(now: Date())
      self.restore()
    }

    // 2. Sensors.
    let location = LocationSensor()
    location.onEvent = { [weak self] event in self?.send(event) }
    location.onAuthorizationChange = { [weak self] in
      // Always / WhenInUse may have just been granted from the permission screen.
      self?.motion.startIfAuthorized()
    }
    self.location = location
    location.start()

    motion.onEvent = { [weak self] event in self?.send(event) }
    motion.startIfAuthorized()

    carLink.onEvent = { [weak self] event in self?.send(event) }
    carLink.start()

    log.info("engine started")
  }

  /// Re-checks permissions that can change in Settings while we were in the background.
  @MainActor
  public func applicationDidBecomeActive() {
    guard isStarted else { return }
    motion.startIfAuthorized()
  }

  // MARK: Events

  /// Thread-safe entry point for sensor events.
  public func send(_ event: DetectionEvent) {
    queue.async { self.process(event, now: Date()) }
  }

  private func process(_ event: DetectionEvent, now: Date) {
    dispatchPrecondition(condition: .onQueue(queue))
    let effects = reduceAndApply(event, now: now)
    if case .wake = event {
      syncCarLinkLevel(now: now)
    } else if effects.contains(.startGPS) {
      syncCarLinkLevel(now: now)
    }
  }

  @discardableResult
  private func reduceAndApply(_ event: DetectionEvent, now: Date) -> [Effect] {
    recorder.record(event, at: now) // DEBUG only; no-op in release
    let old = state
    let (next, effects) = reducer.reduce(state, event, now: now)
    state = next
    apply(effects, now: now)
    didUpdateState(from: old, cause: event.typeName, now: now)
    return effects
  }

  /// `CarLinkSensor` reports changes only. After a wake or a GPS start the reducer may not
  /// know the current level (e.g. CarPlay connected before MAYBE_DRIVING timed out to IDLE,
  /// or a fresh process after relaunch), so re-read the route and feed the level as a normal,
  /// recorded `.carLink` event when it differs from what the state believes.
  private func syncCarLinkLevel(now: Date) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let known = state.knownCarLinkLevel else { return }
    let level = carLink.refresh()
    guard level != known else { return }
    reduceAndApply(.carLink(connected: level), now: now)
  }

  private func restore() {
    dispatchPrecondition(condition: .onQueue(queue))
    let now = Date()
    let persisted = stateFile.load()
    // Recorded so a field trace replays across the relaunch (TraceReplayer runs the same policy).
    recorder.recordRestore(persisted ?? PersistedDetectionState(state: .idle, savedAt: now), at: now)
    let (restored, effects) = StateRestorePolicy.restore(persisted, now: now, reducer: reducer)
    state = restored
    lastTripEndedAt = persisted?.lastTripEndedAt
    tripID = restored.hasOpenTrip || effects.contains(where: \.isEndTrip) ? persisted?.tripID : nil
    log.info("restored state \(restored.name, privacy: .public) (persisted: \(persisted?.state.name ?? "none", privacy: .public))")
    apply(effects, now: now)
    didUpdateState(from: .idle, cause: "restore", now: now, forceNotify: true)
    if effects.contains(.startGPS) { syncCarLinkLevel(now: now) }
  }

  // MARK: Effects

  private func apply(_ effects: [Effect], now: Date) {
    dispatchPrecondition(condition: .onQueue(queue))
    // endTrip and saveParking come together (reducer: stopGPS, endTrip, saveParking,
    // setGeofence); saveParking must still see the trip that endTrip just closed.
    var closedTripID: Int64?
    for effect in effects {
      log.debug("effect \(effect.logName, privacy: .public)")
      switch effect {
      case .startGPS:
        onMain { $0.startGPS() }
      case .stopGPS:
        onMain { $0.stopGPS() }
      case let .beginTrip(startedAt):
        do {
          let id = try store.beginTrip(startedAt: startedAt)
          tripID = id
          refineTripStart(tripID: id, reducerStart: startedAt, confirmedAt: now)
        } catch {
          log.error("store.beginTrip failed")
        }
      case let .endTrip(status, endedAt):
        do { try store.endTrip(tripID: tripID, status: status, endedAt: endedAt) } catch {
          log.error("store.endTrip failed")
        }
        closedTripID = tripID
        tripID = nil
        lastTripEndedAt = endedAt
      case let .saveParking(point):
        do { try store.saveParking(point, tripID: closedTripID ?? tripID) } catch {
          log.error("store.saveParking failed")
        }
      case let .setGeofence(center, radius):
        onMain { $0.setGeofence(center: center, radius: radius) }
      case .clearGeofence:
        onMain { $0.clearGeofence() }
      }
    }
  }

  /// Real trip start from Core Motion history (docs/DECISIONS.md, "Gerçek başlangıç").
  /// The reducer's start is the wake time; the drive often began minutes earlier (the wake
  /// trigger lags). Core Motion keeps 7 days, but the query only covers the last ~2 hours and
  /// never reaches before the previous trip's end (so an old trip's automotive run is never
  /// glued onto this one). The reducer state is not changed (it never uses
  /// `trip.startedAt` for decisions).
  private func refineTripStart(tripID id: Int64, reducerStart: Date, confirmedAt: Date) {
    let from = DriveStartEstimator.queryStart(detectedAt: confirmedAt, lastTripEndedAt: lastTripEndedAt)
    let lookback = confirmedAt.timeIntervalSince(from)
    motion.queryHistory(from: from, to: confirmedAt) { [weak self] spans in
      guard let self else { return }
      guard let estimate = DriveStartEstimator.estimateStart(history: spans, detectedAt: confirmedAt, maxLookback: lookback),
            estimate < reducerStart
      else { return }
      self.queue.async {
        do { try self.store.refineTripStart(tripID: id, startedAt: estimate) } catch {
          self.log.error("store.refineTripStart failed")
        }
        self.log.info("trip start refined by \(Int(reducerStart.timeIntervalSince(estimate)), privacy: .public) s")
      }
    }
  }

  private func onMain(_ body: @escaping @MainActor (LocationSensor) -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let location = self.location else { return }
        body(location)
      }
    }
  }

  // MARK: State bookkeeping

  private func didUpdateState(from old: DetectionState, cause: String, now: Date, forceNotify: Bool = false) {
    let changed = old.name != state.name
    persistIfNeeded(changed: changed || forceNotify, now: now)
    guard changed || forceNotify else { return }
    if changed {
      log.info("\(old.name, privacy: .public) -> \(self.state.name, privacy: .public) on \(cause, privacy: .public)")
    }
    updateTickTimer()
    let name = state.name
    snapshotLock.lock(); _stateName = name; snapshotLock.unlock()
    observers.values.forEach { $0(name) }
  }

  private func persistIfNeeded(changed: Bool, now: Date) {
    let due = lastPersistAt.map { now.timeIntervalSince($0) >= persistInterval } ?? true
    guard changed || (state.isGPSState && due) else { return }
    do {
      try stateFile.save(PersistedDetectionState(state: state, savedAt: now, tripID: tripID, lastTripEndedAt: lastTripEndedAt))
      lastPersistAt = now
    } catch {
      log.error("state persist failed")
    }
  }

  private func updateTickTimer() {
    // DRIVING ticks too: the 15 min stationary timeout must fire when no fixes arrive at all.
    let wantsTick = state.isGPSState
    if wantsTick, tickTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .seconds(2))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        self.process(.tick, now: Date())
      }
      // NOTE: while the app is suspended the timer does not fire; in GPS states the
      // background activity session keeps the process running, which is what makes ticks
      // (and the timeouts) reliable there.
      timer.resume()
      tickTimer = timer
    } else if !wantsTick, let timer = tickTimer {
      timer.cancel()
      tickTimer = nil
    }
  }

  // MARK: Bridge support

  /// Observer is called on the engine queue with the new state name. Returns a token.
  public func addStateObserver(_ observer: @escaping @Sendable (String) -> Void) -> UUID {
    let id = UUID()
    queue.async { self.observers[id] = observer }
    return id
  }

  public func removeStateObserver(_ id: UUID) {
    queue.async { self.observers[id] = nil }
  }

  @MainActor
  public func requestWhenInUseAuthorization() async -> String {
    guard let location else { return "unavailable" }
    return Self.name(of: await location.requestWhenInUse())
  }

  @MainActor
  public func requestAlwaysAuthorization() async -> String {
    guard let location else { return "unavailable" }
    return Self.name(of: await location.requestAlways())
  }

  public func requestMotionAuthorization(completion: @escaping @Sendable (String) -> Void) {
    motion.requestAuthorization { completion(Self.name(of: $0)) }
  }

  /// Flags and names only. Never coordinates (docs/DECISIONS.md: "Ham koordinat loglanmaz").
  @MainActor
  public func diagnostics() async -> [String: Any] {
    var locationInfo: [String: Any] = ["authorization": "unavailable"]
    var serviceSession: Any = NSNull()
    var liveUpdates: Any = NSNull()
    var gpsActive = false
    var gpsRequested = false
    var geofenceActive = false
    if let location {
      locationInfo = [
        "authorization": Self.name(of: location.authorizationStatus),
        "accuracy": location.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
      ]
      serviceSession = location.lastServiceDiagnostic?.dictionary ?? NSNull()
      liveUpdates = location.lastLiveFlags?.dictionary ?? NSNull()
      gpsActive = location.isGPSActive
      gpsRequested = location.isGPSRequested
      geofenceActive = location.geofenceActive
    }
    // Class method that Apple warns against calling on the main thread.
    let servicesEnabled = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      queue.async { cont.resume(returning: CLLocationManager.locationServicesEnabled()) }
    }
    locationInfo["servicesEnabled"] = servicesEnabled

    return [
      "engine": [
        "started": isStarted,
        "state": stateName,
        "gpsActive": gpsActive,
        "gpsRequested": gpsRequested,
        "geofenceActive": geofenceActive,
        "carLinkConnected": carLink.isConnected,
        "traceRecording": TraceRecorder.isEnabled,
      ] as [String: Any],
      "location": locationInfo,
      "serviceSession": serviceSession,
      "liveUpdates": liveUpdates,
      "motion": [
        "available": MotionSensor.isAvailable,
        "authorization": Self.name(of: MotionSensor.authorizationStatus),
      ] as [String: Any],
    ]
  }

  static func name(of status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whenInUse"
    @unknown default: return "unknown"
    }
  }

  static func name(of status: CMAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }
}

// MARK: - Small helpers (no coordinates in any of these strings)

extension DetectionState {
  /// GPS is on in these states (they are entered with startGPS and left with stopGPS).
  var isGPSState: Bool {
    switch self {
    case .maybeDriving, .driving, .maybeParked: return true
    case .idle, .parked: return false
    }
  }

  var hasOpenTrip: Bool {
    switch self {
    case .driving, .maybeParked: return true
    default: return false
    }
  }

  /// Car link level the state believes in; nil where the reducer does not track it.
  var knownCarLinkLevel: Bool? {
    switch self {
    case let .maybeDriving(_, carLink): return carLink
    case let .driving(trip): return trip.carLinkConnected
    case let .maybeParked(trip, _, _): return trip.carLinkConnected
    case .idle, .parked: return nil
    }
  }
}

extension Effect {
  var isEndTrip: Bool {
    if case .endTrip = self { return true }
    return false
  }

  var logName: String {
    switch self {
    case .startGPS: return "startGPS"
    case .stopGPS: return "stopGPS"
    case .beginTrip: return "beginTrip"
    case .endTrip(let status, _): return "endTrip(\(status.rawValue))"
    case .saveParking(let p): return "saveParking(\(p.confidence.rawValue))"
    case .setGeofence: return "setGeofence"
    case .clearGeofence: return "clearGeofence"
    }
  }
}
