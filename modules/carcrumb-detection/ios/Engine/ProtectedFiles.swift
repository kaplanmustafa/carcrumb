import Foundation

/// File helpers for data the engine writes while the phone may be locked.
///
/// Protection is `completeUntilFirstUserAuthentication` (docs/DECISIONS.md, "Dosya koruması"):
/// readable/writable in the background after the first unlock since boot. `.complete` would
/// make writes fail when a background wake happens with the screen locked.
enum ProtectedFiles {
  /// Application Support/<relativePath>, created with the right protection and excluded
  /// from iCloud/iTunes backup (detection state and traces are device-local by design).
  static func directory(_ relativePath: String) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var dir = base.appendingPathComponent(relativePath, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    try excludeFromBackup(&dir)
    return dir
  }

  static func excludeFromBackup(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  /// Atomic replace. `.atomic` writes a temp file and renames; the protection option
  /// applies to the final file.
  static func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var u = url
    try excludeFromBackup(&u)
  }
}

/// Last detection state on disk (`Application Support/CarCrumb/engine/state.json`).
/// Called only on the engine queue.
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
}
