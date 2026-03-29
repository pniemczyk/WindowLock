import Foundation

enum LogLevel: String {
  case info = "INFO"
  case warn = "WARN"
  case error = "ERROR"
}

enum Log {
  static var debugMode: Bool = false

  /// Recent log entries kept for debug alert display
  private(set) static var recentEntries: [String] = []
  private static let maxEntries = 200

  // MARK: - File logging

  static let logDirURL: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Logs/WindowLock", isDirectory: true)
  }()

  static let logFileURL: URL = logDirURL.appendingPathComponent("windowlock.log")

  private static var fileHandle: FileHandle? = {
    let fm = FileManager.default
    try? fm.createDirectory(at: logDirURL, withIntermediateDirectories: true)
    if !fm.fileExists(atPath: logFileURL.path) {
      fm.createFile(atPath: logFileURL.path, contents: nil)
    }
    return try? FileHandle(forWritingTo: logFileURL)
  }()

  static func logFileSize() -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
          let size = attrs[.size] as? Int64 else { return 0 }
    return size
  }

  static func clearLogFile() {
    fileHandle?.truncateFile(atOffset: 0)
    fileHandle?.seek(toFileOffset: 0)
    clearRecent()
  }

  // MARK: - Interface

  static func info(_ message: String) { log(.info, message) }
  static func warn(_ message: String) { log(.warn, message) }
  static func error(_ message: String) { log(.error, message) }

  static func clearRecent() {
    recentEntries.removeAll()
  }

  /// Returns recent entries filtered to warnings and errors only.
  static var recentErrors: [String] {
    recentEntries.filter { $0.contains("[WARN]") || $0.contains("[ERROR]") }
  }

  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

  private static func log(_ level: LogLevel, _ message: String) {
    let timestamp = formatter.string(from: Date())
    let line = "[\(timestamp)] [\(level.rawValue)] \(message)"
    fputs("\(line)\n", stderr)

    if let data = (line + "\n").data(using: .utf8) {
      fileHandle?.seekToEndOfFile()
      fileHandle?.write(data)
      // Flush immediately so logs survive abrupt termination (SIGKILL, crash)
      fileHandle?.synchronizeFile()
    }

    recentEntries.append(line)
    if recentEntries.count > maxEntries {
      recentEntries.removeFirst(recentEntries.count - maxEntries)
    }
  }
}
