import Foundation
import AppKit

// MARK: - CLI argument parsing

let args = CommandLine.arguments
let captureOnly = args.contains("--capture-only")
let restoreOnly = args.contains("--restore")
let noMenuBar = args.contains("--no-menubar")
let listLayouts = args.contains("--list-layouts")
let saveLayoutArg = args.firstIndex(of: "--save-layout").flatMap {
  args.indices.contains($0 + 1) ? args[$0 + 1] : nil
}
let restoreLayoutArg = args.firstIndex(of: "--restore-layout").flatMap {
  args.indices.contains($0 + 1) ? args[$0 + 1] : nil
}
let deleteLayoutArg = args.firstIndex(of: "--delete-layout").flatMap {
  args.indices.contains($0 + 1) ? args[$0 + 1] : nil
}
let intervalArg = args.firstIndex(of: "--interval").flatMap {
  args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
} ?? 30

Log.info("WindowLock starting...")

// MARK: - Space Manager diagnostics

SpaceManager.logDiagnostics()

// MARK: - Accessibility check

let hasAccessibility = PermissionsManager.checkAndPromptAccessibility()

// MARK: - Layout management CLI

if listLayouts {
  let profiles = ProfileStore.listProfiles()
  if profiles.isEmpty {
    print("No saved layouts.")
  } else {
    print("Saved layouts:")
    for name in profiles {
      if let snap = ProfileStore.load(name: name) {
        print("  \(name)  (\(snap.windows.count) windows, \(snap.displays.count) displays)")
      } else {
        print("  \(name)  (error loading)")
      }
    }
  }
  exit(0)
}

if let name = saveLayoutArg {
  let snapshot = WindowTracker.captureCurrentState()
  ProfileStore.save(snapshot, name: name)
  print("Layout '\(name)' saved (\(snapshot.windows.count) windows)")
  exit(0)
}

if let name = restoreLayoutArg {
  guard hasAccessibility else {
    Log.error("Cannot restore without Accessibility access")
    exit(1)
  }
  guard let snapshot = ProfileStore.load(name: name) else {
    Log.error("Layout '\(name)' not found")
    exit(1)
  }
  WindowRestorer.restore(from: snapshot)
  print("Layout '\(name)' restored")
  exit(0)
}

if let name = deleteLayoutArg {
  ProfileStore.delete(name: name)
  print("Layout '\(name)' deleted")
  exit(0)
}

// MARK: - Capture-only mode

if captureOnly {
  let snapshot = WindowTracker.captureCurrentState()
  StateStore.save(snapshot)

  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  if let data = try? encoder.encode(snapshot),
     let json = String(data: data, encoding: .utf8) {
    print(json)
  }
  exit(0)
}

// MARK: - Restore-only mode

if restoreOnly {
  guard hasAccessibility else {
    Log.error("Cannot restore without Accessibility access")
    exit(1)
  }
  guard let snapshot = StateStore.load() else {
    Log.error("No saved state to restore")
    exit(1)
  }
  WindowRestorer.restore(from: snapshot)
  exit(0)
}

// MARK: - Daemon mode

Log.info("Running in daemon mode (capture interval: \(intervalArg)s)")

let app = NSApplication.shared

// Hide from Dock — menu bar icon only
app.setActivationPolicy(.accessory)

// Last saved snapshot for app-launch restoration
var lastSnapshot: WindowSnapshot? = StateStore.load()

// Shared capture function
func captureNow() {
  let snapshot = WindowTracker.captureCurrentState()
  guard !snapshot.windows.isEmpty else { return }
  StateStore.save(snapshot)
  lastSnapshot = snapshot
  statusBar?.updateStatus(
    windowCount: snapshot.windows.count,
    displayCount: snapshot.displays.count,
    lastCapture: snapshot.capturedAt
  )
}

// Shared restore function
func restoreNow() {
  guard hasAccessibility else {
    Log.warn("Skipping restore - no Accessibility access")
    return
  }
  guard let snapshot = lastSnapshot ?? StateStore.load() else {
    Log.warn("No saved state to restore")
    return
  }
  Log.info("Restoring window positions")
  WindowRestorer.restore(from: snapshot)
}

// Status bar icon
var statusBar: StatusBarController?

if !noMenuBar {
  statusBar = StatusBarController(
    onRestore: { restoreNow() },
    onCapture: { captureNow() },
    onQuit: {
      Log.info("Quit from menu bar")
      captureNow()
      NSApp.terminate(nil)
    }
  )
}

// Periodic capture timer
let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalArg), repeats: true) { _ in
  captureNow()
}
timer.tolerance = 5.0

// Sleep/wake observer
let observer = SleepWakeObserver(
  onSleep: {
    Log.info("Pre-sleep capture")
    captureNow()
  },
  onWake: {
    Log.info("Restoring window positions after wake")
    restoreNow()
  },
  onAppLaunch: { bundleID in
    guard hasAccessibility else { return }
    guard let snapshot = lastSnapshot ?? StateStore.load() else { return }

    let appWindows = snapshot.windows.filter { $0.bundleID == bundleID }
    guard !appWindows.isEmpty else { return }

    Log.info("Restoring windows for newly launched app: \(bundleID)")
    let appSnapshot = WindowSnapshot(
      capturedAt: snapshot.capturedAt,
      displays: snapshot.displays,
      windows: appWindows
    )
    WindowRestorer.restore(from: appSnapshot)
  }
)
observer.start()

// Signal handling for clean shutdown
let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
signalSource.setEventHandler {
  Log.info("SIGTERM received - saving state and exiting")
  captureNow()
  exit(0)
}
signalSource.resume()

let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
intSource.setEventHandler {
  Log.info("SIGINT received - saving state and exiting")
  captureNow()
  exit(0)
}
intSource.resume()

// Initial capture
let initialSnapshot = WindowTracker.captureCurrentState()
if !initialSnapshot.windows.isEmpty {
  StateStore.save(initialSnapshot)
  lastSnapshot = initialSnapshot
  statusBar?.updateStatus(
    windowCount: initialSnapshot.windows.count,
    displayCount: initialSnapshot.displays.count,
    lastCapture: initialSnapshot.capturedAt
  )
}

Log.info("WindowLock daemon running with menu bar icon.")

// Run the application event loop (handles both menu bar and notifications)
app.run()
