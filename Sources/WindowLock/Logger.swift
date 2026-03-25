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

  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
  }()

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

  private static func log(_ level: LogLevel, _ message: String) {
    let timestamp = formatter.string(from: Date())
    let line = "[\(timestamp)] [\(level.rawValue)] \(message)"
    fputs("\(line)\n", stderr)

    recentEntries.append(line)
    if recentEntries.count > maxEntries {
      recentEntries.removeFirst(recentEntries.count - maxEntries)
    }
  }
}
