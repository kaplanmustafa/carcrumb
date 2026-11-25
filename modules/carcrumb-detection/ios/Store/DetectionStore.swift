import Foundation
#if CARCRUMB_SPM
import CarCrumbDetection
#endif

/// Persistence boundary for trips and parking. Swift is the only writer (docs/DECISIONS.md).
///
/// Threading: every method is called synchronously on the engine's serial queue
/// (`DetectionEngine.queue`), never concurrently; JS reads are routed through that queue too.
/// Implementations must be fast and must not call back into the engine synchronously.
///
/// Implementations: `GRDBDetectionStore` (SQLite, WAL; the app) and `InMemoryDetectionStore`
/// (tests). Parking rules: `ParkingPolicy`.
///
/// Store code is Foundation (+ GRDB) only, no CoreLocation, so it is tested with `swift test`.
public protocol DetectionStore: AnyObject {
  /// Opens a trip. `startedAt` is the reducer's start; `refineTripStart` may move it earlier.
  /// Returns the trip id. Ids are persistent and never reused (also not after
  /// `deleteAllHistory`), so a `tripID` kept in `state.json` across a relaunch always refers
  /// to the same row or to no row.
  func beginTrip(startedAt: Date) throws -> Int64
  /// Corrects the start from Core Motion history (DriveStartEstimator). Only moves it earlier.
  /// Ignored if the trip is gone.
  func refineTripStart(tripID: Int64, startedAt: Date) throws
  func endTrip(tripID: Int64?, status: TripStatus, endedAt: Date) throws
  /// Writes a whole, already closed trip in one go. Used when `beginTrip` could not write
  /// (database unavailable before the first unlock), so the trip is not lost.
  /// Returns the trip id to pass to `saveParking` for this trip's park. While the database is
  /// still unavailable the trip is buffered and a **provisional negative id** is returned
  /// (valid only for this store instance); a park buffered with it is linked to the real row
  /// when the buffer is replayed. Never throws `.unavailable`.
  func saveClosedTrip(startedAt: Date, detectedAt: Date, endedAt: Date, status: TripStatus) throws -> Int64
  /// Applies `ParkingPolicy`. A rejected park is not an error; see the outcome.
  @discardableResult
  func saveParking(_ point: ParkPoint, tripID: Int64?) throws -> ParkingWriteOutcome
  /// Launch housekeeping: trips still open (no status) other than `tripID` were orphaned by a
  /// process death between `beginTrip` and the state save, or by a dropped buffered `endTrip`.
  /// They are closed as `uncertain` (out of statistics, like any trip we cannot vouch for),
  /// ending at their start. A park attached to such a trip is kept but detached
  /// (`tripId = NULL`): an uncertain trip has no park (rule 1).
  func abandonOpenTrips(except tripID: Int64?) throws

  // MARK: Reads (JS bridge)

  /// The current park ("Arabam nerede"): the newest written row (see `ParkingPolicy`).
  func lastParking() throws -> StoredParking?
  /// Up to `ParkingPolicy.keepCount` parks, current first.
  func recentParkings() throws -> [StoredParking]
  /// Newest first by write order (row id), not by `startedAt`: the device clock can jump,
  /// write order cannot (same reasoning as `ParkingPolicy`).
  func trips(limit: Int) throws -> [StoredTrip]

  /// History deletion, store part (docs/DECISIONS.md, "Geçmişi silme kontrol listesi"):
  /// all rows, then `VACUUM`, then WAL checkpoint(TRUNCATE). Also drops writes buffered while
  /// the database was unavailable.
  func deleteAllHistory() throws
}

public enum StoredTripStatus: String, Codable, Sendable, CaseIterable {
  case confirmed
  case uncertain
  /// Reconstructed from Core Motion history at launch (no route). Not written yet: the
  /// recovery flow (docs/DECISIONS.md, "Kurtarma") comes in a later step.
  case recovered

  public init(_ status: TripStatus) {
    switch status {
    case .confirmed: self = .confirmed
    case .uncertain: self = .uncertain
    }
  }
}

public struct StoredTrip: Equatable, Codable, Sendable {
  public var id: Int64
  /// Real start (refined from Core Motion history when possible).
  public var startedAt: Date
  /// When detection opened the trip (the reducer's start); `startedAt <= detectedAt`.
  public var detectedAt: Date
  /// nil while the trip is open.
  public var endedAt: Date?
  /// nil while the trip is open.
  public var status: StoredTripStatus?
  /// Driven distance in metres. nil until route recording exists (later step).
  public var distanceMeters: Double?

  public init(
    id: Int64, startedAt: Date, detectedAt: Date, endedAt: Date? = nil,
    status: StoredTripStatus? = nil, distanceMeters: Double? = nil
  ) {
    self.id = id
    self.startedAt = startedAt
    self.detectedAt = detectedAt
    self.endedAt = endedAt
    self.status = status
    self.distanceMeters = distanceMeters
  }
}

/// A stored park point. Contains raw coordinates: never log it; it may go to JS only for display.
public struct StoredParking: Equatable, Codable, Sendable {
  public var id: Int64
  public var tripID: Int64?
  public var latitude: Double
  public var longitude: Double
  /// Horizontal accuracy (m) of the chosen fix.
  public var accuracy: Double
  public var confidence: Confidence
  /// When the car was parked (the automotive → walking transition).
  public var parkedAt: Date
  /// Timestamp of the chosen fix (can be slightly before `parkedAt`).
  public var fixAt: Date

  // Column names (SQL) differ only for the trip reference.
  enum CodingKeys: String, CodingKey {
    case id, tripID = "tripId", latitude, longitude, accuracy, confidence, parkedAt, fixAt
  }

