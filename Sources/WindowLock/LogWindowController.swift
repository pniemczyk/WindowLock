import AppKit

// MARK: - Tree node for outline view

/// Wrapper around WindowInfo for NSOutlineView (needs reference-type identity).
/// A node with children represents a grouped app; children are its secondary windows.
final class WindowNode {
  let info: WindowInfo
  var children: [WindowNode]

  var isGroup: Bool { !children.isEmpty }

  /// Total memory for this node and all children.
  var totalMemory: Int {
    info.memoryUsage + children.reduce(0) { $0 + $1.info.memoryUsage }
  }

  /// Number of windows represented (self + children).
  var windowCount: Int { 1 + children.count }

  init(_ info: WindowInfo, children: [WindowNode] = []) {
    self.info = info
    self.children = children
  }
}

// MARK: - Controller

final class LogWindowController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var outlineView: NSOutlineView!
  private var statusLabel: NSTextField!
  private var autoRefreshTimer: Timer?
  private var snapshot: WindowSnapshot?

  /// Top-level tree nodes (one per PID group).
  private var rootNodes: [WindowNode] = []
  /// Fast lookup: windowNumber → WindowInfo
  private var windowByNumber: [UInt32: WindowInfo] = [:]
  /// PIDs whose group rows are currently expanded (persists across refreshes).
  private var expandedPIDs: Set<pid_t> = []

  private var sortDescriptorKey: String = "App"
  private var sortAscending: Bool = true

  private enum Column: String, CaseIterable {
    case app = "App"
    case window = "Window"
    case pid = "PID"
    // Actions inserted after PID programmatically
    case monitor = "Monitor"
    case space = "Space"
    case status = "Status"
    case position = "Position"
    case size = "Size"
    case memory = "Memory"
    case bundleID = "Bundle ID"

    var width: CGFloat {
      switch self {
      case .app: return 160
      case .window: return 220
      case .pid: return 60
      case .monitor: return 160
      case .space: return 50
      case .status: return 70
      case .position: return 100
      case .size: return 100
      case .memory: return 80
      case .bundleID: return 200
      }
    }

    var minWidth: CGFloat {
      switch self {
      case .pid, .space, .status: return 40
      case .position, .size, .memory: return 70
      default: return 80
      }
    }
  }

  private static let actionsColumnID = NSUserInterfaceItemIdentifier("Actions")

  // UserDefaults keys for persisting layout
  private static let udColumnWidths = "LogWindow.columnWidths"
  private static let udColumnOrder  = "LogWindow.columnOrder"
  private static let udSortKey      = "LogWindow.sortKey"
  private static let udSortAsc      = "LogWindow.sortAscending"

  // MARK: - Show / build window

  func showWindow() {
    if let existing = window, existing.isVisible {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      refresh()
      return
    }

    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    w.title = "WindowLock - Window Log"
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.minSize = NSSize(width: 750, height: 300)
    // Persist window frame across launches
    w.setFrameAutosaveName("WindowLockLogWindow")
    if !w.setFrameUsingName("WindowLockLogWindow") {
      w.center()
    }

    // Restore saved sort preferences
    let ud = UserDefaults.standard
    if let savedKey = ud.string(forKey: Self.udSortKey) {
      sortDescriptorKey = savedKey
      sortAscending = ud.bool(forKey: Self.udSortAsc)
    }

    let contentView = NSView(frame: w.contentView!.bounds)
    contentView.autoresizingMask = [.width, .height]

    let toolbar = buildToolbar(frame: NSRect(x: 0, y: contentView.bounds.height - 40, width: contentView.bounds.width, height: 40))
    contentView.addSubview(toolbar)

    let scrollView = NSScrollView(frame: NSRect(
      x: 0, y: 30,
      width: contentView.bounds.width,
      height: contentView.bounds.height - 70
    ))
    scrollView.autoresizingMask = [.width, .height]
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true

    outlineView = NSOutlineView(frame: scrollView.bounds)
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.usesAlternatingRowBackgroundColors = true
    outlineView.columnAutoresizingStyle = .noColumnAutoresizing
    outlineView.allowsColumnReordering = true
    outlineView.allowsColumnResizing = true
    outlineView.gridStyleMask = [.solidVerticalGridLineMask]
    outlineView.rowHeight = 24
    outlineView.style = .plain
    outlineView.intercellSpacing = NSSize(width: 8, height: 2)
    outlineView.indentationPerLevel = 18
    outlineView.autosaveExpandedItems = false

    // Columns: App, Window, PID, *Actions*, Monitor, Space, ...
    for col in Column.allCases {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
      column.title = col.rawValue
      column.width = col.width
      column.minWidth = col.minWidth
      column.isEditable = false

      let sortDesc = NSSortDescriptor(key: col.rawValue, ascending: true)
      column.sortDescriptorPrototype = sortDesc

      outlineView.addTableColumn(column)

      // The App column is the outline column (shows disclosure triangles)
      if col == .app {
        outlineView.outlineTableColumn = column
      }

      // Insert Actions right after PID
      if col == .pid {
        let actionsCol = NSTableColumn(identifier: Self.actionsColumnID)
        actionsCol.title = "Actions"
        actionsCol.width = 110
        actionsCol.minWidth = 110
        actionsCol.maxWidth = 110
        actionsCol.isEditable = false
        outlineView.addTableColumn(actionsCol)
      }
    }

    // Restore saved column widths
    if let savedWidths = ud.dictionary(forKey: Self.udColumnWidths) as? [String: CGFloat] {
      for col in outlineView.tableColumns {
        if let w = savedWidths[col.identifier.rawValue] {
          col.width = w
        }
      }
    }

    // Restore saved column order
    if let savedOrder = ud.stringArray(forKey: Self.udColumnOrder), !savedOrder.isEmpty {
      let currentIDs = outlineView.tableColumns.map { $0.identifier.rawValue }
      // Only restore if same set of columns (guards against version mismatch)
      if Set(savedOrder) == Set(currentIDs) {
        for (targetIdx, colID) in savedOrder.enumerated() {
          if let currentIdx = outlineView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colID }),
             currentIdx != targetIdx {
            outlineView.moveColumn(currentIdx, toColumn: targetIdx)
          }
        }
      }
    }

    // Apply restored sort descriptor to the outline view header
    outlineView.sortDescriptors = [NSSortDescriptor(key: sortDescriptorKey, ascending: sortAscending)]

    // Context menu
    let menu = NSMenu()
    menu.delegate = self
    outlineView.menu = menu

    scrollView.documentView = outlineView
    contentView.addSubview(scrollView)

    // Observe column resize and reorder for layout persistence
    NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize(_:)),
                                           name: NSTableView.columnDidResizeNotification, object: outlineView)
    NotificationCenter.default.addObserver(self, selector: #selector(columnDidMove(_:)),
                                           name: NSTableView.columnDidMoveNotification, object: outlineView)

    statusLabel = NSTextField(labelWithString: "")
    statusLabel.frame = NSRect(x: 10, y: 5, width: contentView.bounds.width - 20, height: 20)
    statusLabel.autoresizingMask = [.width]
    statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    statusLabel.textColor = .secondaryLabelColor
    contentView.addSubview(statusLabel)

    w.contentView = contentView
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.window = w
    refresh()
    startAutoRefresh()
  }

  // MARK: - Toolbar

  private func buildToolbar(frame: NSRect) -> NSView {
    let toolbar = NSView(frame: frame)
    toolbar.autoresizingMask = [.width, .minYMargin]

    let separator = NSBox(frame: NSRect(x: 0, y: 0, width: frame.width, height: 1))
    separator.boxType = .separator
    separator.autoresizingMask = [.width]
    toolbar.addSubview(separator)

    let refreshBtn = NSButton(frame: NSRect(x: 10, y: 6, width: 80, height: 28))
    refreshBtn.title = "Refresh"
    refreshBtn.bezelStyle = .rounded
    refreshBtn.target = self
    refreshBtn.action = #selector(handleRefresh)
    toolbar.addSubview(refreshBtn)

    let autoRefreshCheck = NSButton(checkboxWithTitle: "Auto-refresh (5s)", target: self, action: #selector(toggleAutoRefresh(_:)))
    autoRefreshCheck.frame = NSRect(x: 100, y: 8, width: 160, height: 24)
    autoRefreshCheck.state = .on
    toolbar.addSubview(autoRefreshCheck)

    let displaysLabel = NSTextField(labelWithString: "")
    displaysLabel.frame = NSRect(x: frame.width - 400, y: 10, width: 390, height: 20)
    displaysLabel.autoresizingMask = [.minXMargin]
    displaysLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    displaysLabel.textColor = .secondaryLabelColor
    displaysLabel.alignment = .right
    displaysLabel.tag = 100
    toolbar.addSubview(displaysLabel)

    return toolbar
  }

  // MARK: - Refresh & grouping

  func refresh() {
    let snap = WindowTracker.captureCurrentState()
    self.snapshot = snap
    rebuildTree()
    updateStatusBar()
    updateDisplaysLabel()
  }

  /// Group windows by PID, pick primary (titled) window, rest become children.
  private func rebuildTree() {
    guard let snapshot else { return }

    // Build lookup
    windowByNumber = [:]
    for w in snapshot.windows {
      windowByNumber[w.windowNumber] = w
    }

    // Group by PID
    var groups: [Int32: [WindowInfo]] = [:]
    for w in snapshot.windows {
      groups[w.pid, default: []].append(w)
    }

    // Build nodes
    var nodes: [WindowNode] = []
    for (_, windows) in groups {
      guard !windows.isEmpty else { continue }

      if windows.count == 1 {
        // Single window — flat row, no children
        nodes.append(WindowNode(windows[0]))
      } else {
        // Multiple windows — pick the best primary
        let sorted = windows.sorted { a, b in
          // Prefer: titled > untitled, on-screen > hidden, larger area > smaller
          if !a.windowTitle.isEmpty && b.windowTitle.isEmpty { return true }
          if a.windowTitle.isEmpty && !b.windowTitle.isEmpty { return false }
          if a.isOnScreen && !b.isOnScreen { return true }
          if !a.isOnScreen && b.isOnScreen { return false }
          return (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
        }
        let primary = sorted[0]
        let children = sorted.dropFirst().map { WindowNode($0) }
        nodes.append(WindowNode(primary, children: children))
      }
    }

    // Sort root nodes
    nodes.sort { a, b in
      let result: Bool
      switch sortDescriptorKey {
      case "App": result = a.info.ownerName.localizedCaseInsensitiveCompare(b.info.ownerName) == .orderedAscending
      case "Window": result = a.info.windowTitle.localizedCaseInsensitiveCompare(b.info.windowTitle) == .orderedAscending
      case "PID": result = a.info.pid < b.info.pid
      case "Monitor": result = a.info.displayName.localizedCaseInsensitiveCompare(b.info.displayName) == .orderedAscending
      case "Space": result = a.info.spaceIndex < b.info.spaceIndex
      case "Status": result = a.info.isOnScreen && !b.info.isOnScreen
      case "Memory": result = a.totalMemory < b.totalMemory
      case "Bundle ID": result = a.info.bundleID.localizedCaseInsensitiveCompare(b.info.bundleID) == .orderedAscending
      default: result = a.info.ownerName.localizedCaseInsensitiveCompare(b.info.ownerName) == .orderedAscending
      }
      return sortAscending ? result : !result
    }

    rootNodes = nodes
    outlineView?.reloadData()

    // Restore previously expanded groups
    for node in rootNodes where node.isGroup && expandedPIDs.contains(node.info.pid) {
      outlineView?.expandItem(node)
    }
  }

  private func updateStatusBar() {
    guard let snapshot else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let totalMem = snapshot.windows.reduce(0) { $0 + $1.memoryUsage }
    let memStr = ByteCountFormatter.string(fromByteCount: Int64(totalMem), countStyle: .memory)
    let spacesUsed = Set(snapshot.windows.map { $0.spaceIndex }).filter { $0 > 0 }.sorted()
    let spaceStr = spacesUsed.isEmpty ? "N/A" : spacesUsed.map(String.init).joined(separator: ",")
    let onScreen = snapshot.windows.filter { $0.isOnScreen }.count
    statusLabel?.stringValue = "\(snapshot.windows.count) windows (\(onScreen) visible)  |  \(rootNodes.count) apps  |  Spaces: \(spaceStr)  |  Memory: \(memStr)  |  \(formatter.string(from: snapshot.capturedAt))"
  }

  private func updateDisplaysLabel() {
    guard let snapshot else { return }
    guard let toolbar = window?.contentView?.subviews.first(where: { $0.frame.height == 40 }) else { return }
    guard let label = toolbar.viewWithTag(100) as? NSTextField else { return }

    let displayInfo = snapshot.displays.enumerated().map { (_, d) in
      let mainTag = d.isMain ? " (main)" : ""
      return "\(d.name)\(mainTag): \(Int(d.bounds.width))x\(Int(d.bounds.height))"
    }.joined(separator: "  |  ")

    label.stringValue = displayInfo
  }

  // MARK: - Timer

  private func startAutoRefresh() {
    stopAutoRefresh()
    autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    autoRefreshTimer?.tolerance = 1.0
  }

  private func stopAutoRefresh() {
    autoRefreshTimer?.invalidate()
    autoRefreshTimer = nil
  }

  @objc private func handleRefresh() { refresh() }

  @objc private func toggleAutoRefresh(_ sender: NSButton) {
    if sender.state == .on { startAutoRefresh() } else { stopAutoRefresh() }
  }

  // MARK: - Helpers

  /// Extract the WindowInfo from an outline view item (node or child node).
  private func windowInfo(for item: Any?) -> WindowInfo? {
    (item as? WindowNode)?.info
  }

  /// Get WindowInfo for the clicked row in the outline view.
  private func windowInfoForClickedRow() -> WindowInfo? {
    let row = outlineView.clickedRow
    guard row >= 0, let item = outlineView.item(atRow: row) else { return nil }
    return windowInfo(for: item)
  }

  /// Get WindowInfo for a windowNumber stored in a button/menu tag.
  private func windowInfoByNumber(_ number: Int) -> WindowInfo? {
    windowByNumber[UInt32(number)]
  }

  // MARK: - Window actions

  private func activateWindow(_ win: WindowInfo) {
    guard let app = NSRunningApplication(processIdentifier: win.pid) else {
      Log.warn("Cannot activate: no running app for pid \(win.pid)")
      return
    }

    // Move off-screen window to active space so it appears immediately
    if !win.isOnScreen, win.windowNumber > 0, SpaceManager.isAvailable {
      if let activeSpaceID = SpaceManager.activeSpaceID() {
        let moved = SpaceManager.moveWindow(windowID: win.windowNumber, toSpaceID: activeSpaceID)
        if moved {
          Log.info("Moved window \(win.windowNumber) to active space for display")
        }
      }
    }

    app.activate(options: [.activateIgnoringOtherApps])

    // Raise the specific window via AX
    let axApp = AXUIElementCreateApplication(win.pid)
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { return }

    var target: AXUIElement?
    if win.windowNumber > 0 {
      target = axWindows.first { SpaceManager.windowID(from: $0) == win.windowNumber }
    }
    if target == nil, !win.windowTitle.isEmpty {
      target = axWindows.first { axWin in
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
        return (titleRef as? String) == win.windowTitle
      }
    }
    if target == nil, win.windowIndex < axWindows.count {
      target = axWindows[win.windowIndex]
    }
    if target == nil { target = axWindows.first }

    if let axWindow = target {
      AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }
  }

  private func revealInFinder(_ win: WindowInfo) {
    guard let app = NSRunningApplication(processIdentifier: win.pid),
          let url = app.bundleURL else {
      if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: win.bundleID) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appURL.path)
      }
      return
    }
    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
  }

  private func openTerminal(_ win: WindowInfo) {
    let dirPath: String
    if let app = NSRunningApplication(processIdentifier: win.pid),
       let url = app.bundleURL {
      dirPath = url.deletingLastPathComponent().path
    } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: win.bundleID) {
      dirPath = appURL.deletingLastPathComponent().path
    } else {
      dirPath = NSHomeDirectory()
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-a", "Terminal", dirPath]
    do { try task.run() } catch {
      Log.warn("Failed to open Terminal at \(dirPath): \(error)")
    }
  }

  private func killApp(_ win: WindowInfo) {
    guard let app = NSRunningApplication(processIdentifier: win.pid) else { return }

    let alert = NSAlert()
    alert.messageText = "Force Quit \(win.ownerName)?"
    alert.informativeText = "PID \(win.pid) — \(win.bundleID)\nUnsaved work in this app will be lost."
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Force Quit")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let success = app.forceTerminate()
    if success {
      Log.info("Force-terminated \(win.ownerName) (pid \(win.pid))")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.refresh()
      }
    } else {
      Log.warn("Failed to force-terminate \(win.ownerName)")
    }
  }

  // MARK: - Button handlers (tag = windowNumber)

  @objc private func handleAppNameClick(_ sender: NSButton) {
    guard let win = windowInfoByNumber(sender.tag) else { return }
    activateWindow(win)
  }

  @objc private func handleActionButton(_ sender: NSButton) {
    guard let win = windowInfoByNumber(sender.tag) else { return }
    switch sender.identifier?.rawValue {
    case "action_show":    activateWindow(win)
    case "action_finder":  revealInFinder(win)
    case "action_term":    openTerminal(win)
    case "action_kill":    killApp(win)
    default: break
    }
  }

  // MARK: - NSOutlineViewDataSource

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if item == nil { return rootNodes.count }
    if let node = item as? WindowNode { return node.children.count }
    return 0
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if item == nil { return rootNodes[index] }
    return (item as! WindowNode).children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? WindowNode)?.isGroup ?? false
  }

  func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    guard let descriptor = outlineView.sortDescriptors.first else { return }
    sortDescriptorKey = descriptor.key ?? "App"
    sortAscending = descriptor.ascending
    saveColumnLayout()
    rebuildTree()
  }

  // MARK: - NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let colID = tableColumn?.identifier,
          let node = item as? WindowNode else { return nil }
    let win = node.info
    let isChild = outlineView.parent(forItem: item) != nil

    // --- Actions column ---
    if colID == Self.actionsColumnID {
      return makeActionsCell(win: win)
    }

    let id = colID.rawValue

    // --- App column: clickable link (only for root nodes) ---
    if id == "App" {
      return makeAppNameCell(node: node, isChild: isChild)
    }

    // --- Data columns ---
    let cellID = NSUserInterfaceItemIdentifier("Cell_\(id)")
    let cell: NSTableCellView

    if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
      cell = reused
    } else {
      cell = NSTableCellView()
      cell.identifier = cellID
      let tf = NSTextField(labelWithString: "")
      tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
      tf.lineBreakMode = .byTruncatingTail
      tf.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(tf)
      cell.textField = tf
      NSLayoutConstraint.activate([
        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }

    let text: String
    switch id {
    case "Window":
      if isChild {
        text = win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle
      } else if node.isGroup {
        // Show primary title + child count
        let title = win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle
        text = "\(title)  +\(node.children.count) more"
      } else {
        text = win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle
      }
    case "PID":
      text = isChild ? "" : "\(win.pid)"
    case "Monitor":
      text = win.displayName
    case "Space":
      text = win.spaceIndex > 0 ? "\(win.spaceIndex)" : (win.spaceNumber > 0 ? "\(win.spaceNumber)" : "--")
    case "Status":
      text = win.isOnScreen ? "visible" : "hidden"
    case "Position":
      text = "\(Int(win.frame.x)), \(Int(win.frame.y))"
    case "Size":
      text = "\(Int(win.frame.width)) x \(Int(win.frame.height))"
    case "Memory":
      if isChild {
        text = ByteCountFormatter.string(fromByteCount: Int64(win.memoryUsage), countStyle: .memory)
      } else {
        text = ByteCountFormatter.string(fromByteCount: Int64(node.totalMemory), countStyle: .memory)
      }
    case "Bundle ID":
      text = isChild ? "" : win.bundleID
    default:
      text = ""
    }

    cell.textField?.stringValue = text

    if !win.isOnScreen {
      cell.textField?.textColor = .secondaryLabelColor
    } else if id == "Window" && win.windowTitle.isEmpty {
      cell.textField?.textColor = .tertiaryLabelColor
    } else {
      cell.textField?.textColor = .labelColor
    }

    // Dim the "+N more" suffix
    if id == "Window", !isChild, node.isGroup {
      cell.textField?.textColor = .secondaryLabelColor
    }

    return cell
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    if let node = notification.userInfo?["NSObject"] as? WindowNode {
      expandedPIDs.insert(node.info.pid)
    }
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    if let node = notification.userInfo?["NSObject"] as? WindowNode {
      expandedPIDs.remove(node.info.pid)
    }
  }

  // MARK: - Cell builders

  private func makeAppNameCell(node: WindowNode, isChild: Bool) -> NSView {
    let container = NSView()
    let win = node.info

    let btn = NSButton(frame: .zero)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.isBordered = false
    btn.setButtonType(.momentaryPushIn)
    btn.alignment = .left
    btn.tag = Int(win.windowNumber)
    btn.target = self
    btn.action = #selector(handleAppNameClick(_:))
    btn.toolTip = "Click to show \(win.ownerName)"

    let title: String
    if isChild {
      title = win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle
    } else if node.isGroup {
      title = "\(win.ownerName) (\(node.windowCount))"
    } else {
      title = win.ownerName
    }

    let color: NSColor = win.isOnScreen ? .controlAccentColor : .secondaryLabelColor
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 12, weight: isChild ? .regular : .medium),
      .foregroundColor: color,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    btn.attributedTitle = NSAttributedString(string: title, attributes: attrs)

    // App icon for root nodes only
    if !isChild,
       let app = NSRunningApplication(processIdentifier: win.pid),
       let icon = app.icon {
      let smallIcon = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
        icon.draw(in: rect)
        return true
      }
      btn.image = smallIcon
      btn.imagePosition = .imageLeft
      btn.imageHugsTitle = true
    }

    container.addSubview(btn)
    NSLayoutConstraint.activate([
      btn.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
      btn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
      btn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    return container
  }

  private func makeActionsCell(win: WindowInfo) -> NSView {
    let container = NSView()

    let buttons: [(id: String, icon: String, tooltip: String)] = [
      ("action_show",   "eye",               "Show Window"),
      ("action_finder", "folder",            "Reveal in Finder"),
      ("action_term",   "terminal",          "Open Terminal"),
      ("action_kill",   "xmark.circle.fill", "Force Quit"),
    ]

    let btnSize: CGFloat = 22
    let spacing: CGFloat = 4
    var x: CGFloat = 4

    for def in buttons {
      let btn = NSButton(frame: NSRect(x: x, y: 1, width: btnSize, height: btnSize))
      btn.bezelStyle = .recessed
      btn.isBordered = false
      btn.setButtonType(.momentaryPushIn)
      btn.identifier = NSUserInterfaceItemIdentifier(def.id)
      btn.tag = Int(win.windowNumber)
      btn.target = self
      btn.action = #selector(handleActionButton(_:))
      btn.toolTip = def.tooltip

      if let img = NSImage(systemSymbolName: def.icon, accessibilityDescription: def.tooltip) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        btn.image = img.withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
      }

      btn.contentTintColor = def.id == "action_kill" ? .systemRed : .secondaryLabelColor
      container.addSubview(btn)
      x += btnSize + spacing
    }

    return container
  }

  // MARK: - Layout persistence

  private func saveColumnLayout() {
    guard let outlineView else { return }
    let ud = UserDefaults.standard

    // Save column widths
    var widths: [String: CGFloat] = [:]
    for col in outlineView.tableColumns {
      widths[col.identifier.rawValue] = col.width
    }
    ud.set(widths, forKey: Self.udColumnWidths)

    // Save column order
    let order = outlineView.tableColumns.map { $0.identifier.rawValue }
    ud.set(order, forKey: Self.udColumnOrder)

    // Save sort preferences
    ud.set(sortDescriptorKey, forKey: Self.udSortKey)
    ud.set(sortAscending, forKey: Self.udSortAsc)
  }

  @objc private func columnDidResize(_ notification: Notification) {
    saveColumnLayout()
  }

  @objc private func columnDidMove(_ notification: Notification) {
    saveColumnLayout()
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    saveColumnLayout()
    stopAutoRefresh()
  }
}

