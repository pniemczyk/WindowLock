import Foundation

enum StateStore {
  private static let dirPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/WindowLock"
  }()

  private static let filePath = "\(dirPath)/window-state.json"

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  static func save(_ snapshot: WindowSnapshot) {
    do {
      try FileManager.default.createDirectory(
        atPath: dirPath,
        withIntermediateDirectories: true
      )

      let data = try encoder.encode(snapshot)
      let tempPath = filePath + ".tmp"
      try data.write(to: URL(fileURLWithPath: tempPath))
      try FileManager.default.moveItem(atPath: tempPath, toPath: filePath)
      Log.info("State saved (\(snapshot.windows.count) windows)")
    } catch {
      // moveItem fails if destination exists; remove first then retry
      if (error as NSError).domain == NSCocoaErrorDomain {
        do {
          try FileManager.default.removeItem(atPath: filePath)
          let data = try encoder.encode(snapshot)
          let tempPath = filePath + ".tmp"
          try data.write(to: URL(fileURLWithPath: tempPath))
          try FileManager.default.moveItem(atPath: tempPath, toPath: filePath)
          Log.info("State saved on retry (\(snapshot.windows.count) windows)")
        } catch {
          Log.error("Failed to save state: \(error)")
        }
      } else {
        Log.error("Failed to save state: \(error)")
      }
    }
  }

  static func load() -> WindowSnapshot? {
    guard FileManager.default.fileExists(atPath: filePath) else {
      Log.info("No saved state found")
      return nil
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
      let snapshot = try decoder.decode(WindowSnapshot.self, from: data)
      Log.info("Loaded state from \(snapshot.capturedAt) (\(snapshot.windows.count) windows)")
      return snapshot
    } catch {
      Log.error("Failed to load state: \(error)")
      return nil
    }
  }
}
