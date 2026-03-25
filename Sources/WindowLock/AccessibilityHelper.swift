import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

struct PermissionStatus {
  let name: String
  let granted: Bool
  let required: Bool
  let description: String
  let settingsPath: String
}

enum PermissionsManager {
  /// The resolved absolute path of the currently running binary.
  static var currentBinaryPath: String {
    if let first = CommandLine.arguments.first {
      // Resolve to absolute path
      let url = URL(fileURLWithPath: first).standardized
      return url.path
    }
    return ProcessInfo.processInfo.arguments.first ?? "windowlock"
  }

  /// Check all permissions needed for full functionality.
  static func checkAll() -> [PermissionStatus] {
    return [
      checkAccessibility(),
      checkScreenRecording()
    ]
  }

  /// Quick check if Accessibility is granted (used at startup).
  static func isAccessibilityGranted() -> Bool {
    AXIsProcessTrusted()
  }

  /// Check Accessibility status. Prompts only on first run; subsequent checks are silent.
  static func checkAndPromptAccessibility() -> Bool {
    // Check silently first — avoid repeated system prompts on every launch
    let trusted = AXIsProcessTrusted()

    if !trusted {
      let path = currentBinaryPath
      Log.warn("Accessibility access NOT granted for: \(path)")
      Log.warn("WindowLock can capture window state but CANNOT restore positions or read window titles.")
      Log.warn("To grant access:")
      Log.warn("  1. Open System Settings > Privacy & Security > Accessibility")
      Log.warn("  2. Click + and add this exact binary: \(path)")
      Log.warn("  3. Enable the toggle next to it")
      Log.warn("  4. Restart WindowLock")
      Log.warn("NOTE: If you granted permission to a different path (e.g. /usr/local/bin/windowlock),")
      Log.warn("      it does NOT apply to this binary. macOS permissions are per-binary-path.")
    } else {
      Log.info("Accessibility access granted for: \(currentBinaryPath)")
    }

    return trusted
  }

  // MARK: - Individual permission checks

  static func checkAccessibility() -> PermissionStatus {
    let granted = AXIsProcessTrusted()
    return PermissionStatus(
      name: "Accessibility",
      granted: granted,
      required: true,
      description: "Move and resize windows, read window titles",
      settingsPath: "Privacy & Security > Accessibility"
    )
  }

  static func checkScreenRecording() -> PermissionStatus {
    // Screen Recording permission is needed for CGWindowListCopyWindowInfo to return
    // window titles (kCGWindowName). We test by checking if we can read a window name.
    let granted = testScreenRecordingAccess()
    return PermissionStatus(
      name: "Screen Recording",
      granted: granted,
      required: false,
      description: "Read window titles via CGWindowList (optional, AX API is used as fallback)",
      settingsPath: "Privacy & Security > Screen Recording"
    )
  }

  /// Test Screen Recording by checking if CGWindowList returns window names.
  private static func testScreenRecordingAccess() -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return false
    }

    // If we can read any non-empty window name, Screen Recording is granted
    for entry in windowList {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      if let name = entry[kCGWindowName as String] as? String, !name.isEmpty {
        return true
      }
    }

    // No names found — could mean no windows have titles, or permission denied.
    // Try a secondary check: if we got window entries with PIDs but no names,
    // Screen Recording is likely denied.
    let hasWindowsWithoutNames = windowList.contains { entry in
      let layer = entry[kCGWindowLayer as String] as? Int ?? -1
      let pid = entry[kCGWindowOwnerPID as String] as? Int ?? 0
      let name = entry[kCGWindowName as String] as? String ?? ""
      return layer == 0 && pid > 0 && name.isEmpty
    }

    return !hasWindowsWithoutNames
  }

  // MARK: - Open System Settings

  static func openAccessibilitySettings() {
    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  static func openScreenRecordingSettings() {
    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }

  static func openSettingsFor(permission: PermissionStatus) {
    switch permission.name {
    case "Accessibility":
      openAccessibilitySettings()
    case "Screen Recording":
      openScreenRecordingSettings()
    default:
      break
    }
  }

  private static func openSettings(_ urlString: String) {
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}
