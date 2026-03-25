import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

enum WindowTracker {
  private static let ignoredOwners: Set<String> = [
    "WindowServer", "Dock", "SystemUIServer", "Control Center",
    "Notification Center", "Spotlight", "WindowLock"
  ]

  static func captureCurrentState() -> WindowSnapshot {
    let displays = DisplayManager.currentDisplays()

    guard let windowList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      Log.warn("Failed to get window list")
      return WindowSnapshot(capturedAt: Date(), displays: displays, windows: [])
    }

    // Pre-fetch AX window titles per PID for reliable title matching
    var axTitlesByPID: [pid_t: [String]] = [:]

    var windows: [WindowInfo] = []
    // Track per-app window index for matching when titles are empty
    var appWindowIndex: [String: Int] = [:]

    for entry in windowList {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
        continue
      }

      guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
        continue
      }

      guard rect.width > 0 && rect.height > 0 else { continue }

      let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
      guard !ignoredOwners.contains(ownerName) else { continue }

      let pid = entry[kCGWindowOwnerPID as String] as? pid_t ?? 0

      let bundleID: String
      if let app = NSRunningApplication(processIdentifier: pid) {
        bundleID = app.bundleIdentifier ?? ""
      } else {
        bundleID = ""
      }

      guard !bundleID.isEmpty else { continue }

      // Get window title: try CGWindowList first, fall back to AX API
      var windowTitle = entry[kCGWindowName as String] as? String ?? ""

      if windowTitle.isEmpty {
        // Fetch AX titles for this PID once
        if axTitlesByPID[pid] == nil {
          axTitlesByPID[pid] = fetchAXWindowTitles(pid: pid)
        }

        let idx = appWindowIndex[bundleID] ?? 0
        let axTitles = axTitlesByPID[pid] ?? []
        if idx < axTitles.count {
          windowTitle = axTitles[idx]
        }
      }

      let currentIndex = appWindowIndex[bundleID] ?? 0
      appWindowIndex[bundleID] = currentIndex + 1

      let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? true
      let windowLayer = entry[kCGWindowLayer as String] as? Int ?? 0
      let memoryUsage = entry[kCGWindowMemoryUsage as String] as? Int ?? 0
      let spaceNumber = entry["kCGWindowWorkspace" as String] as? Int ?? 0

      let displayIndex = DisplayManager.displayIndex(for: rect.origin, in: displays)
      let display = displays.indices.contains(displayIndex) ? displays[displayIndex] : displays.first!
      let relFrame = DisplayManager.relativeFrame(rect, in: display)

      windows.append(WindowInfo(
        bundleID: bundleID,
        ownerName: ownerName,
        windowTitle: windowTitle,
        pid: pid,
        windowIndex: currentIndex,
        frame: CodableRect(from: rect),
        relativeFrame: CodableRect(from: relFrame),
        displayIndex: displayIndex,
        displayName: display.name,
        spaceNumber: spaceNumber,
        isOnScreen: isOnScreen,
        windowLayer: windowLayer,
        memoryUsage: memoryUsage
      ))
    }

    Log.info("Captured \(windows.count) windows across \(displays.count) displays")
    return WindowSnapshot(capturedAt: Date(), displays: displays, windows: windows)
  }

  /// Fetch window titles via AXUIElement (works with Accessibility permission, no Screen Recording needed).
  private static func fetchAXWindowTitles(pid: pid_t) -> [String] {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
      return []
    }

    return axWindows.map { window in
      var titleRef: CFTypeRef?
      let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
      if titleResult == .success, let title = titleRef as? String {
        return title
      }
      return ""
    }
  }
}
