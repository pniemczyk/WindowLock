import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
  private var statusItem: NSStatusItem!
  private let logWindowController = LogWindowController()
  private let onRestore: () -> Void
  private let onCapture: () -> Void
  private let onQuit: () -> Void

  private let infoTag = 1000

  init(
    onRestore: @escaping () -> Void,
    onCapture: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.onRestore = onRestore
    self.onCapture = onCapture
    self.onQuit = onQuit
    super.init()
    setupStatusItem()
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    if let button = statusItem.button {
      if let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "WindowLock") {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = image.withSymbolConfiguration(config)
        button.image?.isTemplate = true
      } else {
        button.title = "WL"
      }
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    buildMenu(menu)
  }

  private func buildMenu(_ menu: NSMenu) {
    // --- Status info ---
    let windowItem = NSMenuItem(title: "Windows: --", action: nil, keyEquivalent: "")
    windowItem.isEnabled = false
    windowItem.tag = infoTag
    menu.addItem(windowItem)

    let displayItem = NSMenuItem(title: "Displays: --", action: nil, keyEquivalent: "")
    displayItem.isEnabled = false
    displayItem.tag = infoTag + 1
    menu.addItem(displayItem)

    let spacesItem = NSMenuItem(title: "Spaces: --", action: nil, keyEquivalent: "")
    spacesItem.isEnabled = false
    spacesItem.tag = infoTag + 2
    menu.addItem(spacesItem)

    let captureTimeItem = NSMenuItem(title: "Last capture: --", action: nil, keyEquivalent: "")
    captureTimeItem.isEnabled = false
    captureTimeItem.tag = infoTag + 3
    menu.addItem(captureTimeItem)

    updateInfoItems(menu)

    menu.addItem(NSMenuItem.separator())

    // --- Window Log ---
    let logItem = NSMenuItem(title: "Show Window Log...", action: #selector(handleShowLog), keyEquivalent: "l")
    logItem.target = self
    menu.addItem(logItem)

    menu.addItem(NSMenuItem.separator())

    // --- Quick actions ---
    let restoreItem = NSMenuItem(title: "Restore Last State", action: #selector(handleRestore), keyEquivalent: "r")
    restoreItem.target = self
    menu.addItem(restoreItem)

    let captureItem = NSMenuItem(title: "Capture Now", action: #selector(handleCapture), keyEquivalent: "c")
    captureItem.target = self
    menu.addItem(captureItem)

    menu.addItem(NSMenuItem.separator())

    // --- Save Layout ---
    let saveItem = NSMenuItem(title: "Save Layout As...", action: #selector(handleSaveLayout), keyEquivalent: "s")
    saveItem.target = self
    menu.addItem(saveItem)

    menu.addItem(NSMenuItem.separator())

    // --- Saved Layouts: click to restore directly ---
    let profiles = ProfileStore.listProfiles()

    if profiles.isEmpty {
      let emptyItem = NSMenuItem(title: "No Saved Layouts", action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      menu.addItem(emptyItem)
    } else {
      let headerItem = NSMenuItem(title: "Restore Layout:", action: nil, keyEquivalent: "")
      headerItem.isEnabled = false
      menu.addItem(headerItem)

      for name in profiles {
        // Direct click = restore. No submenu on these items.
        let item = NSMenuItem(title: "  \(name)", action: #selector(handleRestoreProfile(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = name
        menu.addItem(item)
      }

      // Manage layouts in a separate submenu
      menu.addItem(NSMenuItem.separator())

      let manageItem = NSMenuItem(title: "Manage Layouts", action: nil, keyEquivalent: "")
      let manageMenu = NSMenu()

      for name in profiles {
        let profileItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")

        let actionsMenu = NSMenu()

        let overwriteAction = NSMenuItem(title: "Overwrite with Current", action: #selector(handleOverwriteProfile(_:)), keyEquivalent: "")
        overwriteAction.target = self
        overwriteAction.representedObject = name
        actionsMenu.addItem(overwriteAction)

        let renameAction = NSMenuItem(title: "Rename...", action: #selector(handleRenameProfile(_:)), keyEquivalent: "")
        renameAction.target = self
        renameAction.representedObject = name
        actionsMenu.addItem(renameAction)

        actionsMenu.addItem(NSMenuItem.separator())

        let deleteAction = NSMenuItem(title: "Delete", action: #selector(handleDeleteProfile(_:)), keyEquivalent: "")
        deleteAction.target = self
        deleteAction.representedObject = name
        actionsMenu.addItem(deleteAction)

        profileItem.submenu = actionsMenu
        manageMenu.addItem(profileItem)
      }

      manageItem.submenu = manageMenu
      menu.addItem(manageItem)
    }

    menu.addItem(NSMenuItem.separator())

    // --- Configuration submenu ---
    let configItem = NSMenuItem(title: "Configuration", action: nil, keyEquivalent: "")
    let configMenu = NSMenu()

    // Debug mode
    let debugItem = NSMenuItem(title: "Debug Mode", action: #selector(handleToggleDebug(_:)), keyEquivalent: "d")
    debugItem.target = self
    debugItem.state = Log.debugMode ? .on : .off
    configMenu.addItem(debugItem)

    configMenu.addItem(NSMenuItem.separator())

    // Permissions
    let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
    let permissionsMenu = NSMenu()
    buildPermissionsSubmenu(permissionsMenu)
    permissionsItem.submenu = permissionsMenu
    configMenu.addItem(permissionsItem)

    configMenu.addItem(NSMenuItem.separator())

    // Uninstall
    let uninstallItem = NSMenuItem(title: "Uninstall WindowLock...", action: #selector(handleUninstall), keyEquivalent: "")
    uninstallItem.target = self
    configMenu.addItem(uninstallItem)

    configItem.submenu = configMenu
    menu.addItem(configItem)

    menu.addItem(NSMenuItem.separator())

    // --- About ---
    let aboutItem = NSMenuItem(title: "About WindowLock", action: #selector(handleAbout), keyEquivalent: "")
    aboutItem.target = self
    menu.addItem(aboutItem)

    menu.addItem(NSMenuItem.separator())

    // --- Quit ---
    let quitItem = NSMenuItem(title: "Quit WindowLock", action: #selector(handleQuit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  private func buildPermissionsSubmenu(_ menu: NSMenu) {
    let permissions = PermissionsManager.checkAll()
    let allGranted = permissions.filter(\.required).allSatisfy(\.granted)

    let statusText = allGranted ? "All required permissions granted" : "Some permissions missing"
    let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
    statusItem.isEnabled = false
    menu.addItem(statusItem)

    menu.addItem(NSMenuItem.separator())

    for permission in permissions {
      let icon = permission.granted ? "checkmark.circle.fill" : (permission.required ? "xmark.circle.fill" : "minus.circle")
      let requiredTag = permission.required ? " (required)" : " (optional)"
      let title = "\(permission.name)\(requiredTag)"

      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        item.image = image.withSymbolConfiguration(config)
        item.image?.isTemplate = false
      }

      let detailMenu = NSMenu()

      let descItem = NSMenuItem(title: permission.description, action: nil, keyEquivalent: "")
      descItem.isEnabled = false
      detailMenu.addItem(descItem)

      let statusDetail = NSMenuItem(
        title: permission.granted ? "Status: Granted" : "Status: Not Granted",
        action: nil,
        keyEquivalent: ""
      )
      statusDetail.isEnabled = false
      detailMenu.addItem(statusDetail)

      detailMenu.addItem(NSMenuItem.separator())

      let openItem = NSMenuItem(
        title: "Open \(permission.settingsPath)...",
        action: #selector(handleOpenPermissionSettings(_:)),
        keyEquivalent: ""
      )
      openItem.target = self
      openItem.representedObject = permission.name
      detailMenu.addItem(openItem)

      item.submenu = detailMenu
      menu.addItem(item)
    }

    menu.addItem(NSMenuItem.separator())

    let refreshItem = NSMenuItem(title: "Refresh Permissions", action: #selector(handleRefreshPermissions), keyEquivalent: "")
    refreshItem.target = self
    menu.addItem(refreshItem)

    let openAllItem = NSMenuItem(title: "Open All Permission Settings...", action: #selector(handleOpenAllSettings), keyEquivalent: "")
    openAllItem.target = self
    menu.addItem(openAllItem)
  }

  private func updateInfoItems(_ menu: NSMenu) {
    guard let snapshot = StateStore.load() else { return }

    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"

    if let item = menu.item(withTag: infoTag) {
      let onScreen = snapshot.windows.filter { $0.isOnScreen }.count
      item.title = "Windows: \(snapshot.windows.count) (\(onScreen) visible)"
    }
    if let item = menu.item(withTag: infoTag + 1) {
      item.title = "Displays: \(snapshot.displays.count)"
    }
    if let item = menu.item(withTag: infoTag + 2) {
      let spaceCount = SpaceManager.totalSpaceCount()
      let spacesUsed = Set(snapshot.windows.map { $0.spaceIndex }).filter { $0 > 0 }.count
      item.title = "Spaces: \(spaceCount) total, \(spacesUsed) with windows"
    }
    if let item = menu.item(withTag: infoTag + 3) {
      item.title = "Last capture: \(formatter.string(from: snapshot.capturedAt))"
    }
  }

  func updateStatus(windowCount: Int, displayCount: Int, lastCapture: Date) {
    // Stats are read fresh from StateStore each time the menu opens.
  }

  // MARK: - Debug

  private func showDebugResult(_ result: RestoreResult, layoutName: String? = nil) {
    guard Log.debugMode else { return }

    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    let title = layoutName != nil ? "Restore '\(layoutName!)' - Debug" : "Restore - Debug"
    alert.messageText = title

    if !result.windowsFailed.isEmpty || result.accessibilityDenied {
      alert.alertStyle = .warning
    } else {
      alert.alertStyle = .informational
    }

    // Selectable/copyable text view for the summary
    var summaryText = result.summary
    if result.accessibilityDenied {
      let path = PermissionsManager.currentBinaryPath
      summaryText += "\n\nBinary path: \(path)\nMake sure this exact path is added in System Settings > Accessibility."
    }
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = summaryText
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    alert.accessoryView = scrollView

    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Show Full Log")

    if result.accessibilityDenied {
      alert.addButton(withTitle: "Open Accessibility Settings")
    }

    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
      showFullLog()
    } else if response == .alertThirdButtonReturn {
      PermissionsManager.openAccessibilitySettings()
    }
  }

  private func showFullLog() {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Recent Log"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = Log.recentEntries.suffix(100).joined(separator: "\n")
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    alert.accessoryView = scrollView

    // Scroll to bottom
    textView.scrollToEndOfDocument(nil)

    alert.runModal()
  }

  // MARK: - Actions

  @objc private func handleShowLog() {
    logWindowController.showWindow()
  }

  @objc private func handleRestore() {
    Log.clearRecent()
    let result = WindowRestorer.restore(from: StateStore.load() ?? WindowSnapshot(capturedAt: Date(), displays: [], windows: []))
    showDebugResult(result)
    onRestore()
  }

  @objc private func handleCapture() {
    onCapture()
  }

  @objc private func handleToggleDebug(_ sender: NSMenuItem) {
    Log.debugMode.toggle()
    Log.info("Debug mode \(Log.debugMode ? "enabled" : "disabled")")
  }

  @objc private func handleSaveLayout() {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Save Current Layout"
    alert.informativeText = "Enter a name for this window layout:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    input.placeholderString = "e.g. Work Setup, Presentation"
    alert.accessoryView = input
    alert.window.initialFirstResponder = input

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let name = input.stringValue.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }

    if ProfileStore.listProfiles().contains(name) {
      let confirm = NSAlert()
      confirm.messageText = "Layout '\(name)' already exists"
      confirm.informativeText = "Do you want to overwrite it?"
      confirm.alertStyle = .warning
      confirm.addButton(withTitle: "Overwrite")
      confirm.addButton(withTitle: "Cancel")
      guard confirm.runModal() == .alertFirstButtonReturn else { return }
    }

    let snapshot = WindowTracker.captureCurrentState()
    ProfileStore.save(snapshot, name: name)
    Log.info("Layout saved as '\(name)'")

    if Log.debugMode {
      NSApp.activate(ignoringOtherApps: true)
      let info = NSAlert()
      info.messageText = "Layout Saved"
      info.informativeText = "'\(name)' saved with \(snapshot.windows.count) windows across \(snapshot.displays.count) displays."
      info.alertStyle = .informational
      info.addButton(withTitle: "OK")
      info.runModal()
    }
  }

  @objc private func handleRestoreProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }

    Log.clearRecent()
    Log.info("User requested restore of layout '\(name)'")

    guard let snapshot = ProfileStore.load(name: name) else {
      Log.error("Could not load layout '\(name)'")
      if Log.debugMode {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Restore Failed"
        alert.informativeText = "Could not load layout '\(name)'. The file may be corrupted."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
      }
      return
    }

    Log.info("Layout '\(name)' loaded: \(snapshot.windows.count) windows, \(snapshot.displays.count) displays")
    let result = WindowRestorer.restore(from: snapshot)
    showDebugResult(result, layoutName: name)
  }

  @objc private func handleOverwriteProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }

    let snapshot = WindowTracker.captureCurrentState()
    ProfileStore.save(snapshot, name: name)
    Log.info("Layout '\(name)' overwritten with current state")
  }

  @objc private func handleRenameProfile(_ sender: NSMenuItem) {
    guard let oldName = sender.representedObject as? String else { return }

    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Rename Layout"
    alert.informativeText = "Enter a new name for '\(oldName)':"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    input.stringValue = oldName
    alert.accessoryView = input
    alert.window.initialFirstResponder = input

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
    guard !newName.isEmpty, newName != oldName else { return }

    if ProfileStore.listProfiles().contains(newName) {
      let confirm = NSAlert()
      confirm.messageText = "Layout '\(newName)' already exists"
      confirm.informativeText = "Do you want to overwrite it?"
      confirm.alertStyle = .warning
      confirm.addButton(withTitle: "Overwrite")
      confirm.addButton(withTitle: "Cancel")
      guard confirm.runModal() == .alertFirstButtonReturn else { return }
    }

    guard let snapshot = ProfileStore.load(name: oldName) else { return }
    ProfileStore.save(snapshot, name: newName)
    ProfileStore.delete(name: oldName)
    Log.info("Layout renamed: '\(oldName)' -> '\(newName)'")
  }

  @objc private func handleDeleteProfile(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }

    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Delete Layout '\(name)'?"
    alert.informativeText = "This cannot be undone."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    ProfileStore.delete(name: name)
  }

  @objc private func handleOpenPermissionSettings(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String else { return }
    let permissions = PermissionsManager.checkAll()
    if let permission = permissions.first(where: { $0.name == name }) {
      PermissionsManager.openSettingsFor(permission: permission)
    }
  }

  @objc private func handleRefreshPermissions() {
    let permissions = PermissionsManager.checkAll()
    let binaryPath = PermissionsManager.currentBinaryPath
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Permission Status"

    var lines: [String] = []
    lines.append("Binary: \(binaryPath)")
    lines.append("")
    for p in permissions {
      let icon = p.granted ? "+" : "-"
      let tag = p.required ? "(required)" : "(optional)"
      lines.append("[\(icon)] \(p.name) \(tag)")
      if !p.granted {
        lines.append("    Grant in: \(p.settingsPath)")
      }
    }

    let anyDenied = permissions.contains(where: { !$0.granted && $0.required })
    if anyDenied {
      lines.append("")
      lines.append("Make sure you added this exact binary path")
      lines.append("in System Settings. Permissions are per-binary.")
    }

    let summaryText = lines.joined(separator: "\n")

    // Use selectable text view so the path can be copied
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = summaryText
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    alert.accessoryView = scrollView

    alert.alertStyle = anyDenied ? .warning : .informational
    alert.addButton(withTitle: "OK")
    if anyDenied {
      alert.addButton(withTitle: "Open Accessibility Settings")
    }

    let response = alert.runModal()
    if response == .alertSecondButtonReturn {
      PermissionsManager.openAccessibilitySettings()
    }
  }

  @objc private func handleOpenAllSettings() {
    PermissionsManager.openAccessibilitySettings()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PermissionsManager.openScreenRecordingSettings()
    }
  }

  @objc private func handleAbout() {
    NSApp.activate(ignoringOtherApps: true)

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? version
    let repoURL = "https://github.com/way2doit/window-lock"

    let alert = NSAlert()
    alert.messageText = "WindowLock"
    alert.alertStyle = .informational

    if let appIcon = NSImage(named: NSImage.applicationIconName) {
      alert.icon = appIcon
    }

    // Build the About content view
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 145))

    let versionLabel = NSTextField(labelWithString: "Version \(version) (build \(build))")
    versionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    versionLabel.frame = NSRect(x: 0, y: 120, width: 300, height: 20)
    container.addSubview(versionLabel)

    let taglineLabel = NSTextField(labelWithString: "Your windows. Your monitors. Your layout. Every single time.")
    taglineLabel.font = NSFont.systemFont(ofSize: 11)
    taglineLabel.textColor = .secondaryLabelColor
    taglineLabel.frame = NSRect(x: 0, y: 98, width: 300, height: 18)
    container.addSubview(taglineLabel)

    let separator = NSBox(frame: NSRect(x: 0, y: 88, width: 300, height: 1))
    separator.boxType = .separator
    container.addSubview(separator)

    let authorLabel = NSTextField(labelWithString: "Author: Paweł Niemczyk")
    authorLabel.font = NSFont.systemFont(ofSize: 12)
    authorLabel.frame = NSRect(x: 0, y: 64, width: 300, height: 18)
    container.addSubview(authorLabel)

    let companyLabel = NSTextField(labelWithString: "way2do.it")
    companyLabel.font = NSFont.systemFont(ofSize: 12)
    companyLabel.textColor = .secondaryLabelColor
    companyLabel.frame = NSRect(x: 0, y: 46, width: 300, height: 18)
    container.addSubview(companyLabel)

    let repoBtn = NSButton(frame: NSRect(x: 0, y: 10, width: 300, height: 20))
    repoBtn.isBordered = false
    repoBtn.setButtonType(.momentaryPushIn)
    repoBtn.alignment = .left
    repoBtn.target = self
    repoBtn.action = #selector(handleOpenRepo)
    let linkAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.controlAccentColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    repoBtn.attributedTitle = NSAttributedString(string: repoURL, attributes: linkAttrs)
    container.addSubview(repoBtn)

    let copyrightLabel = NSTextField(labelWithString: "© 2026 way2do.it — MIT License")
    copyrightLabel.font = NSFont.systemFont(ofSize: 10)
    copyrightLabel.textColor = .tertiaryLabelColor
    copyrightLabel.frame = NSRect(x: 0, y: -8, width: 300, height: 16)
    container.addSubview(copyrightLabel)

    alert.accessoryView = container
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  @objc private func handleOpenRepo() {
    if let url = URL(string: "https://github.com/pniemczyk/WindowLock") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func handleQuit() {
    onQuit()
  }

  @objc private func handleUninstall() {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Uninstall WindowLock?"
    alert.informativeText = "This will:\n- Stop the background daemon\n- Remove the LaunchAgent (no auto-start on login)\n- Remove WindowLock.app from /Applications\n\nSaved layouts and state data in ~/Library/Application Support/WindowLock/ will be preserved."
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else { return }

    Log.info("Uninstalling WindowLock from menu...")

    let plistName = "com.way2do.windowlock.plist"
    let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/\(plistName)"
    let uid = getuid()

    try? FileManager.default.removeItem(atPath: plistPath)
    Log.info("Removed LaunchAgent plist")

    // Remove app bundle from /Applications
    let appPath = "/Applications/WindowLock.app"
    try? FileManager.default.removeItem(atPath: appPath)
    Log.info("Removed \(appPath)")

    // Clean up old bare binary if present
    let oldBinary = "/usr/local/bin/windowlock"
    if FileManager.default.fileExists(atPath: oldBinary) {
      let script = "do shell script \"rm -f \(oldBinary)\" with administrator privileges"
      let task = Process()
      task.launchPath = "/usr/bin/osascript"
      task.arguments = ["-e", script]
      do {
        try task.run()
        task.waitUntilExit()
      } catch {
        Log.warn("Could not remove old binary: \(error)")
      }
    }

    let bootout = Process()
    bootout.launchPath = "/bin/launchctl"
    bootout.arguments = ["bootout", "gui/\(uid)/\(plistName)"]
    try? bootout.run()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      exit(0)
    }
  }
}
