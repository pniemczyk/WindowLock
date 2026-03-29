# WindowLock

**Your windows. Your monitors. Your layout. Every single time.**

You know the feeling. You open your laptop, connect your monitors, and every window is piled on top of each other on your main display. Slack is gone. Your terminal is gone. That carefully arranged three-monitor setup you spent ten minutes perfecting? Gone. macOS just doesn't care.

Or maybe you switch between setups throughout the day — coding layout, meeting layout, deep work layout — and you're tired of dragging windows around like it's 2005.

WindowLock fixes this. It's a tiny, silent menu bar app that remembers where every window belongs and puts it back. After sleep, after restart, after your cat walks across the keyboard and unplugs your monitor. One click to save a layout. One click to restore it. No configuration files. No learning curve. It just works.

Small. Simple. Set it and forget it.

## The Problem

macOS frequently rearranges windows after:
- Waking from sleep
- Restarting
- Disconnecting/reconnecting external monitors

All windows get piled onto the primary display, losing their carefully arranged positions across multiple monitors. Every. Single. Time.

## How It Works

1. **Captures** window positions every 30 seconds and immediately before sleep — across all Spaces and monitors, not just the active one
2. **Stores** state as JSON in `~/Library/Application Support/WindowLock/`
3. **Restores** windows to their saved positions, sizes, monitors, and Spaces after wake, display changes, or app launches
4. **Matches** displays by resolution and arrangement (not display IDs, which macOS reassigns after sleep)
5. **Matches** windows by CGWindowID first, then exact title — skips anything it can't confidently identify to avoid moving the wrong window
6. **Runs** silently in the background with a menu bar icon (no Dock icon)

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ (included with Xcode 15+)
- **Accessibility permissions** (required for restoring window positions and reading window titles)

## Install

### Using the Installer (.pkg)

Download or build the `WindowLock-1.2.1.pkg` installer and double-click to install.

Since this app is ad-hoc signed (no Apple Developer ID), macOS may block it:
- Right-click the `.pkg` > **Open**, or
- Run: `xattr -cr WindowLock-1.2.1.pkg`

The installer places `WindowLock.app` in `/Applications` and configures auto-start on login.

To build the installer from source:

```bash
chmod +x Scripts/build-installer.sh
./Scripts/build-installer.sh
# Output: .build/WindowLock-1.2.1.pkg
```

### From the command line

```bash
chmod +x Scripts/install.sh
./Scripts/install.sh
```

This will:
1. Build the release binary
2. Install `WindowLock.app` to `/Applications`
3. Install and start the LaunchAgent (auto-runs on login)

### Grant Accessibility Access

**Required** - without this, WindowLock can capture window state but cannot restore positions or read window titles.

1. Open **System Settings > Privacy & Security > Accessibility**
2. Click **+** and add `/usr/local/bin/windowlock`
3. Enable the toggle
4. Restart WindowLock (Quit from menu, it will restart on next login, or run `./Scripts/install.sh` again)

## Uninstall

### From the menu bar

Click the WindowLock icon > **Uninstall WindowLock...** > confirm. This will:
- Stop the background daemon
- Remove the LaunchAgent (no auto-start on login)
- Remove the binary from `/usr/local/bin/`
- Prompt for your password (needed to delete from `/usr/local/bin/`)

Saved layouts and state data are preserved.

### From the command line

```bash
# Uninstall (keeps saved data)
chmod +x Scripts/uninstall.sh
./Scripts/uninstall.sh

# Uninstall and remove all saved data (layouts, state, logs)
./Scripts/uninstall.sh --purge
```

### Manual uninstall

If the scripts are not available:

```bash
# 1. Stop the daemon
launchctl bootout "gui/$(id -u)/com.way2do.windowlock.plist"

# 2. Remove the LaunchAgent
rm ~/Library/LaunchAgents/com.way2do.windowlock.plist

# 3. Remove the binary
sudo rm /usr/local/bin/windowlock

# 4. (Optional) Remove saved data
rm -rf ~/Library/Application\ Support/WindowLock

# 5. (Optional) Remove logs
rm -rf ~/Library/Logs/WindowLock

# 6. (Optional) Remove Accessibility entry
#    System Settings > Privacy & Security > Accessibility
#    Select windowlock and click -
```

