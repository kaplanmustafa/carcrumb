import CoreLocation
import Foundation

/// Location sources, all on the main actor.
///
/// Why the main actor: `CLLocationManager` delivers delegate callbacks on the run loop of the
/// thread that created it, and must be created on a thread with a run loop. The main thread
/// is the only one guaranteed to have one, including during a background relaunch.
/// Everything here is cheap; each callback only converts the value and hands it to
/// `onEvent`, which enqueues onto the engine's serial queue.
///
/// Sources (docs/DECISIONS.md, "Algılama mimarisi"):
/// - Wake-ups while GPS is off: significant location change, CLVisit departures,
///   CLMonitor circular condition around the last park point (~150 m).
/// - While driving (startGPS…stopGPS only): `CLLocationUpdate.liveUpdates(.automotiveNavigation)`
///   + `CLBackgroundActivitySession`.
/// - Authorization intent: `CLServiceSession` (iOS 18).
///
/// Privacy: nothing in this file logs coordinates. Diagnostics expose flags only.
@MainActor
final class LocationSensor: NSObject {
  /// Called on the main actor; the receiver must hop to its own queue.
  var onEvent: ((DetectionEvent) -> Void)?
  /// Authorization changed (used to refresh the service session and notify JS).
  var onAuthorizationChange: (() -> Void)?

  private let manager = CLLocationManager()

  // GPS (driving) resources. Non-nil only between startGPS and stopGPS.
  /// Non-nil only while a liveUpdates loop is actually running (reset when it ends/fails).
  private var liveTask: Task<Void, Never>?
  private var backgroundSession: CLBackgroundActivitySession?
  /// The state machine wants GPS (between `.startGPS` and `.stopGPS`).
  private var gpsWanted = false
  /// Identifies the current loop so a stale loop ending cannot clear a newer one.
  private var liveGeneration = 0
  private var restartTask: Task<Void, Never>?
  private var restartAttempts = 0

  // Long-lived service session declaring our authorization intent; diagnostics are read from it.
  private var serviceSession: CLServiceSession?
  // Own tag instead of comparing CLServiceSession.AuthorizationRequirement values (not
  // guaranteed Equatable in the SDK).
  private enum SessionKind { case always, whenInUse }
  private var serviceSessionKind: SessionKind?
  private var diagnosticsTask: Task<Void, Never>?
  private(set) var lastServiceDiagnostic: ServiceSessionFlags?
  private(set) var lastLiveFlags: LiveUpdateFlags?

  // Geofence.
  private static let monitorName = "CarCrumbMonitor"
  private static let parkConditionID = "lastPark"
  private var monitor: CLMonitor?
  private var monitorTask: Task<Void, Never>?
  /// Tail of the serialized geofence operations (set/clear run strictly in effect order).
  private var geofenceChain: Task<Void, Never>?
  private(set) var geofenceActive = false

  private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
  private var started = false

  override init() {
    super.init()
    manager.delegate = self
    // We never call startUpdatingLocation on this manager (driving uses liveUpdates), so these
    // two settings only matter if a standard-updates fallback is added later. They are set
    // deliberately so such a fallback cannot silently misbehave:
    // - activityType = .automotiveNavigation: matches the driving use case.
    // - pausesLocationUpdatesAutomatically = false: an automatic pause in the background
    //   (e.g. 2 min in a traffic jam) can only be resumed by bringing the app to the
    //   foreground, which would lose the rest of the trip and the park point. Stopping GPS is
    //   decided by the state machine (stopGPS), not by Core Location's heuristic.
    manager.activityType = .automotiveNavigation
    manager.pausesLocationUpdatesAutomatically = false
    // allowsBackgroundLocationUpdates is intentionally left false: significant changes,
    // visits and CLMonitor do not need it, and driving updates in the background are
    // covered by CLBackgroundActivitySession.
  }

  // MARK: Lifecycle

