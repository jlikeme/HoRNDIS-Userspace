# Changelog

## 0.3.13 - 2026-10-28

- Require Apple-issued signatures with stable helper identifiers when packaging
  releases, and remove the release workflow's forced ad-hoc re-signing. This
  prevents local-network permission identity changes such as the v0.3.12
  distribution regression. Existing permissions may need reauthorization once.

## 0.3.12 - 2026-10-28

- Fix first-install name and disabled DHCP defaults: reject empty service IDs,
  initialize the new service through the native name/protocol APIs, and repair
  affected owned records/checkpoints without changing their UUID or position.

- Append newly registered network services to the end by default; recovery
  continues to honor the saved relative position of an existing service.

- Persist owned network UUID/configuration and per-location UUID ordering outside
  macOS migration data. Reuse or restore the original registration after reboot
  and system upgrade; necessary replacements use the old live slot or surviving
  neighbors, preserving all other services' relative order. Track manual changes
  and clear recovery state on complete uninstall.

## 0.3.11 - 2026-10-27

- Preserve the owned HoRNDIS USB network service, service identity, custom
  settings and service order during Homebrew upgrades and reinstalls. Stop jobs
  gracefully without disabling integration preferences; full uninstall still
  removes the owned network service.

- Keep the integration agent alive when denied local-network DNS sends return
  EPIPE/SIGPIPE; associate the LaunchAgent with the app, explain local-network
  access, report policy denial explicitly, and persist bounded transition logs.

- Fix missed automatic USB starts after quick cable reconnects by tracking ADB
  transports and retaining pending attempts while previous network status settles;
  record actual startup commands for diagnosis.

- Add optional ADB automatic USB tethering startup with a concise native menu
  command, authorized USB device discovery, pause protection, bounded attempts,
  observed network readiness, ADB path selection and explicit retry.

- Add optional Surge SIM DNS integration with DHCP-based interface/DNS discovery,
  connection-aware module control, DNS cache flushing, persistent cleanup retries,
  and native menu controls. Update DNS mappings and the SIM interface only when
  their values differ, preserving unchanged files and existing rules.
- Add optional Intelligence policy-group switching between SIM-Route and
  新加坡节点, with verified no-op selection, persistent fallback recovery and
  backwards-compatible preferences.

## 0.3.8 - 2026-08-30

- Create a missing `/Library/PrivilegedHelperTools` directory with the standard
  root ownership and `01755` permissions before stopping the current service
  or copying the privileged helper, so CLI, menu, PKG, and Homebrew installation
  all recover automatically without interrupting an existing service first.

## 0.3.7 - 2026-08-25

- Replace the window-style SwiftUI status panel with one native AppKit
  `NSMenu` implementation for macOS 11 and later, restoring system-owned menu
  corners, spacing, highlights, keyboard behavior, accessibility, and side
  submenu presentation.
- Replace liquid-glass USB Tethering and Launch at Login switches with standard
  checked `NSMenuItem` commands, avoiding inactive white switch tracks while
  retaining the existing service, authorization, diagnostics, localization,
  login, and one-second visible-refresh behavior.
- Move Details into a native side submenu containing the current runtime rows,
  diagnostic report, service log, and guided Bug-report actions.
- Request visible semantic menu-item images on macOS 27, where AppKit can hide
  images whose new visibility preference remains automatic, while preserving
  source and runtime compatibility with older SDKs and macOS 11–26.
- Replace the inline English/Simplified Chinese language check with standard
  macOS bundle localization and add Traditional Chinese, Japanese, Korean,
  French, German, Spanish, Brazilian Portuguese, Italian, and Russian, while
  retaining English fallback and per-app language selection.
- Reduce the native root-menu summary to three information rows, combine the
  device and connection duration, hide the authorization row while valid, and
  use the traffic row's leading image as its upload arrow, remove the duplicate
  inline upload marker, and shift the remaining traffic content left without
  changing other root rows.
- Align root-summary symbols with native checked commands through AppKit's
  off-state image column while preserving non-checked accessibility semantics,
  and keep the adjacent Authorize and Install action text-only.

