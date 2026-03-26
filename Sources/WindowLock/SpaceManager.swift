import Foundation
import CoreGraphics
import ApplicationServices

/// Manages macOS Spaces (virtual desktops) using private CGS APIs.
/// These APIs are not documented by Apple but are widely used by window
/// management utilities (yabai, Amethyst, etc.).
enum SpaceManager {
  typealias CGSConnectionID = Int32
  typealias CGSSpaceID = UInt64

  // MARK: - CGS Function Types

  private typealias MainConnectionIDFn = @convention(c) () -> CGSConnectionID
  private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID
  private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> CFArray?
  private typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> CFArray?
  private typealias MoveWindowsToManagedSpaceFn = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
  private typealias AddWindowsToSpacesFn = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
  private typealias RemoveWindowsFromSpacesFn = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
  private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

  // Space type masks for CGSCopySpacesForWindows
  // Bitmask: 1=current, 2=others, 4=user → 7=all
  private static let kCGSSpaceIncludesCurrent: Int32 = 1
  private static let kCGSSpaceIncludesOthers: Int32 = 2
  private static let kCGSSpaceIncludesUser: Int32 = 4
  private static let kCGSSpaceAll: Int32 = 7

  // MARK: - Dynamic Loading

  private static let cgHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
  }()

  private static let axHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
  }()

  private static func loadCGS<T>(_ name: String) -> T? {
    guard let handle = cgHandle, let sym = dlsym(handle, name) else {
      Log.warn("SpaceManager: Failed to load \(name)")
      return nil
    }
    return unsafeBitCast(sym, to: T.self)
  }

  private static func loadAX<T>(_ name: String) -> T? {
    guard let handle = axHandle, let sym = dlsym(handle, name) else {
      Log.warn("SpaceManager: Failed to load \(name)")
      return nil
    }
    return unsafeBitCast(sym, to: T.self)
  }

  // Cached function pointers
  private static let _mainConnectionID: MainConnectionIDFn? = loadCGS("CGSMainConnectionID")
  private static let _getActiveSpace: GetActiveSpaceFn? = loadCGS("CGSGetActiveSpace")
  private static let _copySpacesForWindows: CopySpacesForWindowsFn? = loadCGS("CGSCopySpacesForWindows")
  private static let _copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = loadCGS("CGSCopyManagedDisplaySpaces")
  private static let _moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn? = loadCGS("CGSMoveWindowsToManagedSpace")
  private static let _addWindowsToSpaces: AddWindowsToSpacesFn? = loadCGS("CGSAddWindowsToSpaces")
  private static let _removeWindowsFromSpaces: RemoveWindowsFromSpacesFn? = loadCGS("CGSRemoveWindowsFromSpaces")
  private static let _getWindow: GetWindowFn? = loadAX("_AXUIElementGetWindow")

  /// Whether the CGS private APIs are available.
  static var isAvailable: Bool {
    _mainConnectionID != nil && _copyManagedDisplaySpaces != nil
  }

  /// Log diagnostic info about API availability. Called once at startup.
  static func logDiagnostics() {
    Log.info("SpaceManager: cgHandle=\(cgHandle != nil), axHandle=\(axHandle != nil)")
    Log.info("SpaceManager: mainConnectionID=\(_mainConnectionID != nil), getActiveSpace=\(_getActiveSpace != nil)")
    Log.info("SpaceManager: copySpacesForWindows=\(_copySpacesForWindows != nil), copyManagedDisplaySpaces=\(_copyManagedDisplaySpaces != nil)")
    Log.info("SpaceManager: moveWindowsToManagedSpace=\(_moveWindowsToManagedSpace != nil), getWindow(AX)=\(_getWindow != nil)")
    if let conn = connectionID {
      Log.info("SpaceManager: connectionID=\(conn)")
      let spaces = allSpaces()
      Log.info("SpaceManager: found \(spaces.count) spaces across displays")
      for s in spaces {
        Log.info("SpaceManager:   space id=\(s.spaceID) index=\(s.spaceIndex) display=\(s.displayUUID) active=\(s.isActive) fullscreen=\(s.isFullscreen)")
      }
    } else {
      Log.warn("SpaceManager: connectionID is nil — CGS APIs won't work")
    }
  }

  // MARK: - Connection

  private static var connectionID: CGSConnectionID? {
    _mainConnectionID?()
  }

  // MARK: - Public API

  /// Information about a single space.
  struct SpaceInfo {
    let spaceID: CGSSpaceID
    let spaceIndex: Int     // 1-based index within its display
    let displayUUID: String
    let isActive: Bool
    let isFullscreen: Bool
  }

  /// Get all user spaces across all displays, in order.
  static func allSpaces() -> [SpaceInfo] {
    guard let conn = connectionID,
          let getManagedSpaces = _copyManagedDisplaySpaces,
          let getActive = _getActiveSpace else {
      return []
    }

    let activeSpaceID = CGSSpaceID(getActive(conn))

    guard let displays = getManagedSpaces(conn) as? [[String: Any]] else {
      Log.warn("SpaceManager: CGSCopyManagedDisplaySpaces returned nil")
      return []
    }

    var result: [SpaceInfo] = []

    for display in displays {
      guard let displayUUID = display["Display Identifier"] as? String,
            let spaces = display["Spaces"] as? [[String: Any]] else {
        continue
      }

      var userIndex = 0
      for space in spaces {
        guard let id64 = space["id64"] as? NSNumber else { continue }
        let spaceID = id64.uint64Value
        let spaceType = (space["type"] as? NSNumber)?.intValue ?? 0

        // Type 0 = user space, type 4 = fullscreen space
        let isFullscreen = spaceType == 4
        userIndex += 1

        result.append(SpaceInfo(
          spaceID: spaceID,
          spaceIndex: userIndex,
          displayUUID: displayUUID,
          isActive: spaceID == activeSpaceID,
          isFullscreen: isFullscreen
        ))
      }
    }

    return result
  }

  /// Get display UUIDs mapped to their ordered space IDs.
  static func spacesPerDisplay() -> [String: [CGSSpaceID]] {
    var map: [String: [CGSSpaceID]] = [:]
    let spaces = allSpaces()
    for space in spaces {
      map[space.displayUUID, default: []].append(space.spaceID)
    }
    return map
  }

  /// Get the space ID for a specific CGWindowID.
  static func spaceForWindow(windowID: UInt32) -> CGSSpaceID? {
    guard let conn = connectionID,
          let copySpaces = _copySpacesForWindows else {
      return nil
    }

    let windowIDs = [NSNumber(value: windowID)] as CFArray
    guard let spaceIDs = copySpaces(conn, kCGSSpaceAll, windowIDs) as? [NSNumber],
          let first = spaceIDs.first else {
      return nil
    }

    return first.uint64Value
  }

  /// Get the space index (1-based) for a window on a given display UUID.
  /// Returns 0 if unknown.
  static func spaceIndexForWindow(windowID: UInt32) -> (index: Int, displayUUID: String)? {
    guard let spaceID = spaceForWindow(windowID: windowID) else {
      return nil
    }

    let spaces = allSpaces()
    if let info = spaces.first(where: { $0.spaceID == spaceID }) {
      return (info.spaceIndex, info.displayUUID)
    }

    return nil
  }

  /// Get space indices for multiple windows at once (more efficient).
  static func spaceIndicesForWindows(windowIDs: [UInt32]) -> [UInt32: Int] {
    guard let conn = connectionID,
          let copySpaces = _copySpacesForWindows else {
      Log.warn("SpaceManager: spaceIndicesForWindows unavailable (conn=\(connectionID != nil), copySpaces=\(_copySpacesForWindows != nil))")
      return [:]
    }

    let spaces = allSpaces()
    var spaceIDToIndex: [CGSSpaceID: Int] = [:]
    for space in spaces {
      spaceIDToIndex[space.spaceID] = space.spaceIndex
    }

    if spaceIDToIndex.isEmpty {
      Log.warn("SpaceManager: no spaces found, space indices will be empty")
      return [:]
    }

    var result: [UInt32: Int] = [:]
    var unmapped = 0
    for windowID in windowIDs {
      let ids = [NSNumber(value: windowID)] as CFArray
      if let spaceIDs = copySpaces(conn, kCGSSpaceAll, ids) as? [NSNumber],
         let first = spaceIDs.first {
        let sid = first.uint64Value
        if let idx = spaceIDToIndex[sid] {
          result[windowID] = idx
        } else {
          unmapped += 1
        }
      }
    }

    Log.info("SpaceManager: resolved \(result.count)/\(windowIDs.count) windows to spaces (\(unmapped) unmapped space IDs)")
    return result
  }

  /// Move a window (by CGWindowID) to a specific space index on its current display.
  static func moveWindow(windowID: UInt32, toSpaceIndex targetIndex: Int) -> Bool {
    guard let conn = connectionID,
          let moveWindows = _moveWindowsToManagedSpace else {
      Log.warn("SpaceManager: move API unavailable")
      return false
    }

    // Find the target space ID from the index
    let spaces = allSpaces()

    // First figure out which display this window is on
    guard let currentSpaceID = spaceForWindow(windowID: windowID),
          let currentInfo = spaces.first(where: { $0.spaceID == currentSpaceID }) else {
      Log.warn("SpaceManager: can't determine current space for window \(windowID)")
      return false
    }

    if currentInfo.spaceIndex == targetIndex {
      Log.info("SpaceManager: window \(windowID) already on space \(targetIndex)")
      return true
    }

    // Find target space on the same display
    let displaySpaces = spaces.filter { $0.displayUUID == currentInfo.displayUUID }
    guard let target = displaySpaces.first(where: { $0.spaceIndex == targetIndex }) else {
      Log.warn("SpaceManager: space index \(targetIndex) not found on display \(currentInfo.displayUUID)")
      // Try any display if same display doesn't have the space
      if let anyTarget = spaces.first(where: { $0.spaceIndex == targetIndex }) {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        moveWindows(conn, windowIDs, anyTarget.spaceID)
        Log.info("SpaceManager: moved window \(windowID) to space \(targetIndex) (different display)")
        return true
      }
      return false
    }

    let windowIDs = [NSNumber(value: windowID)] as CFArray
    moveWindows(conn, windowIDs, target.spaceID)
    Log.info("SpaceManager: moved window \(windowID) from space \(currentInfo.spaceIndex) to space \(targetIndex)")
    return true
  }

  /// Move a window to a specific space ID directly.
  static func moveWindow(windowID: UInt32, toSpaceID spaceID: CGSSpaceID) -> Bool {
    guard let conn = connectionID,
          let moveWindows = _moveWindowsToManagedSpace else {
      return false
    }

    let windowIDs = [NSNumber(value: windowID)] as CFArray
    moveWindows(conn, windowIDs, spaceID)
    return true
  }

  /// Get the CGWindowID from an AXUIElement window.
  static func windowID(from axElement: AXUIElement) -> UInt32? {
    guard let getWin = _getWindow else { return nil }
    var windowID: UInt32 = 0
    let result = getWin(axElement, &windowID)
    return result == .success ? windowID : nil
  }

  /// Get the currently active space ID.
  static func activeSpaceID() -> CGSSpaceID? {
    guard let conn = connectionID, let getActive = _getActiveSpace else {
      return nil
    }
    return CGSSpaceID(getActive(conn))
  }

  /// Map space indices to their display UUIDs.
  /// Useful for determining which display an off-screen window belongs to.
  static func spaceToDisplayMap() -> [Int: String] {
    var map: [Int: String] = [:]
    for space in allSpaces() {
      map[space.spaceIndex] = space.displayUUID
    }
    return map
  }

  /// Total number of user spaces across all displays.
  static func totalSpaceCount() -> Int {
    allSpaces().count
  }
}