  /// Idempotent. Called at launch (also on a background relaunch by a location event, before
  /// JS exists) so the pending wake event is delivered.
  func start() {
    guard !started else { return }
    started = true
    refreshAuthorizationDependents()
    startMonitorIfNeeded()
  }

  /// Starts / restarts everything that depends on authorization.
  private func refreshAuthorizationDependents() {
    let status = manager.authorizationStatus
    updateServiceSession(for: status)
    if status == .authorizedAlways {
      // Both are cheap (cell/Wi-Fi based) and relaunch a terminated app. Need Always.
      manager.startMonitoringSignificantLocationChanges()
      manager.startMonitoringVisits()
    } else {
      manager.stopMonitoringSignificantLocationChanges()
      manager.stopMonitoringVisits()
    }
  }

  // MARK: Authorization

  var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
  var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

  /// Shows the system prompt (only if the status allows it) and resolves with the resulting
  /// status. Resolves immediately when no prompt will be shown.
  func requestWhenInUse() async -> CLAuthorizationStatus {
    guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
    return await withCheckedContinuation { cont in
      authorizationContinuations.append(cont)
      manager.requestWhenInUseAuthorization()
    }
  }

  /// Always upgrade. iOS shows the upgrade prompt at most once; if it is not shown, the
  /// delegate is not called, so we also resolve after a timeout with the current status.
  /// Only from When In Use (DECISIONS "İzin akışı": While Using first, Always later with
  /// context). While `.notDetermined` no prompt is shown; the current status is returned.
  func requestAlways() async -> CLAuthorizationStatus {
    let status = manager.authorizationStatus
    guard status == .authorizedWhenInUse else { return status }
    return await withCheckedContinuation { cont in
      authorizationContinuations.append(cont)
      manager.requestAlwaysAuthorization()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(30))
        self?.resolveAuthorizationWaiters()
      }
    }
  }

  private func resolveAuthorizationWaiters() {
    let status = manager.authorizationStatus
    let waiters = authorizationContinuations
    authorizationContinuations.removeAll()
    waiters.forEach { $0.resume(returning: status) }
  }

  // MARK: Service session (iOS 18)

  /// Holds one CLServiceSession matching the granted authorization:
  /// - not created while `.notDetermined`, so it never triggers a prompt by itself (prompts
  ///   only come from the permission screens' "Devam" button),
  /// - `.always` once Always is granted: declares background intent so CLMonitor events
  ///   and liveUpdates keep flowing after a background relaunch,
  /// - `.whenInUse` otherwise, which is what produces the `insufficientlyInUse` diagnostic.
  private func updateServiceSession(for status: CLAuthorizationStatus) {
    let wanted: SessionKind?
    switch status {
    case .authorizedAlways: wanted = .always
    case .authorizedWhenInUse: wanted = .whenInUse
    default: wanted = nil // notDetermined / denied / restricted
    }
    if wanted == serviceSessionKind, serviceSession != nil || wanted == nil { return }

    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    serviceSession?.invalidate()
    serviceSession = nil
    serviceSessionKind = wanted
    lastServiceDiagnostic = nil
    guard let wanted else { return }

    let session = CLServiceSession(authorization: wanted == .always ? .always : .whenInUse)
    serviceSession = session
    diagnosticsTask = Task { @MainActor [weak self] in
      do {
        for try await d in session.diagnostics {
          self?.lastServiceDiagnostic = ServiceSessionFlags(d)
        }
      } catch {
        // Diagnostics stream ended; keep the last snapshot.
      }
    }
  }

  // MARK: GPS (driving only)

  /// A liveUpdates loop is running right now.
  var isGPSActive: Bool { liveTask != nil }
  /// The state machine wants GPS; may be true while `isGPSActive` is false (restart pending).
  var isGPSRequested: Bool { gpsWanted }

  /// Effect `.startGPS`. Idempotent.
  func startGPS() {
    gpsWanted = true
    restartAttempts = 0
    // No location authorization: start neither the live loop nor the background session
    // (it would only show an indicator without data). `gpsWanted` stays true, so the
    // authorization callback starts GPS if permission is granted while still wanted.
    guard hasLocationAuthorization else { return }
    // Keeps the app running in the background and shows the blue indicator while driving.
    // NOTE(iOS): Apple documents starting a CLBackgroundActivitySession from the foreground;
    // a session recreated during a background relaunch continues one that existed before.
    // Our trips usually start from a background wake (SLC / geofence). With Always
    // authorization liveUpdates are still delivered in the background; whether the session
    // created here is honoured must be verified on device (see report, field scenarios).
    if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
    guard liveTask == nil else { return }
    restartTask?.cancel()
    restartTask = nil
    startLiveLoop()
  }

  private func startLiveLoop() {
    liveGeneration += 1
    let generation = liveGeneration
    liveTask = Task { @MainActor [weak self] in
      do {
        for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
          if Task.isCancelled { break }
          guard let self else { break }
          self.lastLiveFlags = LiveUpdateFlags(update)
          if let location = update.location {
            self.restartAttempts = 0
            self.onEvent?(.location(LocationSample(location)))
          }
        }
      } catch {
        // Stream failed (e.g. authorization revoked); handled below like a normal end.
      }
      self?.liveLoopEnded(generation: generation)
    }
  }

  /// The liveUpdates sequence finished or threw. Clear `liveTask` so `isGPSActive` is
  /// truthful, and if the state machine still wants GPS, restart after a short backoff
  /// (2, 4, 8 … max 60 s). A loop ended by stopGPS / a newer loop is ignored (generation).
  private func liveLoopEnded(generation: Int) {
    guard generation == liveGeneration else { return }
    liveTask = nil
    lastLiveFlags = nil
    guard gpsWanted else { return }
    let delay = min(60, 2 << min(restartAttempts, 5)) // 2,4,8,16,32,60
    restartAttempts += 1
    restartTask?.cancel()
    restartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, !Task.isCancelled, self.gpsWanted, self.liveTask == nil else { return }
      self.restartTask = nil
      // Authorization revoked: stop retrying; the authorization callback restarts GPS.
      guard self.hasLocationAuthorization else { return }
      self.startLiveLoop()
    }
  }

  var hasLocationAuthorization: Bool {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: return true
    default: return false
    }
  }

  /// Authorization changed while GPS is wanted: start it once granted, release the session
  /// and loop once revoked (gpsWanted stays true; the state machine decides when to stop).
  private func applyAuthorizationToGPS() {
    guard gpsWanted else { return }
    if hasLocationAuthorization {
      if liveTask == nil { startGPS() }
    } else {
      liveGeneration += 1 // the loop's end is stale; no restart attempts
      restartTask?.cancel()
      restartTask = nil
      liveTask?.cancel()
      liveTask = nil
      backgroundSession?.invalidate()
      backgroundSession = nil
      lastLiveFlags = nil
    }
  }

  /// Effect `.stopGPS`. Idempotent.
  func stopGPS() {
    gpsWanted = false
    liveGeneration += 1 // the cancelled loop's end is now stale
    restartTask?.cancel()
    restartTask = nil
    restartAttempts = 0
    liveTask?.cancel()
    liveTask = nil
    backgroundSession?.invalidate()
    backgroundSession = nil
    lastLiveFlags = nil
  }

  // MARK: Geofence (CLMonitor)

  /// CLMonitor persists its conditions across launches by itself; we only have to reopen it
  /// with the same name at every launch and consume `events`, otherwise the exit event that
  /// relaunched us is not delivered. Only one instance per name may exist in the process.
  private func startMonitorIfNeeded() {
    guard monitorTask == nil else { return }
    monitorTask = Task { @MainActor [weak self] in
      // NOTE(iOS): CLMonitor is an actor in the SDK, hence the awaits. If it turns out to be
      // a plain class the awaits only produce "no async operations" warnings.
      let monitor = await CLMonitor(Self.monitorName)
      guard let self else { return }
      self.monitor = monitor
      let ids = await monitor.identifiers
      self.geofenceActive = ids.contains(Self.parkConditionID)
      do {
        for try await event in await monitor.events {
          guard event.identifier == Self.parkConditionID else { continue }
          // `.unsatisfied` = we left the circle around the parked car.
          if event.state == .unsatisfied {
            self.onEvent?(.wake(.geofenceExit))
          }
        }
      } catch {
        // Events stream ended; it is reopened at next launch.
      }
    }
  }

  /// Effect `.setGeofence`. Replaces any previous park condition.
  func setGeofence(center: LocationSample, radius: Double) {
    let coordinate = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
    enqueueGeofenceOperation { [weak self] monitor in
      await monitor.remove(Self.parkConditionID)
      let condition = CLMonitor.CircularGeographicCondition(center: coordinate, radius: radius)
      // We are standing at the car when this is set, so assume "inside"; the next transition
      // we care about is the exit.
      await monitor.add(condition, identifier: Self.parkConditionID, assuming: .satisfied)
      self?.geofenceActive = true
    }
  }

  /// Effect `.clearGeofence` (not emitted by the reducer; Karar D. Kept for history deletion).
  func clearGeofence() {
    enqueueGeofenceOperation { [weak self] monitor in
      await monitor.remove(Self.parkConditionID)
      self?.geofenceActive = false
    }
  }

  /// History deletion: removes the park condition and confirms that the monitor no longer
  /// lists it. Returns false if the monitor could not be opened or the condition is still
  /// there. Runs in the same serialized chain as set/clear (after any earlier operation).
  func clearGeofenceVerified() async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      enqueueGeofenceOperation(onUnavailable: { cont.resume(returning: false) }) { [weak self] monitor in
        await monitor.remove(Self.parkConditionID)
        let ids = await monitor.identifiers
        let gone = !ids.contains(Self.parkConditionID)
        if gone { self?.geofenceActive = false }
        cont.resume(returning: gone)
      }
    }
  }

  /// Runs geofence operations one after another in call order. Each one awaits the monitor
  /// and CLMonitor calls, so independent Tasks could interleave (an older set finishing after
  /// a newer one would leave the wrong circle). `onUnavailable` runs instead of `operation`
  /// when the monitor cannot be obtained (so an awaiting caller is always resumed).
  private func enqueueGeofenceOperation(
    onUnavailable: (@MainActor () -> Void)? = nil,
    _ operation: @escaping @MainActor (CLMonitor) async -> Void
  ) {
    let previous = geofenceChain
    geofenceChain = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, let monitor = await self.awaitMonitor() else {
        onUnavailable?()
        return
      }
      await operation(monitor)
    }
  }

  /// The monitor is opened asynchronously at start; effects may arrive before that.
  private func awaitMonitor() async -> CLMonitor? {
    startMonitorIfNeeded()
    for _ in 0..<50 {
      if let monitor { return monitor }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return monitor
  }
}

