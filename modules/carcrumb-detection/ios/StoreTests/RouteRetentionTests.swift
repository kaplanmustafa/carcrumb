import Foundation
import GRDB
import XCTest
import CarCrumbDetection
@testable import CarCrumbStore

// Route retention (docs/DECISIONS.md "Rota saklama süresi"), running distance, thinning count
// and its restore. Synthetic coordinates only (CLAUDE.md: 41.0±0.1 / -40.0±0.1). Runs on macOS
// CI (`swift test`).

private extension RouteFixtures {
  /// `count` points going north 100 m per step, alternating 0 / 100 m east (a zig-zag): a
  /// thinned version is clearly shorter than the original polyline.
  static func zigzag(_ count: Int, from start: TimeInterval = 0) -> [RoutePoint] {
    let metresPerDegreeLon = metresPerDegreeLat * cos(41.0 * .pi / 180)
    return (0..<count).map { i in
      RoutePoint(
        latitude: 41.0 + Double(i) * 100 / metresPerDegreeLat,
        longitude: -40.0 + Double(i % 2) * 100 / metresPerDegreeLon,
        accuracy: 5, timestamp: StoreFixtures.date(start + Double(i) * 10))
    }
  }
}

// MARK: - Pure parts

final class RouteRetentionPolicyTests: XCTestCase {
  private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
  }

  func testRawValuesAreTheBridgeValues() {
    XCTAssertEqual(RouteRetention.allCases.map(\.rawValue), ["threeMonths", "twelveMonths", "forever"])
    XCTAssertEqual(RouteRetention.default, .twelveMonths)
  }

  func testCutoffIsCalendarMonths() {
    let now = utc(2026, 11, 26)
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: now), utc(2026, 8, 26, 0))
    XCTAssertEqual(RouteRetention.twelveMonths.cutoff(now: now), utc(2025, 11, 26, 0))
    XCTAssertNil(RouteRetention.forever.cutoff(now: now), "forever: nothing is ever purged")
    // Month end: 31 May - 3 months is the last day of February.
    XCTAssertEqual(RouteRetention.threeMonths.cutoff(now: utc(2026, 5, 31)), utc(2026, 2, 28, 0))
  }

  func testPurgeScheduleAtMostOnceADay() {
    let t = StoreFixtures.date(0)
    XCTAssertTrue(RoutePurgeSchedule.isDue(lastRun: nil, now: t), "never ran")
    XCTAssertFalse(RoutePurgeSchedule.isDue(lastRun: t, now: t.addingTimeInterval(23 * 3600)))
    XCTAssertTrue(RoutePurgeSchedule.isDue(lastRun: t, now: t.addingTimeInterval(24 * 3600)))
    XCTAssertTrue(RoutePurgeSchedule.isDue(lastRun: t, now: t.addingTimeInterval(-60)), "clock set back: run")
  }

  func testSettingsInUserDefaults() throws {
    let suite = "carcrumb-retention-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = RouteRetentionSettings(defaults: defaults)
    XCTAssertEqual(settings.retention, .twelveMonths, "default when unset")
    XCTAssertNil(settings.lastPurgeAt)

    settings.retention = .threeMonths
    XCTAssertEqual(defaults.string(forKey: "carcrumb.routeRetention"), "threeMonths")
    XCTAssertEqual(RouteRetentionSettings(defaults: defaults).retention, .threeMonths, "read back by a new instance")

    defaults.set("sixMonths", forKey: RouteRetentionSettings.retentionKey)
    XCTAssertEqual(settings.retention, .twelveMonths, "unknown stored value: default")

    settings.lastPurgeAt = StoreFixtures.date(42)
    XCTAssertEqual(settings.lastPurgeAt, StoreFixtures.date(42))
  }
}

final class RouteThinCountTests: XCTestCase {
  func testThinCountFromSeqGap() {
    XCTAssertEqual(RouteThinning.thinCount(firstSeq: 0, secondSeq: 1), 0)
    XCTAssertEqual(RouteThinning.thinCount(firstSeq: 0, secondSeq: 2), 1)
    XCTAssertEqual(RouteThinning.thinCount(firstSeq: 0, secondSeq: 4), 2)
    XCTAssertEqual(RouteThinning.thinCount(firstSeq: 0, secondSeq: 1024), 10)
    XCTAssertEqual(RouteThinning.thinCount(firstSeq: 5, secondSeq: 5), 0, "corrupt: no thinning assumed")
  }

  func testThinCountingMatchesThin() {
    XCTAssertEqual(RouteThinning.thinCounting(Array(0..<25), maxCount: 10).passes, 2)
    XCTAssertEqual(RouteThinning.thinCounting(Array(0..<25), maxCount: 10).points, RouteThinning.thin(Array(0..<25), maxCount: 10).points)
    XCTAssertEqual(RouteThinning.thinCounting(Array(0..<10), maxCount: 10).passes, 0)
  }