## 0.3.6 - 2026-08-18

- Hand root-published status snapshots to the console user so the menu bar
  app can read supervisor states such as "starting", "waiting for a console
  user", agent-restart errors, and "stopped" instead of showing stale data.
- Probe the host interface's IPv4 address during a connected session and
  automatically request a DHCP refresh through the fixed supervisor channel
  when a VPN transition or network reordering strips the address, with a
  grace period and rate limit so repairs never race DHCP negotiation.
- Add RNDIS negative-path tests covering truncated headers, out-of-range
  offsets, 64-bit wraparound, corrupt aggregated transfers, and completion
  mismatches, plus JSON-escape serialization tests for hostile device
  strings and a behavioral diagnostics-redaction test target.
- Update the user guide (English and Chinese) and limitations document to
  describe the current menu bar window and in-place Details disclosure, and
  add the missing 0.3.5 changelog entry.

## 0.3.5 - 2026-08-15

- Refresh DHCP through the fixed supervisor channel after every successful
  RNDIS initialization and publish the connected state only after DHCP
  succeeds, so reconnects and delayed post-boot phone connections regain
  addresses automatically.
- Select an unused feth pair at startup and tear down only interfaces owned by
  the current supervisor, never adopting or destroying another application's
  interfaces.
- Add privacy-preserving diagnostic reports with stable in-memory device
  aliases, bilingual bug-report documentation, and a diagnostic-upload issue
  form; account and device names, serial and location identifiers, MAC/IP
  values, hardware identifiers, packet contents, and credentials are excluded
  at collection time.
- Reuse independent USB receive/transmit buffers and bound autorelease
  lifetimes so sustained transfers no longer grow data-agent memory.
- Wrap the diagnostics manual page text.

## 0.3.4 - 2026-08-13

- Make package upgrades, menu restarts, and direct app launches converge on a
  single menu bar process, including older standalone instances that are not
  owned by the login LaunchAgent.
- Wait for graceful termination before relaunch and use macOS force termination
  only for an unresponsive stale instance, preventing duplicate status icons
  after an in-place upgrade.

## 0.3.3 - 2026-08-13

- Preserve the menu's required one-second live refresh while reducing
  counter-only status-file writes to a five-second cadence when the menu is
  closed; device, service, error, and user-requested transitions remain
  immediate.
- Replace the privileged supervisor's 250 ms child polling with event-driven
  waiting, eliminating its idle CPU, wakeups, and I/O without changing the
  one-time authorization or automatic restart model.
- Add a renewable, unprivileged observation lease and bounded control-command
  batching so opening the menu restores fresh one-second traffic snapshots
  without delaying connect or disconnect commands.
- Add runtime publication tests and make the one-second visible-refresh
  behavior part of the documented and automated menu contract.

## 0.3.2 - 2026-08-13

- Restore the native SwiftUI `MenuBarExtra` interaction baseline, including
  draggable mini switches, local Details disclosure animation, active accent
  colors, and foreground-app focus preservation.
- Unify every menu row's icon column, text start, height, selection inset, and
  24-point highlight geometry; match the current system selection curve while
  leaving the compositor-owned window frame to macOS.
- Add English and Simplified Chinese app localizations, menu UI regression
  tests, and documented visual acceptance rules for future changes.

## 0.3.1 - 2026-08-12

- Restore the selected system accent color on the native switch controls without replacing their system material or animation.
- Force standard menu-item icons to remain visible on macOS 27 so native and switch rows share the same icon, title, and vertical alignment.
- Keep the native `NSMenu` frame and corner geometry introduced in 0.3.0.

## 0.3.0 - 2026-08-12

- Replace the custom window-style popover and all manual corner clipping with AppKit's native `NSStatusItem` and `NSMenu`, letting macOS own the exact menu frame, corner geometry, spacing, highlights, dark mode, and submenu animations.
- Keep the compact native `NSSwitch` controls for USB tethering and login startup while the surrounding status, action, and Details rows use standard menu items.
- Install the menu bar app at `/Applications/HoRNDIS Status.app` from both the release package and Homebrew.
- Replace the source-built Homebrew Formula with a prebuilt universal package Cask so users do not need Xcode or Command Line Tools.
- Consolidate installation, menu control, status, diagnostics, and command help under the single `horndis` command, with a complete `man horndis` page.

