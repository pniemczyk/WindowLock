import Foundation
import CoreGraphics

struct CodableRect: Codable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

  init(from rect: CGRect) {
    self.x = rect.origin.x
    self.y = rect.origin.y
    self.width = rect.size.width
    self.height = rect.size.height
  }
}

struct DisplayInfo: Codable, Sendable {
  let displayID: UInt32
  let name: String
  let bounds: CodableRect
  let isMain: Bool
  let isBuiltIn: Bool
}

struct WindowInfo: Codable, Sendable {
  let bundleID: String
  let ownerName: String
  let windowTitle: String
  let pid: Int32
  let windowNumber: UInt32      // CGWindowID for space operations
  let windowIndex: Int
  let frame: CodableRect
  let relativeFrame: CodableRect
  let displayIndex: Int
  let displayName: String
  let spaceIndex: Int           // 1-based index of the Space this window is on (0 = unknown)
  let spaceNumber: Int          // kept for backward compatibility with saved JSON
  let isOnScreen: Bool
  let windowLayer: Int
  let memoryUsage: Int
}

struct WindowSnapshot: Codable, Sendable {
  let capturedAt: Date
  let displays: [DisplayInfo]
  let windows: [WindowInfo]
}
