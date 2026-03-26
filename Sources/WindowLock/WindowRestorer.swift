import Foundation
import AppKit
import ApplicationServices

struct RestoreResult {
  var totalSaved: Int = 0
  var appsNotRunning: [String] = []
  var appsNoWindows: [String] = []
  var windowsMatched: Int = 0
  var windowsMoved: Int = 0
  var windowsSpaceMoved: Int = 0
  var windowsSpaceFailed: Int = 0
  var windowsFailed: [(app: String, title: String, error: String)] = []
  var accessibilityDenied: Bool = false

  var summary: String {
    var lines: [String] = []
    lines.append("Restore summary:")
    lines.append("  Saved windows: \(totalSaved)")
    lines.append("  Matched: \(windowsMatched)")
    lines.append("  Moved: \(windowsMoved)")
    if windowsSpaceMoved > 0 || windowsSpaceFailed > 0 {
      lines.append("  Spaces restored: \(windowsSpaceMoved)")
      if windowsSpaceFailed > 0 {
        lines.append("  Spaces failed: \(windowsSpaceFailed)")
      }
    }
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

      let savedSpaceIndex = savedWindow.spaceIndex > 0 ? savedWindow.spaceIndex : savedWindow.spaceNumber

      Log.info("  \(savedWindow.ownerName) [\(savedWindow.windowIndex)] '\(savedWindow.windowTitle)' -> \(targetDisplay.name) @ \(Int(targetOrigin.x)),\(Int(targetOrigin.y)) \(Int(targetSize.width))x\(Int(targetSize.height)) space:\(savedSpaceIndex)")

      // Step 0: Move window to correct space if needed
      if savedSpaceIndex > 0, SpaceManager.isAvailable {
        if let cgWindowID = SpaceManager.windowID(from: axWindow) {
          let moved = SpaceManager.moveWindow(windowID: cgWindowID, toSpaceIndex: savedSpaceIndex)
          if moved {
            result.windowsSpaceMoved += 1
          } else {
            Log.warn("  Failed to move window to space \(savedSpaceIndex)")
            result.windowsSpaceFailed += 1
          }
        } else {
          Log.warn("  Could not get CGWindowID from AXUIElement for space move")
          result.windowsSpaceFailed += 1
        }
      }

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

  /// Match saved windows to current AX windows with high confidence.
  ///
  /// Uses a strict multi-pass approach — only matches when we are confident
  /// the saved window corresponds to the exact same AX window. Unmatched
  /// windows are skipped to avoid moving/resizing the wrong window.
  ///
  /// Pass 1: CGWindowID — the kernel-level window identifier, stable while
  ///         the window exists (doesn't survive app restart).
  /// Pass 2: Exact title + exact size — for windows recreated after restart
  ///         where the title and dimensions are the same.
  /// Pass 3: Exact title (unique within app) — only if exactly one saved and
  ///         one AX window share the same non-empty title.
  ///
  /// Deliberately omits fuzzy/index-based matching to prevent wrong-window
  /// restoration in multi-window apps like Chrome or Mail.
  private static func matchWindows(saved: [WindowInfo], axWindows: [AXUIElement]) -> [(WindowInfo, AXUIElement)] {
    var results: [(WindowInfo, AXUIElement)] = []
    var usedAXIndices = Set<Int>()
    var matchedSavedIDs = Set<UInt32>() // windowNumber is unique per saved window

    // Pre-compute AX window metadata once
    struct AXWindowMeta {
      let title: String
      let cgWindowID: UInt32
      let size: CGSize
    }

    let axMeta: [AXWindowMeta] = axWindows.map { window in
      var titleRef: CFTypeRef?
      let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
      let title = (titleResult == .success) ? (titleRef as? String ?? "") : ""

      let cgID = SpaceManager.windowID(from: window) ?? 0

      var sizeRef: CFTypeRef?
      var size = CGSize.zero
      let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
      if sizeResult == .success, let axValue = sizeRef {
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
      }

      return AXWindowMeta(title: title, cgWindowID: cgID, size: size)
    }

    Log.info("  AX windows (\(axMeta.count)): \(axMeta.map { "id=\($0.cgWindowID) '\($0.title)' \(Int($0.size.width))x\(Int($0.size.height))" })")
    Log.info("  Saved windows (\(saved.count)): \(saved.map { "id=\($0.windowNumber) '\($0.windowTitle)' \(Int($0.frame.width))x\(Int($0.frame.height))" })")

    // Pass 1: Match by CGWindowID (strongest identity — same kernel window)
    for savedWindow in saved {
      guard savedWindow.windowNumber > 0 else { continue }

      for (axIdx, meta) in axMeta.enumerated() where !usedAXIndices.contains(axIdx) {
        if meta.cgWindowID > 0 && meta.cgWindowID == savedWindow.windowNumber {
          results.append((savedWindow, axWindows[axIdx]))
          usedAXIndices.insert(axIdx)
          matchedSavedIDs.insert(savedWindow.windowNumber)
          Log.info("  Matched by windowID: \(savedWindow.windowNumber) '\(savedWindow.windowTitle)' -> AX[\(axIdx)]")
          break
        }
      }
    }

    // Pass 2: Exact title + matching size (handles app restart where IDs change)
    //         Size match uses a tolerance to accommodate minor rounding differences.
    let sizeTolerance: CGFloat = 4.0
    for savedWindow in saved where !matchedSavedIDs.contains(savedWindow.windowNumber) {
      guard !savedWindow.windowTitle.isEmpty else { continue }

      for (axIdx, meta) in axMeta.enumerated() where !usedAXIndices.contains(axIdx) {
        if meta.title == savedWindow.windowTitle &&
           abs(meta.size.width - CGFloat(savedWindow.frame.width)) <= sizeTolerance &&
           abs(meta.size.height - CGFloat(savedWindow.frame.height)) <= sizeTolerance {
          results.append((savedWindow, axWindows[axIdx]))
          usedAXIndices.insert(axIdx)
          matchedSavedIDs.insert(savedWindow.windowNumber)
          Log.info("  Matched by title+size: '\(savedWindow.windowTitle)' \(Int(savedWindow.frame.width))x\(Int(savedWindow.frame.height)) -> AX[\(axIdx)]")
          break
        }
      }
    }

    // Pass 3: Exact title only — but ONLY when the title is unique on both sides.
    //         If multiple saved or AX windows share the same title, skip to avoid ambiguity.
    let remainingSaved = saved.filter { !matchedSavedIDs.contains($0.windowNumber) && !$0.windowTitle.isEmpty }
    let remainingAXIndices = (0..<axWindows.count).filter { !usedAXIndices.contains($0) }

    // Group remaining saved by title
    let savedByTitle = Dictionary(grouping: remainingSaved) { $0.windowTitle }
    // Group remaining AX by title
    let axByTitle = Dictionary(grouping: remainingAXIndices) { axMeta[$0].title }

    for (title, savedGroup) in savedByTitle {
      guard title != "",
            savedGroup.count == 1,
            let axGroup = axByTitle[title],
            axGroup.count == 1 else { continue }

      let savedWindow = savedGroup[0]
      let axIdx = axGroup[0]
      guard !usedAXIndices.contains(axIdx) else { continue }

      results.append((savedWindow, axWindows[axIdx]))
      usedAXIndices.insert(axIdx)
      matchedSavedIDs.insert(savedWindow.windowNumber)
      Log.info("  Matched by unique title: '\(title)' -> AX[\(axIdx)]")
    }

    // Log unmatched for diagnostics
    let unmatched = saved.filter { !matchedSavedIDs.contains($0.windowNumber) }
    if !unmatched.isEmpty {
      Log.info("  Skipped \(unmatched.count) saved windows (no confident match):")
      for w in unmatched {
        Log.info("    - id=\(w.windowNumber) '\(w.windowTitle)' \(Int(w.frame.width))x\(Int(w.frame.height))")
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
