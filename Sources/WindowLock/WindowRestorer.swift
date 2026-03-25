import Foundation
import AppKit
import ApplicationServices

struct RestoreResult {
  var totalSaved: Int = 0
  var appsNotRunning: [String] = []
  var appsNoWindows: [String] = []
  var windowsMatched: Int = 0
  var windowsMoved: Int = 0
  var windowsFailed: [(app: String, title: String, error: String)] = []
  var accessibilityDenied: Bool = false

  var summary: String {
    var lines: [String] = []
    lines.append("Restore summary:")
    lines.append("  Saved windows: \(totalSaved)")
    lines.append("  Matched: \(windowsMatched)")
    lines.append("  Moved: \(windowsMoved)")
    lines.append("  Failed: \(windowsFailed.count)")

    if accessibilityDenied {
      lines.append("")
      lines.append("ERROR: Accessibility access not granted!")
      lines.append("Cannot move or resize any windows.")
    }

    if !appsNotRunning.isEmpty {
      lines.append("")
      lines.append("Apps not running (skipped):")
      for app in appsNotRunning { lines.append("  - \(app)") }
    }

    if !appsNoWindows.isEmpty {
      lines.append("")
      lines.append("Apps with no AX windows found:")
      for app in appsNoWindows { lines.append("  - \(app)") }
    }

    if !windowsFailed.isEmpty {
      lines.append("")
      lines.append("Failed windows:")
      for f in windowsFailed {
        lines.append("  - \(f.app) '\(f.title)': \(f.error)")
      }
    }

    return lines.joined(separator: "\n")
  }
}

enum WindowRestorer {
  @discardableResult
  static func restore(from snapshot: WindowSnapshot) -> RestoreResult {
    var result = RestoreResult()
    result.totalSaved = snapshot.windows.count

    guard AXIsProcessTrusted() else {
      Log.error("Accessibility access not granted. Cannot restore windows.")
      result.accessibilityDenied = true
      return result
    }

    let currentDisplays = DisplayManager.currentDisplays()
    let displayMapping = DisplayManager.mapOldToNew(old: snapshot.displays, new: currentDisplays)

    Log.info("Display mapping: \(displayMapping)")
    Log.info("Current displays: \(currentDisplays.map { "\($0.name) \(Int($0.bounds.width))x\(Int($0.bounds.height))" })")
    Log.info("Saved displays: \(snapshot.displays.map { "\($0.name) \(Int($0.bounds.width))x\(Int($0.bounds.height))" })")

    let windowsByApp = Dictionary(grouping: snapshot.windows) { $0.bundleID }

    for (bundleID, savedWindows) in windowsByApp {
      let appName = savedWindows.first?.ownerName ?? bundleID

      guard let app = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == bundleID }) else {
        Log.info("App not running: \(appName) (\(bundleID)), skipping")
        result.appsNotRunning.append(appName)
        continue
      }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      let axWindows = getAXWindows(axApp)

