import XCTest
@testable import CarCrumbDetection

/// "Geçmişi sil" geofence step. Konumsuz mod (no permission → no CLMonitor) must not fail
/// history deletion; only a condition that is provably still registered does.
final class GeofenceClearPolicyTests: XCTestCase {
  func testRemovedSucceeds() {
    XCTAssertTrue(GeofenceClearPolicy.succeeded(.removed))
  }

  func testMonitorUnavailableSucceedsWithoutLocationPermission() {
    XCTAssertTrue(GeofenceClearPolicy.succeeded(.monitorUnavailable))
  }

  func testConditionStillPresentFails() {
    XCTAssertFalse(GeofenceClearPolicy.succeeded(.stillPresent))
  }
}
