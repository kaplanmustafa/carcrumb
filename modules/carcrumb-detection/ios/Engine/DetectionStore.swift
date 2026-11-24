import Foundation

/// Persistence boundary for trips and parking. Swift is the only writer (docs/DECISIONS.md).
///
/// Threading: every method is called synchronously on the engine's serial queue
/// (`DetectionEngine.queue`), never concurrently. Implementations must be fast and must not
/// call back into the engine synchronously.
///
/// The GRDB (SQLite, WAL) implementation comes in a later step and will implement this
/// protocol. Its rules (enforced there, not here):
/// - a low-confidence park must not overwrite a high-confidence one,
/// - keep the last 3 park points,
/// - `uncertain` trips stay out of statistics until confirmed.
public protocol DetectionStore: AnyObject {
  /// Opens a trip. `startedAt` is the reducer's start; `refineTripStart` may move it earlier.
  /// Returns an opaque trip id.
  func beginTrip(startedAt: Date) throws -> Int64
  /// Corrects the start from Core Motion history (DriveStartEstimator). Ignored if the trip is gone.
  func refineTripStart(tripID: Int64, startedAt: Date) throws
  func endTrip(tripID: Int64?, status: TripStatus, endedAt: Date) throws
  func saveParking(_ point: ParkPoint, tripID: Int64?) throws
}

/// Placeholder until the GRDB store lands. Keeps data in memory only (lost on termination).
public final class InMemoryDetectionStore: DetectionStore {
  public struct TripRow: Equatable {
    public var id: Int64
    public var startedAt: Date
    public var endedAt: Date?
    public var status: TripStatus?
  }

  public private(set) var trips: [TripRow] = []
  /// Newest last; mirrors the "keep last 3" rule so the bridge can be exercised before GRDB.
  public private(set) var parkings: [ParkPoint] = []
  private var nextID: Int64 = 1

  public init() {}

  public func beginTrip(startedAt: Date) throws -> Int64 {
    let id = nextID
    nextID += 1
    trips.append(TripRow(id: id, startedAt: startedAt, endedAt: nil, status: nil))
    return id
  }

  public func refineTripStart(tripID: Int64, startedAt: Date) throws {
    guard let i = trips.firstIndex(where: { $0.id == tripID }) else { return }
    trips[i].startedAt = startedAt
  }

  public func endTrip(tripID: Int64?, status: TripStatus, endedAt: Date) throws {
    guard let tripID, let i = trips.firstIndex(where: { $0.id == tripID }) else { return }
    trips[i].endedAt = endedAt
    trips[i].status = status
  }

  public func saveParking(_ point: ParkPoint, tripID: Int64?) throws {
    parkings.append(point)
    if parkings.count > 3 { parkings.removeFirst(parkings.count - 3) }
  }
}
