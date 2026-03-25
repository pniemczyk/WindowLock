import Foundation
import CoreGraphics
import AppKit

enum DisplayManager {
  static func currentDisplays() -> [DisplayInfo] {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)

    guard displayCount > 0 else { return [] }

    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

    // Build a map from CGDirectDisplayID to NSScreen.localizedName
    let screenNames = buildScreenNameMap()

    return displayIDs.enumerated().map { (index, id) in
      let bounds = CGDisplayBounds(id)
      let isMain = CGDisplayIsMain(id) != 0
      let isBuiltIn = CGDisplayIsBuiltin(id) != 0
      let name = screenNames[id] ?? displayFallbackName(index: index, isMain: isMain, isBuiltIn: isBuiltIn)

      return DisplayInfo(
        displayID: id,
        name: name,
        bounds: CodableRect(from: bounds),
        isMain: isMain,
        isBuiltIn: isBuiltIn
      )
    }
  }

  /// Match NSScreen instances to CGDirectDisplayIDs via deviceDescription.
  private static func buildScreenNameMap() -> [CGDirectDisplayID: String] {
    var map: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
      if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        map[displayID] = screen.localizedName
      }
    }
    return map
  }

  private static func displayFallbackName(index: Int, isMain: Bool, isBuiltIn: Bool) -> String {
    if isBuiltIn { return "Built-in Display" }
    if isMain { return "Main Display" }
    return "Display \(index + 1)"
  }

  static func displayIndex(for point: CGPoint, in displays: [DisplayInfo]) -> Int {
    for (index, display) in displays.enumerated() {
      if display.bounds.cgRect.contains(point) {
        return index
      }
    }
    return 0
  }

  static func relativeFrame(_ frame: CGRect, in display: DisplayInfo) -> CGRect {
    let displayBounds = display.bounds.cgRect
    return CGRect(
      x: frame.origin.x - displayBounds.origin.x,
      y: frame.origin.y - displayBounds.origin.y,
      width: frame.size.width,
      height: frame.size.height
    )
  }

  static func absoluteFrame(_ relativeFrame: CGRect, in display: DisplayInfo) -> CGRect {
    let displayBounds = display.bounds.cgRect
    return CGRect(
      x: relativeFrame.origin.x + displayBounds.origin.x,
      y: relativeFrame.origin.y + displayBounds.origin.y,
      width: relativeFrame.size.width,
      height: relativeFrame.size.height
    )
  }

  /// Maps old display indices to new display indices by matching resolution and position.
  static func mapOldToNew(old: [DisplayInfo], new: [DisplayInfo]) -> [Int: Int] {
    var mapping: [Int: Int] = [:]
    var usedNew = Set<Int>()

    // First pass: match by exact bounds (same resolution and position)
    for (oldIdx, oldDisplay) in old.enumerated() {
      for (newIdx, newDisplay) in new.enumerated() where !usedNew.contains(newIdx) {
        if oldDisplay.bounds.width == newDisplay.bounds.width &&
           oldDisplay.bounds.height == newDisplay.bounds.height &&
           oldDisplay.isMain == newDisplay.isMain {
          mapping[oldIdx] = newIdx
          usedNew.insert(newIdx)
          break
        }
      }
    }

    // Second pass: match remaining by resolution only
    for (oldIdx, oldDisplay) in old.enumerated() where mapping[oldIdx] == nil {
      for (newIdx, newDisplay) in new.enumerated() where !usedNew.contains(newIdx) {
        if oldDisplay.bounds.width == newDisplay.bounds.width &&
           oldDisplay.bounds.height == newDisplay.bounds.height {
          mapping[oldIdx] = newIdx
          usedNew.insert(newIdx)
          break
        }
      }
    }

    // Fallback: map any remaining old displays to display 0
    for oldIdx in old.indices where mapping[oldIdx] == nil {
      mapping[oldIdx] = 0
    }

    return mapping
  }
}
