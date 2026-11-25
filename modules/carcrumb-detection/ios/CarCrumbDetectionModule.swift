import ExpoModulesCore

// Bridge only. Detection runs in Swift (DetectionEngine) even when JS is not loaded
// (background wake, started by DetectionAppDelegateSubscriber). JS listens to events and
// queries state/diagnostics. Nothing returned here contains coordinates.
//
// Keep in sync with src/CarCrumbDetection.types.ts and src/CarCrumbDetectionModule.ts.
public class CarCrumbDetectionModule: Module {
  private var observerToken: UUID?

  public func definition() -> ModuleDefinition {
    Name("CarCrumbDetection")

    Events("onStateChange")

    OnCreate {
      // Safety net if the app delegate subscriber did not run; start() is idempotent.
      DispatchQueue.main.async {
        MainActor.assumeIsolated { DetectionEngine.shared.start() }
      }
      // Observer runs on the engine queue; sendEvent is safe to call from any thread.
      self.observerToken = DetectionEngine.shared.addStateObserver { [weak self] name in
        self?.sendEvent("onStateChange", ["state": name])
      }
    }

    OnDestroy {
      if let token = self.observerToken {
        DetectionEngine.shared.removeStateObserver(token)
      }
    }

    Function("getState") { () -> String in
      DetectionEngine.shared.stateName
    }

    /// Resolves with "notDetermined" | "restricted" | "denied" | "whenInUse" | "always".
    AsyncFunction("requestWhenInUseAuthorization") { (promise: Promise) in
      Task { @MainActor in
        promise.resolve(await DetectionEngine.shared.requestWhenInUseAuthorization())
      }
    }

    AsyncFunction("requestAlwaysAuthorization") { (promise: Promise) in
      Task { @MainActor in
        promise.resolve(await DetectionEngine.shared.requestAlwaysAuthorization())
      }
    }

    /// Resolves with "notDetermined" | "restricted" | "denied" | "authorized".
    AsyncFunction("requestMotionAuthorization") { (promise: Promise) in
      DetectionEngine.shared.requestMotionAuthorization { status in
        promise.resolve(status)
      }
    }

    AsyncFunction("getDiagnostics") { (promise: Promise) in
      Task { @MainActor in
        promise.resolve(await DetectionEngine.shared.diagnostics())
      }
    }

    // MARK: History (SQLite; Swift is the only writer, these only read)
    //
    // Parks contain coordinates: they go to JS for display ("Arabam nerede", map link) and are
    // never logged on either side. Store reads run on the engine queue.

    /// Current park or null. Rejects with ERR_STORE_UNAVAILABLE before the first unlock.
    AsyncFunction("getLastParking") { (promise: Promise) in
      DetectionEngine.shared.readStore({ try $0.lastParking() }) { result in
        switch result {
        case let .success(parking):
          if let parking { promise.resolve(BridgeValues.parking(parking)) } else { promise.resolve(NSNull()) }
        case let .failure(error):
          BridgeValues.reject(promise, error)
        }
      }
    }

    /// Up to 3 parks, current first (alternatives when the current one has low confidence).
    AsyncFunction("listRecentParkings") { (promise: Promise) in
      DetectionEngine.shared.readStore({ try $0.recentParkings() }) { result in
        switch result {
        case let .success(parkings): promise.resolve(parkings.map(BridgeValues.parking))
        case let .failure(error): BridgeValues.reject(promise, error)
        }
      }
    }

    /// Newest first. `limit` is a JS number: rounded to the nearest integer and clamped to
    /// 1...500 (non-finite → 50). Taken as Double so 10.5 or 1e3 never fail the conversion.
    AsyncFunction("listTrips") { (limit: Double, promise: Promise) in
      let clamped = limit.isFinite ? Int(min(max(limit.rounded(), 1), 500)) : 50
      DetectionEngine.shared.readStore({ try $0.trips(limit: clamped) }) { result in
        switch result {
        case let .success(trips): promise.resolve(trips.map(BridgeValues.trip))
        case let .failure(error): BridgeValues.reject(promise, error)
        }
      }
    }

    /// Deletes all history (docs/DECISIONS.md checklist, see DetectionEngine.deleteAllHistory).
    /// Resolves after the CLMonitor park condition is confirmed removed. Rejects with
    /// ERR_DELETE_HISTORY and the failed step ("database" | "stateFile" | "geofence" | "traces").
    AsyncFunction("deleteAllHistory") { (promise: Promise) in
      DetectionEngine.shared.deleteAllHistory { result in
        switch result {
        case .success: promise.resolve(NSNull())
        case let .failure(step): promise.reject("ERR_DELETE_HISTORY", step.rawValue)
        }
      }
    }

    // Debug sensor traces. Release builds: empty list / null.
    Function("listTraces") { () -> [String] in
      TraceRecorder.listTraces()
    }

    Function("getTracePath") { (name: String) -> String? in
      TraceRecorder.path(of: name)
    }
  }
}

/// JS shapes of store records. Keep in sync with `ParkingRecord` / `TripRecord` in
/// src/CarCrumbDetection.types.ts. Dates are milliseconds since 1970 (JS `Date` friendly).
enum BridgeValues {
  static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

  static func parking(_ p: StoredParking) -> [String: Any] {
    [
      "id": Int(p.id),
      "tripId": p.tripID.map { Int($0) as Any } ?? NSNull(),
      "latitude": p.latitude,
      "longitude": p.longitude,
      "accuracy": p.accuracy,
      "confidence": p.confidence.rawValue,
      "parkedAt": ms(p.parkedAt),
    ]
  }

  static func trip(_ t: StoredTrip) -> [String: Any] {
    [
      "id": Int(t.id),
      "startedAt": ms(t.startedAt),
      "endedAt": t.endedAt.map { ms($0) as Any } ?? NSNull(),
      "status": t.status?.rawValue ?? "open",
      "distanceMeters": t.distanceMeters.map { $0 as Any } ?? NSNull(),
    ]
  }

  /// Error code only; never the error text (paths) or any record content.
  static func reject(_ promise: Promise, _ error: Error) {
    if (error as? StoreError) == .unavailable {
      promise.reject("ERR_STORE_UNAVAILABLE", "History is not readable yet (device not unlocked since restart).")
    } else {
      promise.reject("ERR_STORE", "History could not be read.")
    }
  }
}