// MARK: - NSMenuDelegate (right-click context menu)

extension LogWindowController: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    guard let win = windowInfoForClickedRow() else { return }

    let header = NSMenuItem(title: "\(win.ownerName) — \(win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle)", action: nil, keyEquivalent: "")
    header.isEnabled = false
    if let app = NSRunningApplication(processIdentifier: win.pid),
       let icon = app.icon {
      let resized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        icon.draw(in: rect)
        return true
      }
      header.image = resized
    }
    menu.addItem(header)
    menu.addItem(NSMenuItem.separator())

    let wn = Int(win.windowNumber)

    let showItem = NSMenuItem(title: "Show Window", action: #selector(contextAction(_:)), keyEquivalent: "")
    showItem.target = self
    showItem.tag = wn
    showItem.representedObject = "show" as NSString
    if let img = NSImage(systemSymbolName: "eye", accessibilityDescription: nil) { showItem.image = img }
    menu.addItem(showItem)

    let finderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextAction(_:)), keyEquivalent: "")
    finderItem.target = self
    finderItem.tag = wn
    finderItem.representedObject = "finder" as NSString
    if let img = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) { finderItem.image = img }
    menu.addItem(finderItem)

    let termItem = NSMenuItem(title: "Open Terminal Here", action: #selector(contextAction(_:)), keyEquivalent: "")
    termItem.target = self
    termItem.tag = wn
    termItem.representedObject = "term" as NSString
    if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) { termItem.image = img }
    menu.addItem(termItem)

    menu.addItem(NSMenuItem.separator())

    // Copy submenu
    let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
    let copyMenu = NSMenu()
    let copyPID = NSMenuItem(title: "PID: \(win.pid)", action: #selector(contextCopy(_:)), keyEquivalent: "")
    copyPID.target = self; copyPID.representedObject = "\(win.pid)"
    copyMenu.addItem(copyPID)
    let copyBundle = NSMenuItem(title: "Bundle ID: \(win.bundleID)", action: #selector(contextCopy(_:)), keyEquivalent: "")
    copyBundle.target = self; copyBundle.representedObject = win.bundleID
    copyMenu.addItem(copyBundle)
    if let app = NSRunningApplication(processIdentifier: win.pid), let url = app.bundleURL {
      let copyPath = NSMenuItem(title: "Path: \(url.path)", action: #selector(contextCopy(_:)), keyEquivalent: "")
      copyPath.target = self; copyPath.representedObject = url.path
      copyMenu.addItem(copyPath)
    }
    copyItem.submenu = copyMenu
    menu.addItem(copyItem)

    menu.addItem(NSMenuItem.separator())

    let killItem = NSMenuItem(title: "Force Quit \(win.ownerName)", action: #selector(contextAction(_:)), keyEquivalent: "")
    killItem.target = self
    killItem.tag = wn
    killItem.representedObject = "kill" as NSString
    if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) { killItem.image = img }
    menu.addItem(killItem)
  }

  @objc private func contextAction(_ sender: NSMenuItem) {
    guard let win = windowInfoByNumber(sender.tag),
          let action = sender.representedObject as? String else { return }
    switch action {
    case "show":   activateWindow(win)
    case "finder": revealInFinder(win)
    case "term":   openTerminal(win)
    case "kill":   killApp(win)
    default: break
    }
  }

  @objc private func contextCopy(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