  /// Two halvings in one append double the spacing twice (was: once).
  func testSamplerScalesByEveryHalving() {
    var s = RouteSampler()
    s.begin(tripID: 1)
    s.didThin(times: RouteAppendResult(storedCount: 7, thinCount: 2).thinCount)
    XCTAssertEqual(s.spacingScale, 4)
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 0, at: 0), driving: true))
    XCTAssertFalse(s.offer(RouteFixtures.sample(north: 99, at: 59), driving: true), "< 100 m and < 60 s")
    XCTAssertTrue(s.offer(RouteFixtures.sample(north: 101, at: 59), driving: true))
    s.didThin(times: 0)
    XCTAssertEqual(s.spacingScale, 4, "no thinning: unchanged")
  }

  /// A restored trip starts at the stored density (was: back to 1 after every relaunch).
  func testBeginWithThinCountRestoresScale() {
    var s = RouteSampler()
    s.begin(tripID: 1, thinCount: 3)
    XCTAssertEqual(s.spacingScale, 8)
    s.begin(tripID: 2)
    XCTAssertEqual(s.spacingScale, 1, "a new trip starts dense")
  }
}

// MARK: - Store scenarios (both stores)

enum RouteRetentionScenarios {
  static let cutoff = StoreFixtures.date(10_000)

  @discardableResult
  static func closedTrip(_ store: DetectionStore, endingAt end: TimeInterval, status: TripStatus = .confirmed) throws -> Int64 {
    let id = try store.beginTrip(startedAt: StoreFixtures.date(end - 600))
    try store.appendRoutePoints(RouteFixtures.straightRoute(4, from: end - 600), tripID: id, maxPoints: 5000)
    try store.endTrip(tripID: id, status: status, endedAt: StoreFixtures.date(end))
    return id
  }

