import Foundation

/// File helpers for data the engine writes while the phone may be locked.
///
/// Protection is `completeUntilFirstUserAuthentication` (docs/DECISIONS.md, "Dosya koruması"):
/// readable/writable in the background after the first unlock since boot. `.complete` would
/// make writes fail when a background wake happens with the screen locked.
///
/// Lives in Store/ (Foundation only) because both the SQLite store and the engine's
/// `StateFile` / `TraceRecorder` use it.
enum ProtectedFiles {
  static let protection = FileProtectionType.completeUntilFirstUserAuthentication

  /// Application Support/<relativePath>, created with the right protection and excluded
  /// from iCloud/iTunes backup (detection state, history and traces are device-local by design).
  /// New files created inside inherit the directory's protection class.
  static func directory(_ relativePath: String) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var dir = base.appendingPathComponent(relativePath, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.protectionKey: protection])
    }
    try excludeFromBackup(&dir)
    return dir
  }

  static func excludeFromBackup(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  /// Sets the protection class explicitly on an existing file (no-op if it does not exist).
  /// Only meaningful on iOS; macOS (`swift test`) has no per-file data protection classes.
  static func protectExistingFile(at url: URL) throws {
    #if os(iOS)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    #endif
  }

  /// Atomic replace. `.atomic` writes a temp file and renames; the protection option
  /// applies to the final file.
  static func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var u = url
    try excludeFromBackup(&u)
  }
}
