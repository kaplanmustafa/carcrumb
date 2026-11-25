import Foundation

/// Last detection state on disk (`Application Support/CarCrumb/engine/state.json`).
/// Called only on the engine queue. File helpers: `ProtectedFiles` (Store/ProtectedFiles.swift).
final class StateFile {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }()
  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }()

  // Resolved lazily and retried: before the first unlock after a reboot the container is
  // not accessible yet (a background wake can happen then), so resolution may fail once.
  private var resolvedURL: URL?
  private var url: URL? {
    if resolvedURL == nil {
      resolvedURL = (try? ProtectedFiles.directory("CarCrumb/engine"))?.appendingPathComponent("state.json")
    }
    return resolvedURL
  }

  init() {}

  func load() -> PersistedDetectionState? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(PersistedDetectionState.self, from: data)
  }

  func save(_ value: PersistedDetectionState) throws {
    guard let url else { return }
    try ProtectedFiles.writeAtomically(try encoder.encode(value), to: url)
  }

  /// History deletion: removes `state.json` (it can hold the trip ring buffer = coordinates).
  func delete() throws {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
