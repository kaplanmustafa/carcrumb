import Foundation

// Debug sensor trace format (JSON Lines), shared by the on-device recorder
// (Engine/TraceRecorder.swift, DEBUG builds only) and the pure `TraceReplayer`.
//
// One record per line, UTF-8, dates as seconds since 1970 (Double):
//
//   {"event":{"type":"wake","source":"visit"},"t":1800000000}
//   {"event":{"activity":"walking","startedAt":1800000590,"type":"motion"},"t":1800000605}
//   {"event":{"sample":{"accuracy":5,"latitude":41,"longitude":29,"speed":0,"timestamp":1800000600},"type":"location"},"t":1800000600}
//   {"event":{"connected":true,"type":"carLink"},"t":1800000001}
//   {"event":{"type":"tick"},"t":1800000140}
//   {"restore":{"savedAt":1800000300,"state":{…},"version":1},"t":1800000590}
//
// `t` is the `now` the engine passed to the reducer (or to `StateRestorePolicy`), so replay
// is exact.
//
// Optional keys (older traces without them still decode):
// - motion `startedAt`: `CMMotionActivity.startDate`, the real start of the activity.
// - `restore` records: the persisted state the engine restored at launch (process relaunch).
//   Replay runs it through `StateRestorePolicy` exactly like the engine does.
//
// Blank lines are ignored. Traces contain raw coordinates: they stay on the device
// (Application Support/traces, excluded from backup) and are never logged or uploaded.

/// One recorded input: a reducer event or a state restore at launch.
public struct TraceRecord: Equatable, Codable, Sendable {
  public enum Payload: Equatable, Sendable {
    case event(DetectionEvent)
    case restore(PersistedDetectionState)
  }

  public var time: Date
  public var payload: Payload

  public init(time: Date, event: DetectionEvent) {
    self.time = time
    self.payload = .event(event)
  }

  public init(time: Date, restore persisted: PersistedDetectionState) {
    self.time = time
    self.payload = .restore(persisted)
  }

  /// The reducer event; nil for restore records.
  public var event: DetectionEvent? {
    if case let .event(e) = payload { return e }
    return nil
  }

  /// Safe to log (no payload).
  public var typeName: String {
    switch payload {
    case let .event(e): return e.typeName
    case .restore: return "restore"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case time = "t"
    case event
    case restore
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    time = try c.decode(Date.self, forKey: .time)
    if let event = try c.decodeIfPresent(DetectionEvent.self, forKey: .event) {
      payload = .event(event)
    } else if let persisted = try c.decodeIfPresent(PersistedDetectionState.self, forKey: .restore) {
      payload = .restore(persisted)
    } else {
      throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "record has neither event nor restore")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(time, forKey: .time)
    switch payload {
    case let .event(e): try c.encode(e, forKey: .event)
    case let .restore(p): try c.encode(p, forKey: .restore)
    }
  }
}

public enum TraceFormatError: Error, Equatable {
  /// 1-based line number and a short reason (no payload, it may contain coordinates).
  case invalidLine(Int, String)
}

public enum TraceFormat {
  public static func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    e.outputFormatting = [.sortedKeys] // single line, stable key order
    return e
  }

  public static func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }

  /// One JSON line including the trailing newline.
  public static func encodeLine(_ record: TraceRecord, encoder: JSONEncoder = makeEncoder()) throws -> Data {
    var data = try encoder.encode(record)
    data.append(0x0A)
    return data
  }

  public static func decodeLines(_ data: Data) throws -> [TraceRecord] {
    let decoder = makeDecoder()
    var records: [TraceRecord] = []
    var lineNumber = 0
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
      lineNumber += 1
      var bytes = Data(line)
      if bytes.last == 0x0D { bytes.removeLast() } // tolerate CRLF (fixtures edited on Windows)
      if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
      do {
        records.append(try decoder.decode(TraceRecord.self, from: bytes))
      } catch {
        throw TraceFormatError.invalidLine(lineNumber, "not a valid trace record")
      }
    }
    return records
  }
}

// MARK: - DetectionEvent wire format

extension DetectionEvent: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, source, activity, startedAt, sample, connected
  }

  /// Stable event type name; also safe to log (no payload).
  public var typeName: String {
    switch self {
    case .wake: return "wake"
    case .motion: return "motion"
    case .location: return "location"
    case .carLink: return "carLink"
    case .tick: return "tick"
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "wake": self = .wake(try c.decode(WakeSource.self, forKey: .source))
    case "motion":
      self = .motion(try c.decode(MotionActivity.self, forKey: .activity),
                     startedAt: try c.decodeIfPresent(Date.self, forKey: .startedAt))
    case "location": self = .location(try c.decode(LocationSample.self, forKey: .sample))
    case "carLink": self = .carLink(connected: try c.decode(Bool.self, forKey: .connected))
    case "tick": self = .tick
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(typeName, forKey: .type)
    switch self {
    case let .wake(source): try c.encode(source, forKey: .source)
    case let .motion(activity, startedAt):
      try c.encode(activity, forKey: .activity)
      try c.encodeIfPresent(startedAt, forKey: .startedAt)
    case let .location(sample): try c.encode(sample, forKey: .sample)
    case let .carLink(connected): try c.encode(connected, forKey: .connected)
    case .tick: break
    }
  }
}

// MARK: - Replay

/// Pure replay of a recorded trace through the reducer (and `StateRestorePolicy` for restore
/// records). No I/O besides the `Data` you pass in.
public struct TraceReplayer: Sendable {
  public struct Transition: Equatable, Sendable {
    public var at: Date
    public var from: String
    public var to: String
    public var eventType: String
  }

  public struct Result: Equatable, Sendable {
    public var finalState: DetectionState
    public var effects: [Effect]
    /// State-name changes in order; handy for asserting a scenario's path.
    public var transitions: [Transition]
  }

  public var reducer: DetectionReducer

  public init(reducer: DetectionReducer = DetectionReducer()) {
    self.reducer = reducer
  }

  public func replay(_ records: [TraceRecord], from start: DetectionState = .idle) -> Result {
    var state = start
    var effects: [Effect] = []
    var transitions: [Transition] = []
    for record in records {
      let result: (DetectionState, [Effect])
      switch record.payload {
      case let .event(event):
        result = reducer.reduce(state, event, now: record.time)
      case let .restore(persisted):
        result = StateRestorePolicy.restore(persisted, now: record.time, reducer: reducer)
      }
      if result.0.name != state.name {
        transitions.append(Transition(at: record.time, from: state.name, to: result.0.name, eventType: record.typeName))
      }
      state = result.0
      effects += result.1
    }
    return Result(finalState: state, effects: effects, transitions: transitions)
  }

  public func replay(jsonLines data: Data, from start: DetectionState = .idle) throws -> Result {
    replay(try TraceFormat.decodeLines(data), from: start)
  }
}
