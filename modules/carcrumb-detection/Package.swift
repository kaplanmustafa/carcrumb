// swift-tools-version:6.0
// Builds and tests the pure detection core and the SQLite store (no Expo, no CoreLocation)
// with `swift test` on macOS CI, without building the app.
// The app itself uses ios/CarCrumbDetection.podspec (one module, GRDB via spm_dependency);
// this file is not part of that pod.
//
// Targets mirror the pod's folders:
// - CarCrumbDetection (ios/Detection): state machine, Foundation only.
// - CarCrumbStore (ios/Store): DetectionStore + GRDB store, Foundation + GRDB only. In the
//   pod it is the same module as Detection; here it imports it, guarded by CARCRUMB_SPM.
import PackageDescription

let package = Package(
  name: "CarCrumbDetection",
  platforms: [.iOS(.v18), .macOS(.v14)],
  products: [
    .library(name: "CarCrumbDetection", targets: ["CarCrumbDetection"]),
    .library(name: "CarCrumbStore", targets: ["CarCrumbStore"]),
  ],
  dependencies: [
    // Same range as the podspec's spm_dependency (up to next major from 7.0.0).
    .package(url: "https://github.com/groue/GRDB.swift.git", "7.0.0"..<"8.0.0"),
  ],
  targets: [
    .target(name: "CarCrumbDetection", path: "ios/Detection"),
    .target(
      name: "CarCrumbStore",
      dependencies: ["CarCrumbDetection", .product(name: "GRDB", package: "GRDB.swift")],
      path: "ios/Store",
      swiftSettings: [.define("CARCRUMB_SPM")]),
    .testTarget(name: "CarCrumbDetectionTests", dependencies: ["CarCrumbDetection"], path: "ios/Tests"),
    .testTarget(
      name: "CarCrumbStoreTests",
      dependencies: ["CarCrumbStore", "CarCrumbDetection", .product(name: "GRDB", package: "GRDB.swift")],
      path: "ios/StoreTests"),
  ],
  // Same language mode as the pod (podspec swift_version 5.9).
  swiftLanguageModes: [.v5]
)