  /// Strictly older than the limit: purged; at or after it: kept. The trip rows stay with
  /// their status, dates and distance. A second run deletes nothing.
  static func boundary(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let before = try closedTrip(store, endingAt: 9_999)
    let uncertainBefore = try closedTrip(store, endingAt: 5_000, status: .uncertain)
    let at = try closedTrip(store, endingAt: 10_000)
    let after = try closedTrip(store, endingAt: 10_001)

    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 8, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: before), [], file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: uncertainBefore), [], "uncertain trips too", file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: at).count, 4, "endedAt == limit: not older, kept", file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: after).count, 4, file: file, line: line)

    let rows = try store.trips(limit: 10)
    XCTAssertEqual(rows.count, 4, "no trip row is deleted", file: file, line: line)
    let purged = try XCTUnwrap(rows.first { $0.id == before }, file: file, line: line)
    XCTAssertEqual(purged.status, .confirmed, file: file, line: line)
    XCTAssertEqual(purged.startedAt, StoreFixtures.date(9_399), file: file, line: line)
    XCTAssertEqual(purged.endedAt, StoreFixtures.date(9_999), file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(purged.distanceMeters, file: file, line: line), 300, accuracy: 0.01,
                   "distance survives the route", file: file, line: line)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 0, "idempotent", file: file, line: line)
  }

  /// An open trip is never purged, however old its start (no endedAt); its running distance
  /// is current. An abandoned trip (closed uncertain, endedAt = startedAt) keeps its distance
  /// and is purged like any closed trip.
  static func openAndAbandonedTrips(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let orphan = try store.beginTrip(startedAt: StoreFixtures.date(0))
    try store.appendRoutePoints(RouteFixtures.straightRoute(3), tripID: orphan, maxPoints: 5000)
    let open = try store.beginTrip(startedAt: StoreFixtures.date(100))
    try store.appendRoutePoints(RouteFixtures.straightRoute(5, from: 100), tripID: open, maxPoints: 5000)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 10).first { $0.id == open }?.distanceMeters, file: file, line: line),
                   400, accuracy: 0.01, "running distance while open", file: file, line: line)

    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 0, "both open: nothing", file: file, line: line)

    try store.abandonOpenTrips(except: open)
    let abandoned = try XCTUnwrap(try store.trips(limit: 10).first { $0.id == orphan }, file: file, line: line)
    XCTAssertEqual(abandoned.status, .uncertain, file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(abandoned.distanceMeters, file: file, line: line), 200, accuracy: 0.01,
                   "abandoned trip keeps its distance", file: file, line: line)

    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 3, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: orphan), [], file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: open).count, 5, "open trip untouched", file: file, line: line)
    let rows = try store.trips(limit: 10)
    XCTAssertEqual(try XCTUnwrap(rows.first { $0.id == orphan }?.distanceMeters, file: file, line: line), 200, accuracy: 0.01,
                   file: file, line: line)
    XCTAssertNil(rows.first { $0.id == open }?.status, "still open", file: file, line: line)
  }

  /// A limit before every trip (what "forever" never even calls, and what a fresh 12-month
  /// limit usually is): nothing deleted, every route intact.
  static func nothingExpiredIsANoOp(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try closedTrip(store, endingAt: 20_000)
    let b = try closedTrip(store, endingAt: 30_000)
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: cutoff), 0, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: a).count, 4, file: file, line: line)
    XCTAssertEqual(try store.tripRoute(tripID: b).count, 4, file: file, line: line)
    XCTAssertNil(RouteRetention.forever.cutoff(now: StoreFixtures.date(1e9)), file: file, line: line)
  }

  /// The distance is summed at write time: thinning a zig-zag (which cuts its corners) does
  /// not shorten it, neither while open nor at endTrip.
  static func thinningKeepsDistance(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    let route = RouteFixtures.zigzag(15)
    let full = try XCTUnwrap(RouteDistance.meters(route), file: file, line: line)
    try store.appendRoutePoints(Array(route[0..<8]), tripID: trip, maxPoints: 10)
    XCTAssertTrue(try store.appendRoutePoints(Array(route[8...]), tripID: trip, maxPoints: 10).thinned, file: file, line: line)
    let thinnedSum = try XCTUnwrap(RouteDistance.meters(try store.tripRoute(tripID: trip)), file: file, line: line)
    XCTAssertLessThan(thinnedSum, full - 100, "the thinned polyline is clearly shorter", file: file, line: line)
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line), full, accuracy: 0.01,
                   "open: full distance", file: file, line: line)
    try store.endTrip(tripID: trip, status: .confirmed, endedAt: StoreFixtures.date(600))
    XCTAssertEqual(try XCTUnwrap(try store.trips(limit: 1).first?.distanceMeters, file: file, line: line), full, accuracy: 0.01,
                   "closed: full distance, not the thinned route's", file: file, line: line)
  }

  /// Halvings are counted (one append far above the cap = 2) and readable after the fact.
  static func thinCountIsStored(_ store: DetectionStore, file: StaticString = #filePath, line: UInt = #line) throws {
    let trip = try store.beginTrip(startedAt: StoreFixtures.date(0))
    XCTAssertEqual(try store.routeThinCount(tripID: trip), 0, "no route", file: file, line: line)
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(15), tripID: trip, maxPoints: 10).thinCount, 1,
                   file: file, line: line)
    XCTAssertEqual(try store.routeThinCount(tripID: trip), 1, file: file, line: line)
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(5, from: 150).map {
      RoutePoint(latitude: $0.latitude + 0.0135, longitude: $0.longitude, accuracy: $0.accuracy, timestamp: $0.timestamp)
    }, tripID: trip, maxPoints: 10).thinCount, 1, file: file, line: line)
    XCTAssertEqual(try store.routeThinCount(tripID: trip), 2, file: file, line: line)

    let far = try store.beginTrip(startedAt: StoreFixtures.date(1000))
    XCTAssertEqual(try store.appendRoutePoints(RouteFixtures.straightRoute(25, from: 1000), tripID: far, maxPoints: 10).thinCount, 2,
                   "25 → 13 → 7", file: file, line: line)
    XCTAssertEqual(try store.routeThinCount(tripID: far), 2, file: file, line: line)
    XCTAssertEqual(try store.routeThinCount(tripID: 999_999), 0, "unknown trip", file: file, line: line)
  }

  static func runAll(_ make: () throws -> DetectionStore) throws {
    try boundary(make())
    try openAndAbandonedTrips(make())
    try nothingExpiredIsANoOp(make())
    try thinningKeepsDistance(make())
    try thinCountIsStored(make())
  }
}

final class InMemoryRouteRetentionTests: XCTestCase {
  func testSameRetentionRulesAsSQLiteStore() throws {
    try RouteRetentionScenarios.runAll { InMemoryDetectionStore() }
  }
}

final class GRDBRouteRetentionTests: TemporaryDirectoryTestCase {
  private func fresh() -> DetectionStore {
    let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return GRDBDetectionStore(directoryProvider: { dir })
  }

  private var databasePath: String { directory.appendingPathComponent(GRDBDetectionStore.fileName).path }

  private static func bytes(of value: Double) -> Data {
    var bits = value.bitPattern.bigEndian // SQLite stores REAL big-endian
    return Data(bytes: &bits, count: 8)
  }