## Usage

WindowLock runs automatically after installation with a menu bar icon.

### Menu Bar

A window icon appears in the macOS menu bar:

```
Windows: 15 (7 visible)
Displays: 3
Spaces: 19 total, 9 with windows
Last capture: 14:32:05
─────────────────────────
Show Window Log...    ⌘L
─────────────────────────
Restore Last State    ⌘R
Capture Now           ⌘C
─────────────────────────
Save Layout As...     ⌘S
─────────────────────────
  Work Setup
  Presentation
  Coding
Manage Layouts          ▸
─────────────────────────
Configuration           ▸
  ✓ Launch at Login
  ─────────────────────
  Debug Mode          ⌘D
  ─────────────────────
  Logs                  ▸
    Log file size: 42 KB
    ─────────────────────
    Clear Log File...
    Open Logs Folder
  ─────────────────────
  Permissions           ▸
  ─────────────────────
  Uninstall WindowLock...
─────────────────────────
About WindowLock
─────────────────────────
Quit WindowLock       ⌘Q
```

### Saved Layouts

Save your window arrangement with a custom name and restore it with one click directly from the menu.

**To save:**
1. Arrange your windows how you want them
2. Click the WindowLock icon > **Save Layout As...**
3. Enter a name (e.g., "Work Setup", "Presentation", "Coding")

**To restore:** click the layout name directly in the menu - it restores immediately. Layout names appear as top-level items for one-click access.

**To manage:** open the **Manage Layouts** submenu to:
- **Overwrite with Current** - instantly update a layout with current window positions (no confirmation)
- **Rename...** - change a layout name
- **Delete** - remove a saved layout

### Debug Mode

Toggle **Debug Mode** (Cmd+D) under **Configuration** to surface restore diagnostics. When enabled:

- After each restore operation, an alert shows the restore summary in a selectable, copyable text field: how many windows were saved, matched, moved, and which ones failed
- A **Show Full Log** button opens a scrollable view of all recent log entries
- If Accessibility access is denied, an **Open Accessibility Settings** button takes you directly to the correct System Settings pane

This is useful for troubleshooting when windows don't move to their expected positions.

### Window Log

The Window Log provides a detailed, interactive view of every tracked window across all Spaces and monitors, similar to Activity Monitor. Open it via **Show Window Log...** (Cmd+L).

| Column | Description |
|---|---|
| App | Application name (clickable — activates and shows the window) |
| Window | Window title |
| PID | Process ID |
| Actions | Show, Reveal in Finder, Open Terminal, Force Quit buttons |
| Monitor | Display name (e.g., "LG ULTRAGEAR+", "Built-in Retina Display") |
| Space | Virtual desktop / Space number |
| Status | Visible or hidden (on another Space) |
| Position | Absolute screen coordinates (x, y) |
| Size | Window dimensions (width x height) |
| Memory | Window buffer memory usage |
| Bundle ID | Application bundle identifier |

**Interactive features:**
- **Click app name** to activate and show that window (switches Space if needed)
- **Action buttons** with SF Symbol icons and tooltips:
  - 👁 **Show** — bring window to the current Space and focus it
  - 📁 **Reveal in Finder** — open the app's bundle location
  - 💻 **Open Terminal** — open Terminal.app in the app's directory
  - ✕ **Force Quit** — terminate the app (requires confirmation)
- **Right-click context menu** — all actions plus Copy (PID, Bundle ID, Path)
- **Tree grouping** — apps with multiple windows (e.g., Chrome, Mail) are grouped under expandable parent rows; click the disclosure triangle to see individual windows
- **Persistent layout** — window size, position, column widths, column order, and sort state are remembered across sessions
- Click any column header to sort
- Auto-refresh every 5 seconds (toggleable; expanded groups stay expanded)
- Status bar showing total window count, app count, spaces, and memory
- Display info bar showing connected monitors with resolutions

### Permissions

WindowLock needs macOS permissions to function fully. The **Permissions** submenu in the menu bar shows the live status of each permission and lets you open the relevant System Settings pane directly.

