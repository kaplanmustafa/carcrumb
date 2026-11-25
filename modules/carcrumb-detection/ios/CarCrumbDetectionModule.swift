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

    // Debug sensor traces. Release builds: empty list / null.
    Function("listTraces") { () -> [String] in
      TraceRecorder.listTraces()
    }

    Function("getTracePath") { (name: String) -> String? in
      TraceRecorder.path(of: name)
    }
  }
}
