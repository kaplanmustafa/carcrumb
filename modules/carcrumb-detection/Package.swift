// swift-tools-version:6.0
// Builds and tests only the pure detection core (no Expo, no CoreLocation) so the
// state machine can be checked with `swift test` on macOS CI without building the app.
// The app itself uses ios/CarCrumbDetection.podspec; this file is not part of that pod.
import PackageDescription

let package = Package(
  name: "CarCrumbDetection",
  platforms: [.iOS(.v18), .macOS(.v14)],
  products: [
    .library(name: "CarCrumbDetection", targets: ["CarCrumbDetection"]),
  ],
  targets: [
    .target(name: "CarCrumbDetection", path: "ios/Detection"),
    .testTarget(name: "CarCrumbDetectionTests", dependencies: ["CarCrumbDetection"], path: "ios/Tests"),
  ],
  // Same language mode as the pod (podspec swift_version 5.9).
  swiftLanguageModes: [.v5]
)