// MARK: - CLLocationManagerDelegate

extension LocationSensor: CLLocationManagerDelegate {
  // Delegate methods are delivered on the main thread (manager created there).
  // `nonisolated` + assumeIsolated keeps the protocol conformance valid under strict checking.

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    MainActor.assumeIsolated {
      self.refreshAuthorizationDependents()
      self.resolveAuthorizationWaitersIfDecided()
      self.applyAuthorizationToGPS()
      self.onAuthorizationChange?()
    }
  }

  /// Only significant-location-change fixes arrive here (no standard updates on this
  /// manager). They are coarse (hundreds of metres), so they are used only as a wake signal
  /// and never as a `.location` sample: a coarse fix could fake the 30–50 m walk-away check.
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    MainActor.assumeIsolated {
      self.onEvent?(.wake(.significantLocationChange))
    }
  }

  /// Arrivals mean "stopped somewhere" and would only waste 5 min of GPS in MAYBE_DRIVING;
  /// departures are a plausible trip start, so only those wake the state machine.
  nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let isDeparture = visit.departureDate != Date.distantFuture
    MainActor.assumeIsolated {
      if isDeparture { self.onEvent?(.wake(.visit)) }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // kCLErrorLocationUnknown is transient; denial is reported via authorization change.
  }
}