| Permission | Required | What it enables |
|---|---|---|
| **Accessibility** | Yes | Move/resize windows, read window titles via AX API |
| **Screen Recording** | No (optional) | Read window titles via CGWindowList (AX API is used as fallback) |

The submenu shows:
- Status icon for each permission (granted/missing)
- Hover over any permission to see details and **open its Settings pane** directly
- **Refresh Permissions** - re-check all permissions and show a summary dialog
- **Open All Permission Settings...** - opens both Accessibility and Screen Recording settings panes

After granting or revoking permissions in System Settings, use **Refresh Permissions** to verify the changes took effect. Some permission changes require restarting WindowLock.

### CLI Commands

```bash
# Capture current window state and print as JSON
windowlock --capture-only

# Restore windows from last auto-saved state
windowlock --restore

# Run as daemon with custom interval (seconds)
windowlock --interval 15

# Run without menu bar icon (headless)
windowlock --no-menubar
```

**Layout management from the command line:**

```bash
# Save current window arrangement with a name
windowlock --save-layout "Work Setup"

# Restore a saved layout by name
windowlock --restore-layout "Work Setup"

# List all saved layouts
windowlock --list-layouts

# Delete a saved layout
windowlock --delete-layout "Work Setup"
```

### Logs

All log output is written to `~/Library/Logs/WindowLock/windowlock.log`. You can view it live or manage it via the menu:

```bash
# View live logs
tail -f ~/Library/Logs/WindowLock/windowlock.log
```

Or use the **Logs** submenu under **Configuration** to:
- See the current log file size
- **Clear Log File** — truncate the file (with confirmation)
- **Open Logs Folder** — open `~/Library/Logs/WindowLock/` in Finder

### Launch at Login

Toggle **Launch at Login** under **Configuration** to have WindowLock start automatically when you log in. This installs or removes a LaunchAgent at `~/Library/LaunchAgents/com.way2do.windowlock.plist` pointing to the current binary. No restart required — the change takes effect immediately.

## How Display Matching Works

After sleep/wake, macOS assigns new display IDs. WindowLock handles this by:

1. Storing window positions **relative to their display's origin** (not absolute screen coordinates)
2. Matching old displays to new ones by **resolution and main-display flag**
3. If a display is missing, its windows are skipped (macOS already moved them)

This means your windows are restored to the correct monitor even when display IDs change.

## How Space Tracking Works

WindowLock uses macOS private CGS APIs (the same ones used by yabai, Amethyst, and other window managers) to track and restore windows across virtual desktops:

1. **Enumerates all Spaces** across all displays via `CGSCopyManagedDisplaySpaces`
2. **Queries each window's Space** via `CGSCopySpacesForWindows` with the "all spaces" bitmask
3. **Moves windows between Spaces** via `CGSMoveWindowsToManagedSpace` during restore
4. **Maps display UUIDs** from CGS to `CGDirectDisplayID` for accurate cross-display tracking

This means WindowLock captures and restores the complete state — even windows on Spaces you're not currently viewing.

## How Window Matching Works

Windows are matched between saved state and current state using a strict 3-pass approach. The goal is **high confidence** — if a window can't be identified with certainty, it is skipped rather than guessed (preventing wrong-window restoration in multi-window apps like Chrome or Mail).

1. **CGWindowID match** — the kernel-level window identifier, unique per window and stable as long as the window exists. This handles sleep/wake, Space changes, and display reconnections perfectly.
2. **Exact title + exact size** — for windows recreated after an app restart where the CGWindowID changed but the title and dimensions are the same.
3. **Unique exact title** — only matches when exactly one saved window and one current window share the same non-empty title within that app. Ambiguous titles (e.g., multiple "(untitled)" windows) are skipped.

When restoring, each matched window goes through:
- **Space restoration** — move to the correct virtual desktop first
- **Position-size-position** sequence — move to the correct monitor, resize, then fine-tune position (some apps clamp position on the first move)

## Development

### Building from Source

```bash
# Debug build (fast, for development)
swift build

# Release build (optimized)
swift build -c release
```

