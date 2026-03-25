import Foundation
import AppKit

final class SleepWakeObserver {
  private let onSleep: () -> Void
  private let onWake: () -> Void
  private let onAppLaunch: (String) -> Void

  init(
    onSleep: @escaping () -> Void,
    onWake: @escaping () -> Void,
    onAppLaunch: @escaping (String) -> Void
  ) {
    self.onSleep = onSleep
    self.onWake = onWake
    self.onAppLaunch = onAppLaunch
  }

  func start() {
    let center = NSWorkspace.shared.notificationCenter

    center.addObserver(
      self,
      selector: #selector(handleSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )

    center.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    center.addObserver(
      self,
      selector: #selector(handleAppLaunch(_:)),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )

    // Also observe display configuration changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDisplayChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    Log.info("Sleep/wake observer started")
  }

  @objc private func handleSleep() {
    Log.info("System going to sleep - capturing state")
    onSleep()
  }

  @objc private func handleWake() {
    Log.info("System woke up - scheduling restoration")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      self?.onWake()
    }
  }

  @objc private func handleAppLaunch(_ notification: Notification) {
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let bundleID = app.bundleIdentifier else { return }
    Log.info("App launched: \(bundleID)")
    // Delay to give the app time to create its windows
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.onAppLaunch(bundleID)
    }
  }

  @objc private func handleDisplayChange() {
    Log.info("Display configuration changed - scheduling restoration")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.onWake()
    }
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
  }
}
