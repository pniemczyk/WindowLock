import Foundation

enum LaunchAtLoginManager {
  private static let plistName = "com.way2do.windowlock"
  private static let plistFileName = "\(plistName).plist"

  private static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(plistFileName)")
  }

  static var isEnabled: Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  static func enable() {
    let binaryPath: String
    if let execURL = Bundle.main.executableURL {
      binaryPath = execURL.path
    } else {
      binaryPath = "/Applications/WindowLock.app/Contents/MacOS/WindowLock"
    }

    let plist: [String: Any] = [
      "Label": plistName,
      "ProgramArguments": [binaryPath],
      "RunAtLoad": true,
      "KeepAlive": false,
      "StandardOutPath": Log.logFileURL.path,
      "StandardErrorPath": Log.logFileURL.path,
    ]

    do {
      let dir = plistURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: plistURL, options: .atomic)

      let load = Process()
      load.launchPath = "/bin/launchctl"
      load.arguments = ["load", plistURL.path]
      try load.run()
      load.waitUntilExit()

      Log.info("Launch at Login enabled (binary: \(binaryPath))")
    } catch {
      Log.error("Failed to enable Launch at Login: \(error)")
    }
  }

  static func disable() {
    let uid = getuid()
    let unload = Process()
    unload.launchPath = "/bin/launchctl"
    unload.arguments = ["bootout", "gui/\(uid)/\(plistName)"]
    try? unload.run()
    unload.waitUntilExit()

    try? FileManager.default.removeItem(at: plistURL)
    Log.info("Launch at Login disabled")
  }
}