## 0.2.3 - 2026-08-12

- Use Apple's `DisclosureGroupStyle` pattern with a native, faster smooth spring for matching expand and collapse animations.
- Make the complete Details row clickable with the system accent-color hover treatment, and keep its icon and text aligned with the surrounding controls.
- Use the native mini switch and a consistent 32-point height for every menu row, with a slimmer 24-point accent selection for interactive rows.
- Match menu selections to the system window with equal edge insets and native concentric-corner geometry on macOS 26, plus a continuous-radius compatibility fallback on older systems.
- Prevent transient menu-window resize callbacks from cancelling disclosure animations, align expanded rows with the compact view, and display transmitted traffic before received traffic.

## 0.2.2 - 2026-08-12

- Avoid SwiftUI's external `@State` macro for action-row hover tracking so source builds work with the standalone macOS 27 Command Line Tools as well as full Xcode.
- Validate the complete Homebrew source build, application bundle installation, and Formula test path against the published release archive.

## 0.2.1 - 2026-08-12

- Menu controls now use the system accent color and Apple SF Symbol icon columns consistently.
- Replaced nested tracking areas with `NSMenuItem.isHighlighted` to prevent stuck hover states.
- Replaced unsupported AppKit menu resizing with a native SwiftUI Details disclosure.
- Refresh traffic, duration, and connection controls every second while the menu is open.
- Restored the native system switch appearance while retaining the selected accent color.
- Preserve stable Homebrew executable symlinks in the login LaunchAgent across upgrades.
- Added a complete macOS application icon and sealed it into the status app bundle.
- Added one-command Homebrew activation and a unified GitHub Release installer package.
- Let the native window-style menu bar scene render enabled switches with the selected system accent color.
- Let macOS render the menu bar symbol as a template image for automatic light and dark contrast.
- Show persistent authorization state and offer a standard macOS administrator install action when required.
- Bundle the fixed network installer tool inside the menu bar app for Homebrew and Release packages.
- Replaced manual menu tracking with the native window-style `MenuBarExtra`, preserving foreground-app focus while macOS handles status-item alignment and accent-colored switches.
- Replaced the separate Details submenu with a native `DisclosureGroup` using Apple's smooth spring animation on macOS 14 and later.
- Prepopulate the menu model before its first presentation so opening no longer triggers a second size/layout pass.
- Realign highlighted action rows with summary and switch rows, and use shield status symbols for persistent authorization.
- Add matching English and Simplified Chinese GitHub landing pages with an in-page language switch.
- Exclude local agent instructions, agent state, and Finder metadata from published source archives.

## 0.2.0 - 2026-08-11

- Lightweight Swift/AppKit menu bar status app with English and Chinese labels.
- Compact device, session traffic, duration, login-start, and native USB Tethering switch controls.
- Expandable IP, interface, device MAC, service PID, log, project, and diagnostics details.
- Atomic runtime status publication and a console-user-authenticated local control socket.
- Privilege separation: root performs fixed network setup while the current console user handles all USB, RNDIS, status, and control processing.
- Best-effort deployment target lowered to macOS 11.
- Universal Apple Silicon and Intel menu bar release builds.
- English and Chinese user guides plus a dedicated limitations reference.

## 0.1.0 - 2026-08-11

- First macOS RNDIS implementation to run in user space rather than the kernel, without requiring SIP to be disabled.
- IOUSBHost discovery and exclusive ownership of only the RNDIS control/data interfaces.
- RNDIS initialize, query, packet filter, aggregated packet RX, and bulk TX/RX.
- feth/BPF virtual Ethernet bridge with DHCP configuration.
- Root LaunchDaemon installer with automatic USB reconnect.
- Pixel 4 XL end-to-end validation while retaining ADB connectivity.
- Homebrew tap and universal-release automation.