### Rebuilding After Changes

```bash
# Option 1: Build and test locally (no install)
swift build && swift run WindowLock

# Option 2: Build and test specific mode
swift build && swift run WindowLock --capture-only

# Option 3: Full rebuild + install as system daemon
./Scripts/install.sh
```

The install script handles the full cycle: builds a release binary, installs `WindowLock.app` to `/Applications`, and reloads the LaunchAgent so changes take effect immediately.

### Quick Development Workflow

```bash
# 1. Make your code changes
# 2. Build and assemble .app bundle (preserves Accessibility permission)
./Scripts/dev-build.sh

# 3. Test locally
open .build/WindowLock.app                                  # full daemon with menu bar
.build/WindowLock.app/Contents/MacOS/WindowLock --capture-only  # verify capture
.build/WindowLock.app/Contents/MacOS/WindowLock --restore       # verify restore

# 4. When satisfied, install the release version
./Scripts/install.sh

# 5. Or build a distributable .pkg installer
./Scripts/build-installer.sh
```

### Project Structure

```
window_lock/
  Package.swift                  # Swift Package Manager manifest
  README.md
  .gitignore
  Sources/WindowLock/
    main.swift                   # Entry point, CLI args, run loop, daemon setup
    WindowState.swift            # Data models (Codable structs)
    WindowTracker.swift          # Captures windows via CGWindowList + AX API (all Spaces)
    WindowRestorer.swift         # Restores positions, sizes, and Spaces via AX + CGS APIs
    DisplayManager.swift         # Display enumeration, naming, UUID mapping
    SpaceManager.swift           # macOS Spaces (virtual desktops) via private CGS APIs
    StateStore.swift             # JSON persistence for auto-saved state
    ProfileStore.swift           # Named layout save/load/delete
    SleepWakeObserver.swift      # Sleep/wake/display-change notifications
    StatusBarController.swift    # Menu bar icon, dropdown menu, uninstall
    LogWindowController.swift    # Interactive window log with tree grouping (NSOutlineView)
    LaunchAtLoginManager.swift   # LaunchAgent install/remove for Login Items
    AccessibilityHelper.swift    # Permission checking and prompting
    Logger.swift                 # Logging to stderr and ~/Library/Logs/WindowLock/
  Scripts/
    build-installer.sh           # Build release + create .pkg installer
    dev-build.sh                 # Build debug + assemble .app bundle
    install.sh                   # Build release + install to /Applications + load LaunchAgent
    uninstall.sh                 # Stop daemon + remove app + remove LaunchAgent
  Installer/
    welcome.html                 # Installer welcome screen
    readme.html                  # Installer feature description
    license.html                 # MIT license for installer
    conclusion.html              # Post-install Accessibility instructions
    distribution.xml             # productbuild distribution descriptor
    scripts/
      preinstall                 # Stop existing instance before install
      postinstall                # Set up LaunchAgent and start app
  Resources/
    Info.plist                   # App bundle metadata (bundle ID, version)
    com.way2do.windowlock.plist  # LaunchAgent template
```

### Data Storage

| Path | Description |
|---|---|
| `~/Library/Application Support/WindowLock/window-state.json` | Auto-saved window state (updated every 30s) |
| `~/Library/Application Support/WindowLock/profiles/<name>.json` | Named saved layouts |
| `~/Library/Logs/WindowLock/windowlock.log` | Application log file |
| `~/Library/LaunchAgents/com.way2do.windowlock.plist` | LaunchAgent (auto-start on login) |
| `/Applications/WindowLock.app` | Installed app bundle |

## Limitations

- Some apps resist window repositioning (e.g., Finder desktop windows)
- Window titles require Accessibility permission; without it, matching relies on CGWindowID only
- After a full restart, CGWindowIDs change — matching falls back to exact title + size, and windows without a confident match are skipped
- Cannot restore windows for apps that aren't running
- Space management uses private macOS CGS APIs — these are undocumented and could break in future macOS versions (though they've been stable for years and are used by yabai, Amethyst, etc.)
- Fullscreen spaces are tracked but window movement into/out of fullscreen is not supported

## License

MIT