extension LocationSensor {
  private func resolveAuthorizationWaitersIfDecided() {
    let status = manager.authorizationStatus
    // A WhenInUse grant while asking for Always means the upgrade prompt was declined or
    // deferred; resolve anyway, the caller re-reads diagnostics.
    if status != .notDetermined { resolveAuthorizationWaiters() }
  }
}

// MARK: - Value mapping

extension LocationSample {
  init(_ location: CLLocation) {
    self.init(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      accuracy: location.horizontalAccuracy,
      speed: location.speed, // negative when invalid, matches LocationSample contract
      timestamp: location.timestamp)
  }
}

/// `CLServiceSession.Diagnostic` flags (iOS 18). No location data.
struct ServiceSessionFlags: Equatable {
  var authorizationDenied: Bool
  var authorizationDeniedGlobally: Bool
  var authorizationRestricted: Bool
  var insufficientlyInUse: Bool
  var serviceSessionRequired: Bool
  var fullAccuracyDenied: Bool
  var alwaysAuthorizationDenied: Bool
  var authorizationRequestInProgress: Bool

  // NOTE(iOS 18): property names per the iOS 18 SDK `CLServiceSession.Diagnostic`, including
  // `serviceSessionRequired` (present in the SDK; confirmed by the CI build).
  init(_ d: CLServiceSession.Diagnostic) {
    authorizationDenied = d.authorizationDenied
    authorizationDeniedGlobally = d.authorizationDeniedGlobally
    authorizationRestricted = d.authorizationRestricted
    insufficientlyInUse = d.insufficientlyInUse
    serviceSessionRequired = d.serviceSessionRequired
    fullAccuracyDenied = d.fullAccuracyDenied
    alwaysAuthorizationDenied = d.alwaysAuthorizationDenied
    authorizationRequestInProgress = d.authorizationRequestInProgress
  }