  public init(id: Int64, tripID: Int64?, point: ParkPoint) {
    self.id = id
    self.tripID = tripID
    self.latitude = point.location.latitude
    self.longitude = point.location.longitude
    self.accuracy = point.location.accuracy
    self.confidence = point.confidence
    self.parkedAt = point.parkedAt
    self.fixAt = point.location.timestamp
  }
}

public enum ParkingWriteOutcome: String, Equatable, Sendable {
  case inserted
  /// Replaced the park of the same trip (equal or lower confidence before).
  case replaced
  /// Not written: the trip is `uncertain` (no car link). docs/DECISIONS.md "Hata dengesi".
  case rejectedUncertainTrip
  /// Not written: it would have displaced a high-confidence park of the same trip, or (no
  /// trip) the latest high-confidence park it is not newer than. See `ParkingPolicy`.
  case keptHigherConfidence
  /// Written but removed by the "keep last 3" pruning in the same transaction, so it is not
  /// stored. Should not happen with write-order pruning (a new row is always the newest);
  /// checked after pruning so the outcome always matches the stored data (Karar D: the
  /// engine moves the geofence only for a stored park).
  case notKept

  /// True only if the park is in the store after the call.
  public var wasWritten: Bool { self == .inserted || self == .replaced }
}

public enum StoreError: Error, Equatable {
  /// The database cannot be opened right now, typically before the first unlock after a
  /// reboot (file protection). The store retries at the next call; writes that do not need
  /// a result are buffered in memory meanwhile.
  case unavailable
}

// MARK: - In-memory store (tests)

/// Same rules as the SQLite store (`ParkingPolicy`), memory only. For tests / previews.
public final class InMemoryDetectionStore: DetectionStore {
  public private(set) var tripRows: [StoredTrip] = []
  /// Unordered; read through `recentParkings()`.
  public private(set) var parkingRows: [StoredParking] = []
  private var nextTripID: Int64 = 1
  private var nextParkingID: Int64 = 1

  public init() {}

  public func beginTrip(startedAt: Date) throws -> Int64 {
    let id = nextTripID
    nextTripID += 1
    tripRows.append(StoredTrip(id: id, startedAt: startedAt, detectedAt: startedAt))
    return id
  }

  public func refineTripStart(tripID: Int64, startedAt: Date) throws {
    guard let i = tripRows.firstIndex(where: { $0.id == tripID }), startedAt < tripRows[i].startedAt else { return }
    tripRows[i].startedAt = startedAt
  }

  public func endTrip(tripID: Int64?, status: TripStatus, endedAt: Date) throws {
    guard let tripID, let i = tripRows.firstIndex(where: { $0.id == tripID }) else { return }
    tripRows[i].endedAt = endedAt
    tripRows[i].status = StoredTripStatus(status)
  }

  public func saveClosedTrip(startedAt: Date, detectedAt: Date, endedAt: Date, status: TripStatus) throws -> Int64 {
    let id = nextTripID
    nextTripID += 1
    tripRows.append(StoredTrip(
      id: id, startedAt: startedAt, detectedAt: detectedAt, endedAt: endedAt, status: StoredTripStatus(status)))
    return id
  }

  @discardableResult
  public func saveParking(_ point: ParkPoint, tripID: Int64?) throws -> ParkingWriteOutcome {
    // An unknown trip id is stored as "no trip" (same as the SQLite foreign key handling).
    let trip = tripID.flatMap { id in tripRows.first { $0.id == id } }
    let tripID = trip?.id
    let sameTrip = tripID.flatMap { id in parkingRows.first { $0.tripID == id } }
    let latestHigh = parkingRows.filter { $0.confidence == .high }.max { $0.id < $1.id }
    let outcome: ParkingWriteOutcome
    switch ParkingPolicy.decide(point, tripID: tripID, tripStatus: trip?.status, sameTrip: sameTrip, latestHigh: latestHigh) {
    case let .reject(rejection):
      return rejection
    case let .replace(existingID):
      // Re-inserted: the replacement is the newest write.
      parkingRows.removeAll { $0.id == existingID }
      outcome = .replaced
    case .insert:
      outcome = .inserted
    }
    let newID = nextParkingID
    nextParkingID += 1
    parkingRows.append(StoredParking(id: newID, tripID: tripID, point: point))
    prune()
    return parkingRows.contains { $0.id == newID } ? outcome : .notKept
  }

  public func abandonOpenTrips(except tripID: Int64?) throws {
    for i in tripRows.indices where tripRows[i].status == nil && tripRows[i].id != tripID {
      tripRows[i].status = .uncertain
      tripRows[i].endedAt = tripRows[i].startedAt
      let abandoned = tripRows[i].id
      for p in parkingRows.indices where parkingRows[p].tripID == abandoned {
        parkingRows[p].tripID = nil
      }
    }
  }

  public func lastParking() throws -> StoredParking? {
    try recentParkings().first
  }

  public func recentParkings() throws -> [StoredParking] {
    parkingRows.sorted { ParkingPolicy.isNewer($0, than: $1) }
  }

  public func trips(limit: Int) throws -> [StoredTrip] {
    Array(tripRows.sorted { $0.id > $1.id }.prefix(max(0, limit)))
  }

  public func deleteAllHistory() throws {
    tripRows.removeAll()
    parkingRows.removeAll()
    // Ids keep increasing (same as SQLite AUTOINCREMENT).
  }

  private func prune() {
    parkingRows = Array(parkingRows.sorted { ParkingPolicy.isNewer($0, than: $1) }.prefix(ParkingPolicy.keepCount))
  }
}
