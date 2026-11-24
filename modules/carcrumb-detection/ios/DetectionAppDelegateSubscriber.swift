import ExpoModulesCore
import os
import UIKit

/// Starts detection at app launch, before React Native / JS is loaded.
///
/// Registered in expo-module.config.json under `apple.appDelegateSubscribers` (field name
/// verified against expo-modules-autolinking 58.1.0: `ExpoModuleConfig.appleAppDelegateSubscribers()`
/// reads `apple.appDelegateSubscribers`). Autolinking adds this class to the generated
/// ExpoModulesProvider and ExpoAppDelegate forwards UIApplicationDelegate calls to it.
///
/// Background wake: when iOS relaunches the terminated app for a significant location
/// change or a CLMonitor geofence exit, `launchOptions[.location]` is set. The pending event
/// is delivered only to a CLLocationManager / CLMonitor created during this launch, so the
/// engine (and its LocationSensor) must be created here, synchronously, without waiting for JS.
/// We start it on every launch (foreground ones too); start() never shows a permission prompt.
public final class DetectionAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  // `os.Logger`, not ExpoModulesCore's `Logger` (both are visible in this file).
  private let log = os.Logger(subsystem: "app.carcrumb", category: "launch")

  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let locationLaunch = launchOptions?[.location] != nil
    log.info("launch (location wake: \(locationLaunch, privacy: .public))")
    MainActor.assumeIsolated {
      DetectionEngine.shared.start()
    }
    return true
  }

  public func applicationDidBecomeActive(_ application: UIApplication) {
    MainActor.assumeIsolated {
      DetectionEngine.shared.applicationDidBecomeActive()
    }
  }
}
