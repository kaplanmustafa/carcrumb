import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

// QA edge cases for route retention (docs/DECISIONS.md "Rota saklama süresi"). Runs only on
// macOS CI (`swift test`). Synthetic coordinates only (RouteFixtures: 41.0 / -40.0 + metres north).

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let day: TimeInterval = 24 * 60 * 60

final class RouteRetentionCutoffEdgeTests: XCTestCase {
  func testLeapDayAndMonthEnds() {
    // Leap year 2028.
    XCTAssertEqual(RouteRetention.twelveMonths.cutoff(now: utc(2028, 2, 29)), utc(2027, 2, 28), "29 Feb - 12 months")
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2028, 5, 29)), utc(2028, 2, 29), "lands on the leap day")
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2028, 5, 31)), utc(2028, 2, 29), "clamped to the leap day")
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2027, 5, 31)), utc(2027, 2, 28))
    XCTAssertEqual(RouteRetention.twelveMonths.cutoff(now: utc(2029, 2, 28)), utc(2028, 2, 28))
    // 31-day month into a 30-day one, and across the year boundary.
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2026, 12, 31)), utc(2026, 9, 30))
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2027, 1, 15, 0, 30)), utc(2026, 10, 15, 0, 30))
    XCTAssertEqual(RouteRetention.twelveMonths.cutoff(now: utc(2026, 12, 31, 23, 59)), utc(2025, 12, 31, 23, 59))
  }

  /// Moving `now` forward never moves the limit backward (no route that was already purged
  /// "should" have been kept), and the limit is always in the past.
  func testCutoffIsMonotonicAndInThePast() throws {
    for retention in [RouteRetention.threeMonths, .twelveMonths] {
      var previous: Date?
      var now = utc(2026, 1, 1, 0)
      while now < utc(2030, 1, 1, 0) {
        let cutoff = try XCTUnwrap(retention.cutoff(now: now))
        XCTAssertLessThan(cutoff, now)
        if let previous { XCTAssertGreaterThanOrEqual(cutoff, previous, "\(retention) at \(now)") }
        previous = cutoff
        now = now.addingTimeInterval(day / 2)
      }
    }
  }

  /// UTC calendar: the device time zone does not change the limit for the same instant.
  func testCutoffIndependentOfDeviceTimeZone() {
    let instant = utc(2026, 3, 1, 0, 30) // 1 Mar in UTC, still 28 Feb west of UTC
    let saved = NSTimeZone.default
    defer { NSTimeZone.default = saved }
    var results: Set<Date> = []
    for id in ["UTC", "Europe/Istanbul", "America/Los_Angeles", "Pacific/Kiritimati"] {
      NSTimeZone.default = TimeZone(identifier: id)!
      results.insert(RouteRetention.threeMonths.cutoff(now: instant)!)
    }
    XCTAssertEqual(results, [utc(2025, 12, 1, 0, 30)])
  }
}

/// Same scenarios against both stores. `now` is chosen so trips end whole days before it.
enum RouteRetentionEdgeScenarios {
  static let now = StoreFixtures.date(500 * day)

  @discardableResult
  static func trip(_ store: DetectionStore, endedDaysAgo days: Double) throws -> Int64 {
    let end = 500 * day - days * day
    return try RouteRetentionScenarios.closedTrip(store, endingAt: end)
  }

