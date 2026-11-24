import Foundation

/// Debug sensor recording: every reducer input (event + the `now` used) as JSON Lines in
/// `Application Support/traces/trace-YYYY-MM-DD.jsonl` (one file per local day, appended
/// across launches so a relaunch mid-drive stays in the same file).
///
/// DEBUG builds only. In release builds this type compiles to a no-op and `listTraces()`
/// returns nothing, so no raw coordinates are ever written to disk by the recorder.
///
/// Privacy: traces contain raw coordinates. They are never logged, never sent over the
/// network, excluded from backup, protected with `completeUntilFirstUserAuthentication`.
/// Getting them off the phone is a manual developer action (Files / share sheet in a later step).
///
/// Threading: `record` is called only on the engine queue. `listTraces` / `path` only touch
/// the file system read-only and may be called from any thread.
final class TraceRecorder {
  static let directoryName = "traces"

  #if DEBUG
  private let encoder = TraceFormat.makeEncoder()
  private var handle: FileHandle?
  private var currentDay: String?
  private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()
  #endif

  var isEnabled: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }

  func record(_ event: DetectionEvent, at now: Date) {
    #if DEBUG
    do {
      let line = try TraceFormat.encodeLine(TraceRecord(time: now, event: event), encoder: encoder)
      try fileHandle(for: now)?.write(contentsOf: line)
    } catch {
      // Drop the line; never let debug recording affect detection. Close so the next call reopens.
      try? handle?.close()
      handle = nil
      currentDay = nil
    }
    #endif
  }

  func close() {
    #if DEBUG
    try? handle?.close()
    handle = nil
    currentDay = nil
    #endif
  }

  #if DEBUG
  private func fileHandle(for now: Date) throws -> FileHandle? {
    let day = dayFormatter.string(from: now)
    if day == currentDay, let handle { return handle }
    try? handle?.close()
    handle = nil

    let dir = try ProtectedFiles.directory(Self.directoryName)
    var url = dir.appendingPathComponent("trace-\(day).jsonl")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(
        atPath: url.path, contents: nil,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      try ProtectedFiles.excludeFromBackup(&url)
    }
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    handle = h
    currentDay = day
    return h
  }
  #endif

  // MARK: Bridge helpers

  /// File names (newest first). Empty in release builds.
  static func listTraces() -> [String] {
    #if DEBUG
    guard let dir = try? ProtectedFiles.directory(directoryName),
          let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return [] }
    return names.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)
    #else
    return []
    #endif
  }

  /// Absolute path of a trace file, or nil (always nil in release). Rejects anything that
  /// is not a plain file name from `listTraces()` (no path traversal).
  static func path(of name: String) -> String? {
    #if DEBUG
    guard listTraces().contains(name),
          let dir = try? ProtectedFiles.directory(directoryName)
    else { return nil }
    return dir.appendingPathComponent(name).path
    #else
    return nil
    #endif
  }
}
