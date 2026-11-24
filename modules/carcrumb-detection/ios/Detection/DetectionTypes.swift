import Foundation

// Pure value types for the detection state machine.
// No CoreLocation / CoreMotion imports here on purpose: the reducer must stay
// deterministic and replayable from recorded sensor traces (fixtures/traces).

/// A location sample. Raw coordinates must never be logged or sent over the network.
public struct LocationSample: Equatable, Codable, Sendable {
  public var latitude: Double
  public var longitude: Double
  /// Horizontal accuracy in metres (lower is better). Negative = invalid.
  public var accuracy: Double
  /// Speed in m/s. Negative = unknown.
  public var speed: Double
  public var timestamp: Date

  public init(latitude: Double, longitude: Double, accuracy: Double, speed: Double, timestamp: Date) {
    self.latitude = latitude
    self.longitude = longitude
    self.accuracy = accuracy
    self.speed = speed
    self.timestamp = timestamp
  }

  /// Great-circle distance in metres (haversine). Good enough for tens of metres.
  public func distance(to other: LocationSample) -> Double {
    let r = 6_371_000.0
    let dLat = (other.latitude - latitude) * .pi / 180
    let dLon = (other.longitude - longitude) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
      + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * atan2(sqrt(a), sqrt(1 - a))
  }
}

public enum MotionActivity: String, Codable, Sendable {
  case automotive, walking, running, cycling, stationary, unknown
}

public enum WakeSource: String, Codable, Sendable {
  case significantLocationChange, visit, geofenceExit, appLaunch
}

public enum Confidence: String, Codable, Sendable {
  case low, high
}

public enum TripStatus: String, Codable, Sendable {
  /// Confirmed with a car signal (CarPlay / `.carAudio` / known car Bluetooth port).
  case confirmed
  /// No car link during the trip (bus, taxi, someone else's car). Writes no parking.
  case uncertain
}

/// Tunables. Defaults are provisional; field data decides the final values (DECISIONS.md, open questions).
public struct DetectionConfig: Equatable, Sendable {
  /// Speed that confirms driving (m/s). ~18 km/h.
  public var drivingSpeed: Double = 5.0
  /// How long MAYBE_DRIVING may wait for confirmation before falling back to IDLE.
  public var maybeDrivingTimeout: TimeInterval = 5 * 60
  /// Walking distance from the stop point that confirms parking (30–50 m band).
  public var parkConfirmDistance: Double = 40
  /// Ring buffer length used to pick the park point.
  public var bufferWindow: TimeInterval = 60
  /// Geofence radius around the park point; next trip's wake-up trigger.
  public var geofenceRadius: Double = 150
  /// Accuracy (m) at or below which a park point can be high confidence.
  public var goodAccuracy: Double = 20

  public init() {}
}

public struct Trip: Equatable, Sendable {
  public var startedAt: Date
  public var hadCarLink: Bool
  /// Last `bufferWindow` seconds of location samples, oldest first.
  public var buffer: [LocationSample]

  public init(startedAt: Date, hadCarLink: Bool, buffer: [LocationSample] = []) {
    self.startedAt = startedAt
    self.hadCarLink = hadCarLink
    self.buffer = buffer
  }
}

public struct ParkPoint: Equatable, Sendable {
  public var location: LocationSample
  public var confidence: Confidence
  public var parkedAt: Date
}

public enum DetectionState: Equatable, Sendable {
  case idle
  case maybeDriving(since: Date, carLink: Bool)
  case driving(Trip)
  /// Walking started; `candidate` is the buffered location at the automotive → walking transition.
  case maybeParked(trip: Trip, candidate: LocationSample, walkingSince: Date)
  case parked(ParkPoint)

  public var name: String {
    switch self {
    case .idle: return "IDLE"
    case .maybeDriving: return "MAYBE_DRIVING"
    case .driving: return "DRIVING"
    case .maybeParked: return "MAYBE_PARKED"
    case .parked: return "PARKED"
    }
  }
}

public enum DetectionEvent: Equatable, Sendable {
  case wake(WakeSource)
  case motion(MotionActivity)
  case location(LocationSample)
  case carLink(connected: Bool)
  /// Periodic tick so time-based transitions happen without new sensor data.
  case tick
}

public enum Effect: Equatable, Sendable {
  case startGPS
  case stopGPS
  case beginTrip(startedAt: Date)
  case endTrip(status: TripStatus, endedAt: Date)
  /// Storage must not overwrite a high-confidence park with a low one and keeps the last 3.
  case saveParking(ParkPoint)
  case setGeofence(center: LocationSample, radius: Double)
  case clearGeofence
}