      if axWindows.isEmpty {
        // Try without filtering as fallback
        let allAXWindows = getAllAXWindows(axApp)
        if allAXWindows.isEmpty {
          Log.warn("No AX windows at all for \(appName) (pid \(app.processIdentifier))")
          result.appsNoWindows.append(appName)
          continue
        }
        Log.info("No standard AX windows for \(appName), using \(allAXWindows.count) unfiltered windows")
        restoreWindowsForApp(
          savedWindows: savedWindows,
          axWindows: allAXWindows,
          displayMapping: displayMapping,
          currentDisplays: currentDisplays,
          result: &result
        )
      } else {
        Log.info("Restoring \(savedWindows.count) saved windows for \(appName) (found \(axWindows.count) AX windows)")
        restoreWindowsForApp(
          savedWindows: savedWindows,
          axWindows: axWindows,
          displayMapping: displayMapping,
          currentDisplays: currentDisplays,
          result: &result
        )
      }
    }

    Log.info("Restore complete: \(result.windowsMoved)/\(result.windowsMatched) moved, \(result.windowsFailed.count) failed")
    return result
  }

  private static func restoreWindowsForApp(
    savedWindows: [WindowInfo],
    axWindows: [AXUIElement],
    displayMapping: [Int: Int],
    currentDisplays: [DisplayInfo],
    result: inout RestoreResult
  ) {
    let matches = matchWindows(saved: savedWindows, axWindows: axWindows)
    result.windowsMatched += matches.count

    for (savedWindow, axWindow) in matches {
      guard let newDisplayIndex = displayMapping[savedWindow.displayIndex],
            currentDisplays.indices.contains(newDisplayIndex) else {
        let error = "No display mapping for display index \(savedWindow.displayIndex)"
        Log.warn(error)
        result.windowsFailed.append((app: savedWindow.ownerName, title: savedWindow.windowTitle, error: error))
        continue
      }

      let targetDisplay = currentDisplays[newDisplayIndex]
      let absoluteFrame = DisplayManager.absoluteFrame(
        savedWindow.relativeFrame.cgRect,
        in: targetDisplay
      )

      let targetOrigin = absoluteFrame.origin
      let targetSize = absoluteFrame.size

      Log.info("  \(savedWindow.ownerName) [\(savedWindow.windowIndex)] '\(savedWindow.windowTitle)' -> \(targetDisplay.name) @ \(Int(targetOrigin.x)),\(Int(targetOrigin.y)) \(Int(targetSize.width))x\(Int(targetSize.height))")

      // Step 1: Move position first (gets window onto correct monitor)
      let posResult1 = setWindowPosition(axWindow, position: targetOrigin)

      // Step 2: Set size
      let sizeResult = setWindowSize(axWindow, size: targetSize)

      // Step 3: Set position again (some apps clamp position on first move)
      let posResult2 = setWindowPosition(axWindow, position: targetOrigin)

      if posResult1 != .success && posResult2 != .success {
        let error = "Position failed: AXError \(posResult1.rawValue)"
        result.windowsFailed.append((app: savedWindow.ownerName, title: savedWindow.windowTitle, error: error))
      } else if sizeResult != .success {
        let error = "Size failed: AXError \(sizeResult.rawValue), but position OK"
        result.windowsFailed.append((app: savedWindow.ownerName, title: savedWindow.windowTitle, error: error))
        result.windowsMoved += 1
      } else {
        result.windowsMoved += 1
      }
    }
  }

  /// Match saved windows to AX windows by title first, then by index.
  private static func matchWindows(saved: [WindowInfo], axWindows: [AXUIElement]) -> [(WindowInfo, AXUIElement)] {
    var results: [(WindowInfo, AXUIElement)] = []
    var usedAXIndices = Set<Int>()

    // Get AX window titles and positions
    let axTitles: [String] = axWindows.map { window in
      var titleRef: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
      if result == .success, let title = titleRef as? String {
        return title
      }
      return ""
    }

    Log.info("  AX window titles: \(axTitles)")
    Log.info("  Saved titles: \(saved.map { $0.windowTitle })")

    // Pass 1: Match by exact title (non-empty titles only)
    for savedWindow in saved {
      guard !savedWindow.windowTitle.isEmpty else { continue }

      for (axIdx, axTitle) in axTitles.enumerated() where !usedAXIndices.contains(axIdx) {
        if axTitle == savedWindow.windowTitle {
          results.append((savedWindow, axWindows[axIdx]))
          usedAXIndices.insert(axIdx)
          Log.info("  Matched by exact title: '\(savedWindow.windowTitle)' -> AX[\(axIdx)]")
          break
        }
      }
    }

    // Pass 2: Match by partial title (contains)
    let unmatchedAfterExact = saved.filter { sw in
      !results.contains(where: { $0.0.windowIndex == sw.windowIndex && $0.0.bundleID == sw.bundleID })
    }

    for savedWindow in unmatchedAfterExact {
      guard !savedWindow.windowTitle.isEmpty else { continue }

      for (axIdx, axTitle) in axTitles.enumerated() where !usedAXIndices.contains(axIdx) {
        if !axTitle.isEmpty && (axTitle.contains(savedWindow.windowTitle) || savedWindow.windowTitle.contains(axTitle)) {
          results.append((savedWindow, axWindows[axIdx]))
          usedAXIndices.insert(axIdx)
          Log.info("  Matched by partial title: '\(savedWindow.windowTitle)' ~ '\(axTitle)' -> AX[\(axIdx)]")
          break
        }
      }
    }

    // Pass 3: Match remaining by window index order
    let stillUnmatched = saved.filter { sw in
      !results.contains(where: { $0.0.windowIndex == sw.windowIndex && $0.0.bundleID == sw.bundleID })
    }.sorted(by: { $0.windowIndex < $1.windowIndex })

    let unusedAXIndices = (0..<axWindows.count).filter { !usedAXIndices.contains($0) }.sorted()

    for (i, savedWindow) in stillUnmatched.enumerated() {
      if i < unusedAXIndices.count {
        let axIdx = unusedAXIndices[i]
        results.append((savedWindow, axWindows[axIdx]))
        usedAXIndices.insert(axIdx)
        Log.info("  Matched by index: saved[\(savedWindow.windowIndex)] -> AX[\(axIdx)]")
      } else {
        Log.warn("  No AX window available for saved[\(savedWindow.windowIndex)] '\(savedWindow.windowTitle)'")
      }
    }

    return results
  }

  private static func getAXWindows(_ axApp: AXUIElement) -> [AXUIElement] {
    let all = getAllAXWindows(axApp)

    // Filter to only standard windows (skip popovers, sheets, etc.)
    return all.filter { window in
      var roleRef: CFTypeRef?
      let roleResult = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
      guard roleResult == .success, let role = roleRef as? String else { return true }

      var subroleRef: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
      let subrole = subroleRef as? String ?? ""

      // Keep standard windows and dialogs, skip others
      return role == kAXWindowRole as String &&
        (subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String || subrole.isEmpty)
    }
  }

  private static func getAllAXWindows(_ axApp: AXUIElement) -> [AXUIElement] {
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
      Log.warn("  AXUIElementCopyAttributeValue(kAXWindows) failed: \(result.rawValue)")
      return []
    }
    return windows
  }

  @discardableResult
  private static func setWindowPosition(_ window: AXUIElement, position: CGPoint) -> AXError {
    var point = position
    guard let value = AXValueCreate(.cgPoint, &point) else {
      Log.warn("Failed to create AXValue for position")
      return .failure
    }
    let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    if result != .success {
      Log.warn("Failed to set position (\(Int(position.x)),\(Int(position.y))): error \(result.rawValue)")
    }
    return result
  }

  @discardableResult
  private static func setWindowSize(_ window: AXUIElement, size: CGSize) -> AXError {
    var s = size
    guard let value = AXValueCreate(.cgSize, &s) else {
      Log.warn("Failed to create AXValue for size")
      return .failure
    }
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    if result != .success {
      Log.warn("Failed to set size (\(Int(size.width))x\(Int(size.height))): error \(result.rawValue)")
    }
    return result
  }
}
