import Foundation

enum ProfileStore {
  private static let profilesDir: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/WindowLock/profiles"
  }()

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

  private static func filePath(for name: String) -> String {
    let safe = name.replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    return "\(profilesDir)/\(safe).json"
  }

  static func save(_ snapshot: WindowSnapshot, name: String) {
    do {
      try FileManager.default.createDirectory(
        atPath: profilesDir,
        withIntermediateDirectories: true
      )

      let data = try encoder.encode(snapshot)
      let path = filePath(for: name)

      // Remove existing file if present
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }

      try data.write(to: URL(fileURLWithPath: path))
      Log.info("Profile saved: \(name) (\(snapshot.windows.count) windows)")
    } catch {
      Log.error("Failed to save profile '\(name)': \(error)")
    }
  }

  static func load(name: String) -> WindowSnapshot? {
    let path = filePath(for: name)

    guard FileManager.default.fileExists(atPath: path) else {
      Log.warn("Profile not found: \(name)")
      return nil
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let snapshot = try decoder.decode(WindowSnapshot.self, from: data)
      Log.info("Profile loaded: \(name) (\(snapshot.windows.count) windows)")
      return snapshot
    } catch {
      Log.error("Failed to load profile '\(name)': \(error)")
      return nil
    }
  }

  static func delete(name: String) {
    let path = filePath(for: name)
    do {
      try FileManager.default.removeItem(atPath: path)
      Log.info("Profile deleted: \(name)")
    } catch {
      Log.error("Failed to delete profile '\(name)': \(error)")
    }
  }

  static func listProfiles() -> [String] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else {
      return []
    }

    return files
      .filter { $0.hasSuffix(".json") }
      .map { String($0.dropLast(5)) } // remove .json
      .sorted()
  }
}
