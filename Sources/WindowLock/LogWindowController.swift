import AppKit

final class LogWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var tableView: NSTableView!
  private var statusLabel: NSTextField!
  private var autoRefreshTimer: Timer?
  private var snapshot: WindowSnapshot?
  private var sortedWindows: [WindowInfo] = []
  private var sortDescriptorKey: String = "ownerName"
  private var sortAscending: Bool = true

  private enum Column: String, CaseIterable {
    case app = "App"
    case window = "Window"
    case pid = "PID"
    case monitor = "Monitor"
    case space = "Space"
    case position = "Position"
    case size = "Size"
    case memory = "Memory"
    case bundleID = "Bundle ID"

    var width: CGFloat {
      switch self {
      case .app: return 140
      case .window: return 220
      case .pid: return 60
      case .monitor: return 160
      case .space: return 50
      case .position: return 100
      case .size: return 100
      case .memory: return 80
      case .bundleID: return 200
      }
    }

    var minWidth: CGFloat {
      switch self {
      case .pid, .space: return 40
      case .position, .size, .memory: return 70
      default: return 80
      }
    }
  }

  func showWindow() {
    if let existing = window, existing.isVisible {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      refresh()
      return
    }

    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    w.title = "WindowLock - Window Log"
    w.center()
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.minSize = NSSize(width: 700, height: 300)

    let contentView = NSView(frame: w.contentView!.bounds)
    contentView.autoresizingMask = [.width, .height]

    // Toolbar area
    let toolbar = buildToolbar(frame: NSRect(x: 0, y: contentView.bounds.height - 40, width: contentView.bounds.width, height: 40))
    contentView.addSubview(toolbar)

    // Table scroll view
    let scrollView = NSScrollView(frame: NSRect(
      x: 0, y: 30,
      width: contentView.bounds.width,
      height: contentView.bounds.height - 70
    ))
    scrollView.autoresizingMask = [.width, .height]
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true

    tableView = NSTableView(frame: scrollView.bounds)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.allowsColumnReordering = true
    tableView.allowsColumnResizing = true
    tableView.gridStyleMask = [.solidVerticalGridLineMask]
    tableView.rowHeight = 22
    tableView.style = .plain
    tableView.intercellSpacing = NSSize(width: 8, height: 2)

    for col in Column.allCases {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
      column.title = col.rawValue
      column.width = col.width
      column.minWidth = col.minWidth
      column.isEditable = false

      let sortDesc = NSSortDescriptor(key: col.rawValue, ascending: true)
      column.sortDescriptorPrototype = sortDesc

      tableView.addTableColumn(column)
    }

    scrollView.documentView = tableView

    contentView.addSubview(scrollView)

    // Status bar at bottom
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

  private func buildToolbar(frame: NSRect) -> NSView {
    let toolbar = NSView(frame: frame)
    toolbar.autoresizingMask = [.width, .minYMargin]

    // Separator line at bottom
    let separator = NSBox(frame: NSRect(x: 0, y: 0, width: frame.width, height: 1))
    separator.boxType = .separator
    separator.autoresizingMask = [.width]
    toolbar.addSubview(separator)

    // Refresh button
    let refreshBtn = NSButton(frame: NSRect(x: 10, y: 6, width: 80, height: 28))
    refreshBtn.title = "Refresh"
    refreshBtn.bezelStyle = .rounded
    refreshBtn.target = self
    refreshBtn.action = #selector(handleRefresh)
    toolbar.addSubview(refreshBtn)

    // Auto-refresh checkbox
    let autoRefreshCheck = NSButton(checkboxWithTitle: "Auto-refresh (5s)", target: self, action: #selector(toggleAutoRefresh(_:)))
    autoRefreshCheck.frame = NSRect(x: 100, y: 8, width: 160, height: 24)
    autoRefreshCheck.state = .on
    toolbar.addSubview(autoRefreshCheck)

    // Displays info (right side)
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

  func refresh() {
    let snap = WindowTracker.captureCurrentState()
    self.snapshot = snap
    sortAndReload()
    updateStatusBar()
    updateDisplaysLabel()
  }

  private func sortAndReload() {
    guard let snapshot else { return }
    sortedWindows = snapshot.windows.sorted { a, b in
      let result: Bool
      switch sortDescriptorKey {
      case "App": result = a.ownerName.localizedCaseInsensitiveCompare(b.ownerName) == .orderedAscending
      case "Window": result = a.windowTitle.localizedCaseInsensitiveCompare(b.windowTitle) == .orderedAscending
      case "PID": result = a.pid < b.pid
      case "Monitor": result = a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
      case "Space": result = a.spaceNumber < b.spaceNumber
      case "Memory": result = a.memoryUsage < b.memoryUsage
      case "Bundle ID": result = a.bundleID.localizedCaseInsensitiveCompare(b.bundleID) == .orderedAscending
      default: result = a.ownerName.localizedCaseInsensitiveCompare(b.ownerName) == .orderedAscending
      }
      return sortAscending ? result : !result
    }
    tableView?.reloadData()
  }

  private func updateStatusBar() {
    guard let snapshot else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let totalMem = snapshot.windows.reduce(0) { $0 + $1.memoryUsage }
    let memStr = ByteCountFormatter.string(fromByteCount: Int64(totalMem), countStyle: .memory)
    statusLabel?.stringValue = "\(snapshot.windows.count) windows  |  \(snapshot.displays.count) displays  |  Total memory: \(memStr)  |  Captured: \(formatter.string(from: snapshot.capturedAt))"
  }

  private func updateDisplaysLabel() {
    guard let snapshot else { return }
    guard let toolbar = window?.contentView?.subviews.first(where: { $0.frame.height == 40 }) else { return }
    guard let label = toolbar.viewWithTag(100) as? NSTextField else { return }

    let displayInfo = snapshot.displays.enumerated().map { (i, d) in
      let mainTag = d.isMain ? " (main)" : ""
      return "\(d.name)\(mainTag): \(Int(d.bounds.width))x\(Int(d.bounds.height))"
    }.joined(separator: "  |  ")

    label.stringValue = displayInfo
  }

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

  @objc private func handleRefresh() {
    refresh()
  }

  @objc private func toggleAutoRefresh(_ sender: NSButton) {
    if sender.state == .on {
      startAutoRefresh()
    } else {
      stopAutoRefresh()
    }
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int {
    sortedWindows.count
  }

  func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    guard let descriptor = tableView.sortDescriptors.first else { return }
    sortDescriptorKey = descriptor.key ?? "App"
    sortAscending = descriptor.ascending
    sortAndReload()
  }

  // MARK: - NSTableViewDelegate

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let id = tableColumn?.identifier.rawValue, row < sortedWindows.count else { return nil }
    let win = sortedWindows[row]

    let cellID = NSUserInterfaceItemIdentifier("Cell_\(id)")
    let cell: NSTableCellView

    if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
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
    case "App":
      text = win.ownerName
    case "Window":
      text = win.windowTitle.isEmpty ? "(untitled)" : win.windowTitle
    case "PID":
      text = "\(win.pid)"
    case "Monitor":
      text = win.displayName
    case "Space":
      text = win.spaceNumber > 0 ? "\(win.spaceNumber)" : "--"
    case "Position":
      text = "\(Int(win.frame.x)), \(Int(win.frame.y))"
    case "Size":
      text = "\(Int(win.frame.width)) x \(Int(win.frame.height))"
    case "Memory":
      text = ByteCountFormatter.string(fromByteCount: Int64(win.memoryUsage), countStyle: .memory)
    case "Bundle ID":
      text = win.bundleID
    default:
      text = ""
    }

    cell.textField?.stringValue = text
    cell.textField?.textColor = id == "Window" && win.windowTitle.isEmpty ? .tertiaryLabelColor : .labelColor
    return cell
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    stopAutoRefresh()
  }
}