  private func fileContents() throws -> (main: Data, wal: Data) {
    let main = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let walURL = URL(fileURLWithPath: databasePath + "-wal")
    let wal = FileManager.default.fileExists(atPath: walURL.path) ? try Data(contentsOf: walURL) : Data()
    return (main, wal)
  }

  func testBoundary() throws { try RouteRetentionScenarios.boundary(fresh()) }
  func testOpenAndAbandonedTrips() throws { try RouteRetentionScenarios.openAndAbandonedTrips(fresh()) }
  func testNothingExpiredIsANoOp() throws { try RouteRetentionScenarios.nothingExpiredIsANoOp(fresh()) }
  func testThinningKeepsDistance() throws { try RouteRetentionScenarios.thinningKeepsDistance(fresh()) }
  func testThinCountIsStored() throws { try RouteRetentionScenarios.thinCountIsStored(fresh()) }

  /// Purged route coordinates are in neither the database file nor the WAL; the kept trip's
  /// coordinates still are (the search method finds what is there).
  func testPurgedCoordinatesDoNotRemainOnDisk() throws {
    let store = makeStore()
    func route(lat: Double, lon: Double, from start: TimeInterval) -> [RoutePoint] {
      (0..<200).map {
        RoutePoint(latitude: lat + Double($0) * 0.0002, longitude: lon - Double($0) * 0.0002,
                   accuracy: 7, timestamp: StoreFixtures.date(start + Double($0) * 5))
      }
    }
    let expiredRoute = route(lat: 41.0412, lon: -39.9312, from: 0)
    let keptRoute = route(lat: 40.9213, lon: -39.9417, from: 20_000)

    let expired = try store.beginTrip(startedAt: StoreFixtures.date(0))
    for batch in stride(from: 0, to: expiredRoute.count, by: 20) {
      try store.appendRoutePoints(Array(expiredRoute[batch..<batch + 20]), tripID: expired, maxPoints: 5000)
    }
    try store.endTrip(tripID: expired, status: .confirmed, endedAt: StoreFixtures.date(1_000))
    let kept = try store.beginTrip(startedAt: StoreFixtures.date(20_000))
    for batch in stride(from: 0, to: keptRoute.count, by: 20) {
      try store.appendRoutePoints(Array(keptRoute[batch..<batch + 20]), tripID: kept, maxPoints: 5000)
    }
    try store.endTrip(tripID: kept, status: .confirmed, endedAt: StoreFixtures.date(21_000))

    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: RouteRetentionScenarios.cutoff), 200)

    let (main, wal) = try fileContents()
    XCTAssertEqual(wal.count, 0, "WAL truncated after the purge")
    for point in expiredRoute {
      for value in [point.latitude, point.longitude] {
        XCTAssertNil(main.range(of: Self.bytes(of: value)), "purged route coordinate left in the database file")
        XCTAssertNil(wal.range(of: Self.bytes(of: value)), "purged route coordinate left in the WAL")
      }
    }
    let onDisk = main + wal
    XCTAssertNotNil(onDisk.range(of: Self.bytes(of: keptRoute[0].latitude)), "kept route is still stored")
    XCTAssertEqual(try store.tripRoute(tripID: kept), keptRoute)
    XCTAssertGreaterThan(try XCTUnwrap(try store.trips(limit: 10).first { $0.id == expired }?.distanceMeters), 0)
  }

  /// Nothing expired: no write at all (the WAL is not touched).
  func testNoOpPurgeDoesNotWrite() throws {
    let store = makeStore()
    try RouteRetentionScenarios.closedTrip(store, endingAt: 20_000)
    let before = try fileContents()
    let changesBefore = try store.read { $0.totalChangesCount }
    XCTAssertEqual(try store.purgeExpiredRoutes(olderThan: RouteRetentionScenarios.cutoff), 0)
    XCTAssertEqual(try store.read { $0.totalChangesCount }, changesBefore)
    XCTAssertEqual(try fileContents().wal, before.wal)
  }

  /// Relaunch in the middle of a thinned trip: a new store instance reports the same thin
  /// count, so the restored sampler continues at the thinned density.
  func testThinCountSurvivesRelaunch() throws {
    var store: GRDBDetectionStore? = makeStore()
    let trip = try store!.beginTrip(startedAt: StoreFixtures.date(0))
    XCTAssertEqual(try store!.appendRoutePoints(RouteFixtures.straightRoute(25), tripID: trip, maxPoints: 10).thinCount, 2)
    store = nil

    let relaunched = makeStore()
    var sampler = RouteSampler()
    let thinCount = try relaunched.routeThinCount(tripID: trip)
    sampler.begin(tripID: trip, thinCount: thinCount)
    XCTAssertEqual(sampler.spacingScale, 4)
  }
}