  var dictionary: [String: Any] {
    [
      "authorizationDenied": authorizationDenied,
      "authorizationDeniedGlobally": authorizationDeniedGlobally,
      "authorizationRestricted": authorizationRestricted,
      "insufficientlyInUse": insufficientlyInUse,
      "serviceSessionRequired": serviceSessionRequired,
      "fullAccuracyDenied": fullAccuracyDenied,
      "alwaysAuthorizationDenied": alwaysAuthorizationDenied,
      "authorizationRequestInProgress": authorizationRequestInProgress,
    ]
  }
}

/// Flags of the latest `CLLocationUpdate` while driving (iOS 18). No location data.
struct LiveUpdateFlags: Equatable {
  var stationary: Bool
  var locationUnavailable: Bool
  var accuracyLimited: Bool
  var insufficientlyInUse: Bool
  var serviceSessionRequired: Bool

  // NOTE(iOS 18): `stationary` replaces iOS 17's `isStationary`; the others are iOS 18 additions.
  init(_ u: CLLocationUpdate) {
    stationary = u.stationary
    locationUnavailable = u.locationUnavailable
    accuracyLimited = u.accuracyLimited
    insufficientlyInUse = u.insufficientlyInUse
    serviceSessionRequired = u.serviceSessionRequired
  }

  var dictionary: [String: Any] {
    [
      "stationary": stationary,
      "locationUnavailable": locationUnavailable,
      "accuracyLimited": accuracyLimited,
      "insufficientlyInUse": insufficientlyInUse,
      "serviceSessionRequired": serviceSessionRequired,
    ]
  }
}
