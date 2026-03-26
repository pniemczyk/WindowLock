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

    // Use .optionAll to get windows from ALL spaces, not just the active one.
    // .optionOnScreenOnly only returns windows on the current space.
    guard let windowList = CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
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
    // Track seen CGWindowIDs to avoid duplicates
    var seenWindowIDs: Set<UInt32> = []

    // Collect all candidate CGWindowIDs first to batch-query space indices
    var collectedWindowIDs: [UInt32] = []
    for entry in windowList {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
      guard let wid = entry[kCGWindowNumber as String] as? UInt32, wid > 0 else { continue }
      collectedWindowIDs.append(wid)
    }

    // Batch-fetch real space indices via CGS private API
    let spaceIndices = SpaceManager.spaceIndicesForWindows(windowIDs: collectedWindowIDs)

    // Build space-to-display UUID mapping for accurate display assignment
    let spaceDisplayMap = SpaceManager.spaceToDisplayMap()

    for entry in windowList {
      guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
        continue
      }

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

      let windowNumber = entry[kCGWindowNumber as String] as? UInt32 ?? 0

      // Skip duplicates (optionAll can return the same window multiple times)
      guard windowNumber > 0, !seenWindowIDs.contains(windowNumber) else { continue }
      seenWindowIDs.insert(windowNumber)

      guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
            let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
        continue
      }

      // Allow zero-size for minimized windows but skip truly empty ones
      guard rect.width > 0 && rect.height > 0 else { continue }

      let isOnScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false

      // Skip off-screen windows that have no space (likely system artifacts)
      let legacySpaceNumber = entry["kCGWindowWorkspace" as String] as? Int ?? 0
      let spaceIndex = spaceIndices[windowNumber] ?? legacySpaceNumber
      if !isOnScreen && spaceIndex == 0 {
        continue
      }

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

      let windowLayer = entry[kCGWindowLayer as String] as? Int ?? 0
      let memoryUsage = entry[kCGWindowMemoryUsage as String] as? Int ?? 0

      // Determine display: for off-screen windows (other spaces), use the space-to-display
      // mapping from CGS API. For on-screen windows, use position-based detection.
      let displayIndex: Int
      let display: DisplayInfo
      if isOnScreen {
        displayIndex = DisplayManager.displayIndex(for: rect.origin, in: displays)
        display = displays.indices.contains(displayIndex) ? displays[displayIndex] : displays.first!
      } else if let displayUUID = spaceDisplayMap[spaceIndex],
                let idx = DisplayManager.displayIndexByUUID(displayUUID, in: displays) {
        displayIndex = idx
        display = displays[idx]
      } else {
        // Fallback: use position-based heuristic even for off-screen
        displayIndex = DisplayManager.displayIndex(for: rect.origin, in: displays)
        display = displays.indices.contains(displayIndex) ? displays[displayIndex] : displays.first!
      }

      let relFrame = DisplayManager.relativeFrame(rect, in: display)

      windows.append(WindowInfo(
        bundleID: bundleID,
        ownerName: ownerName,
        windowTitle: windowTitle,
        pid: pid,
        windowNumber: windowNumber,
        windowIndex: currentIndex,
        frame: CodableRect(from: rect),
        relativeFrame: CodableRect(from: relFrame),
        displayIndex: displayIndex,
        displayName: display.name,
        spaceIndex: spaceIndex,
        spaceNumber: legacySpaceNumber,
        isOnScreen: isOnScreen,
        windowLayer: windowLayer,
        memoryUsage: memoryUsage
      ))
    }

    let spacesUsed = Set(windows.map { $0.spaceIndex }).filter { $0 > 0 }.sorted()
    Log.info("Captured \(windows.count) windows across \(displays.count) displays, spaces: \(spacesUsed) (\(windows.filter { $0.isOnScreen }.count) on-screen)")
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
