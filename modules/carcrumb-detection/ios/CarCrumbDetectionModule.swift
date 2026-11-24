import ExpoModulesCore

// Bridge only. Detection runs in Swift even when JS is not loaded (background wake);
// JS listens to events and queries state. Sensor wiring (CLLocationUpdate.liveUpdates,
// CLBackgroundActivitySession, CLServiceSession, CMMotionActivityManager, AVAudioSession)
// and the GRDB store are added in follow-up steps.
public class CarCrumbDetectionModule: Module {
  private var state: DetectionState = .idle

  public func definition() -> ModuleDefinition {
    Name("CarCrumbDetection")

    Events("onStateChange")

    Function("getState") { () -> String in
      self.state.name
    }
  }
}
