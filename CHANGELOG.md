# Changelog

All notable changes to WindowLock will be documented in this file.

## [1.1.0] - 2026-03-26

### Added

- **Multi-space window tracking** — captures and restores windows across all virtual desktops (Spaces), not just the active one. Uses macOS private CGS APIs (`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `CGSMoveWindowsToManagedSpace`) for reliable space detection and window movement.
- **SpaceManager module** — new `SpaceManager.swift` providing a complete interface to macOS Spaces: enumerate all spaces per display, query which space a window is on, move windows between spaces, and get the active space ID.
- **Window Log interactive actions** — each window row now has action buttons with SF Symbol icons and tooltips:
  - **Show** (eye) — activates the window; moves it to the current space if it's on a hidden one
  - **Reveal in Finder** (folder) — opens the app bundle location
  - **Open Terminal** (terminal) — opens Terminal.app in the app's directory
  - **Force Quit** (xmark.circle) — terminates the app with a confirmation dialog
- **Window Log tree grouping** — windows sharing the same PID (e.g., multiple Chrome or Mail windows) are grouped under an expandable parent row using `NSOutlineView`. The primary window (titled, on-screen, largest) is the parent; secondary windows are nested children. Single-window apps remain flat rows.
- **Persistent expand state** — expanded groups in the Window Log stay expanded across auto-refreshes (tracked by PID).
- **Persistent Window Log layout** — window size/position, column widths, column order, and sort column/direction are saved to `UserDefaults` and restored when reopening the Window Log or relaunching the app.
- **Click app name to activate** — clicking the app name cell (underlined link style with app icon) activates and raises that specific window. Works for both parent and child rows.
- **Right-click context menu** — full context menu on any window row with Show, Reveal in Finder, Open Terminal, Copy (PID/Bundle ID/Path), and Force Quit actions.
- **Display UUID mapping** — `DisplayManager.displayIndexByUUID()` maps CGS display UUIDs to display indices for accurate off-screen window-to-display assignment.
- **Startup diagnostics** — `SpaceManager.logDiagnostics()` logs API availability, connection ID, and all detected spaces at launch for easier troubleshooting.

### Changed

- **Window capture scope** — `CGWindowListCopyWindowInfo` now uses `.optionAll` instead of `.optionOnScreenOnly`, capturing windows on all spaces and monitors. Duplicate entries are filtered via a `seenWindowIDs` set.
- **Window matching algorithm** — completely rewritten with a strict 3-pass approach to prevent restoring the wrong window in multi-window apps:
  1. **CGWindowID match** — uses the kernel-level window identifier (stable while the window exists)
  2. **Exact title + exact size** — handles windows recreated after app restart
  3. **Unique exact title** — only matches when title is unambiguous (one saved, one AX)
  - Removed partial title matching and index-based fallback — windows that can't be confidently identified are skipped rather than guessed
- **Status bar info** — menu bar now shows `"Windows: N (X visible)"` to distinguish on-screen from off-screen windows.
- **Space column** — Window Log shows the actual space index for each window (was showing "--" for all).
- **Space count** — status bar shows detected space numbers instead of "N/A".

### Fixed

- **CGSConnectionID type** — changed from `UInt32` to `Int32` (signed) per CGS convention, fixing space API calls.
- **Space bitmask** — `kCGSSpaceAll` changed from `1` (current only) to `7` (current + others + user), enabling cross-space window queries.
- **Show window on hidden space** — "Show" action now moves the window to the active space via `SpaceManager.moveWindow(windowID:toSpaceID:)` before activating, instead of just calling `app.activate()` which left the window invisible.
- **Terminal action** — replaced unreliable AppleScript approach with `Process` launching `/usr/bin/open -a Terminal <path>` for correct directory opening.
- **Off-screen display assignment** — windows on non-active spaces now use the CGS space-to-display UUID mapping for accurate display detection instead of position-based heuristics.

## [1.0.0] - 2026-03-15

### Initial Release

- Automatic window position capture every 30 seconds and before sleep
- Window restoration after sleep/wake, display changes, and app launches
- Named layout profiles (save, restore, rename, delete)
- Menu bar interface with keyboard shortcuts
- Multi-monitor support with resolution-based display matching
- Window matching by title with index fallback
- CLI commands for capture, restore, and layout management
- LaunchAgent for auto-start on login
- Debug mode with restore diagnostics
- Window Log table view
- Installer (.pkg) and install/uninstall scripts
- Accessibility and Screen Recording permission management
