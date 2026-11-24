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
  /// Walking distance from the stop point that confirms parking (30–50 m band). Compared
  /// against `distance - sample accuracy` (DECISIONS.md, "Park onayı").
  public var parkConfirmDistance: Double = 40
  /// Upper bound of walking speed (m/s) for a sample to count as "walked away". Above it the
  /// phone is probably still in a slowly moving car.
  public var maxWalkingSpeed: Double = 2.5
  /// Ring buffer length used to pick the park point.
  public var bufferWindow: TimeInterval = 60
  /// Geofence radius around the park point; next trip's wake-up trigger.
  public var geofenceRadius: Double = 150
  /// Accuracy (m) at or below which a park point can be high confidence.
  public var goodAccuracy: Double = 20
  /// A park candidate older than this at the walking start means GPS was lost before the car
  /// stopped (indoor car park ramps): the point is kept but confidence is low.
  public var maxCandidateAge: TimeInterval = 30
  /// Karar A: MAYBE_PARKED without confirmation for this long (from the walking start) ends
  /// the trip: low-confidence park with car link, `uncertain` without. If the car link is
  /// still connected at that point, no park: the trip returns to DRIVING.
  public var maybeParkedTimeout: TimeInterval = 10 * 60
  /// Karar B: DRIVING without movement for this long AND without a connected car link ends
  /// the trip at the stop point (phone left in the car).
  public var drivingStationaryTimeout: TimeInterval = 15 * 60
  /// Absolute cap: DRIVING without movement for this long ends the trip even with the car
  /// link still connected (engine idling / CarPlay left on). Same closing as Karar B:
  /// low park at the stop point with car link, `uncertain` without; end = last movement.
  public var drivingHardStationaryTimeout: TimeInterval = 60 * 60
  /// GPS speed (m/s) at or above which a DRIVING sample counts as movement for Karar B.
  public var movingSpeed: Double = 1.0

  public init() {}
}

public struct Trip: Equatable, Sendable {
  public var startedAt: Date
  /// Car link seen at any time during the trip (decides confirmed vs. uncertain).
  public var hadCarLink: Bool
  /// Last `bufferWindow` seconds of location samples, oldest first.
  public var buffer: [LocationSample]
  /// Current car link level (not only "ever seen"). Park confirmation is blocked while it is
  /// connected; its loss is required for the DRIVING stationary timeout.
  public var carLinkConnected: Bool
  /// Last evidence of the car moving (automotive activity or GPS speed >= `movingSpeed`).
  public var lastMovingAt: Date
  /// Latest activity reported by Core Motion during the trip (nil = none yet).
  public var lastActivity: MotionActivity?
  /// Newest good-accuracy sample that already fell out of `buffer`. Lets the park point be
  /// chosen when the walking report arrives late or GPS was lost before the stop.
  public var anchor: LocationSample?

  public init(
    startedAt: Date,
    hadCarLink: Bool,
    buffer: [LocationSample] = [],
    carLinkConnected: Bool? = nil,
    lastMovingAt: Date? = nil,
    lastActivity: MotionActivity? = nil,
    anchor: LocationSample? = nil
  ) {
    self.startedAt = startedAt
    self.hadCarLink = hadCarLink
    self.buffer = buffer
    self.carLinkConnected = carLinkConnected ?? hadCarLink
    self.lastMovingAt = lastMovingAt ?? startedAt
    self.lastActivity = lastActivity
    self.anchor = anchor
  }
}

extension Trip: Codable {
  private enum CodingKeys: String, CodingKey {
    case startedAt, hadCarLink, buffer, carLinkConnected, lastMovingAt, lastActivity, anchor
  }

  /// Fields added after the first version are optional on decode, so a `state.json` written
  /// by an older build still restores.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let startedAt = try c.decode(Date.self, forKey: .startedAt)
    let buffer = try c.decodeIfPresent([LocationSample].self, forKey: .buffer) ?? []
    self.init(
      startedAt: startedAt,
      hadCarLink: try c.decode(Bool.self, forKey: .hadCarLink),
      buffer: buffer,
      carLinkConnected: try c.decodeIfPresent(Bool.self, forKey: .carLinkConnected),
      lastMovingAt: try c.decodeIfPresent(Date.self, forKey: .lastMovingAt) ?? buffer.last?.timestamp,
      lastActivity: try c.decodeIfPresent(MotionActivity.self, forKey: .lastActivity),
      anchor: try c.decodeIfPresent(LocationSample.self, forKey: .anchor))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(hadCarLink, forKey: .hadCarLink)
    try c.encode(buffer, forKey: .buffer)
    try c.encode(carLinkConnected, forKey: .carLinkConnected)
    try c.encode(lastMovingAt, forKey: .lastMovingAt)
    try c.encodeIfPresent(lastActivity, forKey: .lastActivity)
    try c.encodeIfPresent(anchor, forKey: .anchor)
  }
}

public struct ParkPoint: Equatable, Codable, Sendable {
  public var location: LocationSample
  public var confidence: Confidence
  public var parkedAt: Date

  public init(location: LocationSample, confidence: Confidence, parkedAt: Date) {
    self.location = location
    self.confidence = confidence
    self.parkedAt = parkedAt
  }
}

/// Codable (synthesized) so the engine can persist the last state across app termination.
public enum DetectionState: Equatable, Codable, Sendable {
  case idle
  case maybeDriving(since: Date, carLink: Bool)
  case driving(Trip)
  /// Walking started; `candidate` is the buffered location at the automotive → walking
  /// transition; `walkingSince` is the walking start reported by Core Motion (the event time
  /// when the report carries no start date).
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

/// Codable with an explicit, flat wire format because this is the debug trace format
/// (fixtures/traces/*.jsonl, see `TraceFormat`). Renaming keys breaks recorded traces;
/// new sensor fields must be added as optional keys here AND in the trace docs.
public enum DetectionEvent: Equatable, Sendable {
  case wake(WakeSource)
  /// `startedAt` = `CMMotionActivity.startDate`: when the activity really began. Core Motion
  /// often reports walking tens of seconds late. nil in traces recorded before the field existed.
  case motion(MotionActivity, startedAt: Date? = nil)
  case location(LocationSample)
  case carLink(connected: Bool)
  /// Periodic tick so time-based transitions happen without new sensor data.
  case tick
}

public enum Effect: Equatable, Codable, Sendable {
  case startGPS
  case stopGPS
  case beginTrip(startedAt: Date)
  case endTrip(status: TripStatus, endedAt: Date)
  /// Storage must not overwrite a high-confidence park with a low one and keeps the last 3.
  case saveParking(ParkPoint)
  case setGeofence(center: LocationSample, radius: Double)
  /// Never emitted by the reducer (Karar D: the park geofence changes only with a new park).
  /// Kept for the "delete history" flow.
  case clearGeofence
}