  /// forever → 3 months → 12 months → forever: only the stricter setting deletes; widening it
  /// later does not bring routes back and deletes nothing more; trip rows always stay.
  static func settingTransitions(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let old = try trip(store, endedDaysAgo: 400)
    let mid = try trip(store, endedDaysAgo: 200)
    let recent = try trip(store, endedDaysAgo: 100)
    let fresh = try trip(store, endedDaysAgo: 10)

    XCTAssertNil(RouteRetention.forever.cutoff(now: now), "forever: the engine purges nothing", file: file, line: line)

    let threeMonths = try XCTUnwrap(RouteRetention.threeMonths.cutoff(now: now), file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: threeMonths), 12, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: old), [], file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: mid), [], file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: recent), [], "100 days > 3 months", file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: fresh).count, 4, file: file, line: line)

    let twelveMonths = try XCTUnwrap(RouteRetention.twelveMonths.cutoff(now: now), file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: twelveMonths), 0, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: mid), [], "widening does not restore", file: file, line: line)
    XCTAssertEqual(try store.trips(limit: 10).count, 4, file: file, line: line)
    XCTAssertTrue(try store.trips(limit: 10).allSatisfy { $0.distanceMeters != nil }, "distances survive", file: file, line: line)
  }

  /// Default 12 months on a store with the same trips: only the 400-day-old route goes.
  static func defaultTwelveMonths(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let old = try trip(store, endedDaysAgo: 400)
    let mid = try trip(store, endedDaysAgo: 200)
    let cutoff = try XCTUnwrap(RouteRetention.default.cutoff(now: now), file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 4, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: old), [], file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: mid).count, 4, file: file, line: line)
  }

  /// Purge between two batches of an open trip that started before the limit: the open
  /// trip's route, seq and running distance continue; once closed and expired, it is purged.
  static func purgeBetweenOpenTripBatches(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let expiredClosed = try trip(store, endedDaysAgo: 400)
    let start = 500 * day - 401 * day // started long before the limit, still driving (bad clock / restore)
    let open = try store.beginTrip(startedAt: StoreFixtures.date(start))
    let route = RouteFixtures.straightRoute(6, from: start)
    try store.appendRoutePoints(Array(route[0..<3]), tripID: open, maxPoints: 5000)

    let cutoff = try XCTUnwrap(RouteRetention.threeMonths.cutoff(now: now), file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 4, "only the closed trip", file: file, line: line)

    try store.appendRoutePoints(Array(route[3...]), tripID: open, maxPoints: 5000)
    XCTAssertEqual(try store.tripRoute(tripID: open), route, file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 10).first { $0.id == open }?.distanceMeters, file: file, line: line),
                   500, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: expiredClosed), [], file: file, line: line)

    // Closed just now: not expired.
    try store.endTrip(tripID: open, status: .confirmed, endedAt: now)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 0, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: open).count, 6, file: file, line: line)
    // A later run once it is older than the limit.
    let later = try XCTUnwrap(RouteRetention.threeMonths.cutoff(now: now.addingTimeInterval(100 * day)), file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: later), 6, file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 10).first { $0.id == open }?.distanceMeters, file: file, line: line),
                   500, accuracy: 0.01, file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try settingTransitions(make())
    try defaultTwelveMonths(make())
    try purgeBetweenOpenTripBatches(make())
  }
}

final class InMemoryRouteRetentionEdgeTests: XCTestCase {
  func testSameEdgeCasesAsSQLiteStore() throws {
    try RouteRetentionEdgeScenarios.runAll { InMemoryDetectionStore() }
  }
}

final class GRDBRouteRetentionEdgeTests: TemporaryDirectoryTestCase {
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  func testSettingTransitions() throws { try RouteRetentionEdgeScenarios.settingTransitions(fresh()) }
  func testDefaultTwelveMonths() throws { try RouteRetentionEdgeScenarios.defaultTwelveMonths(fresh()) }
  func testPurgeBetweenOpenTripBatches() throws { try RouteRetentionEdgeScenarios.purgeBetweenOpenTripBatches(fresh()) }

  /// Setting changed, then the process dies before the purge ran: the next engine start reads
  /// the stored setting (new `RouteRetentionSettings` / `UserDefaults` instance) and purges
  /// with it. `lastPurgeAt` is not involved (start purges are forced).
  func testSettingWrittenBeforeRestartIsUsedAtStart() throws {
    let suite = "carcrumb-retention-qa-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    RouteRetentionSettings(defaults: defaults).retention = .threeMonths // set, then "killed"

    let store = makeStore()
    let mid = try RouteRetentionEdgeScenarios.trip(store, endedDaysAgo: 200)

    let atStart = RouteRetentionSettings(defaults: UserDefaults(suiteName: suite)!)
    XCTAssertEqual(atStart.retention, .threeMonths)
    XCTAssertNil(atStart.lastPurgeAt)
    let cutoff = try XCTUnwrap(atStart.retention.cutoff(now: RouteRetentionEdgeScenarios.now))
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 4)
    XCTAssertEqual(try store.tripRoute(tripID: mid), [])
  }

  /// Before the first unlock the purge throws `.unavailable` (the engine then does not record
  /// `lastPurgeAt` and retries); after the unlock the same purge works.
  func testLockedDatabasePurgeThrowsThenSucceeds() throws {
    struct Locked: Error {}
    var locked = false
    let dir = directory!
    let provider: () throws -> URL = {
      if locked { throw Locked() }
      return dir
    }
    let setup = GRDBDetectionStore(directoryProvider: provider)
    let old = try RouteRetentionEdgeScenarios.trip(setup, endedDaysAgo: 400)

    let relaunched = GRDBDetectionStore(directoryProvider: provider)
    locked = true
    let cutoff = try XCTUnwrap(RouteRetention.twelveMonths.cutoff(now: RouteRetentionEdgeScenarios.now))
    XCTAssertThrowsError(try relaunched.purgeExpiredRoutes(olderThan: cutoff)) {
      XCTAssertEqual($0 as? StoreError, .unavailable)
    }
    XCTAssertEqual(relaunched.pendingWriteCount, 0, "a purge is never buffered")

    locked = false
    XCTAssertEqual(try relaunched.purgeExpiredRoutes(olderThan: cutoff), 4)
    XCTAssertEqual(try relaunched.tripRoute(tripID: old), [])
  }
}
