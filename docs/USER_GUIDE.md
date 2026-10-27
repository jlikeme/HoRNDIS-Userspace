# HoRNDIS Userspace Guide

## Requirements

- macOS 11 or later on Apple silicon or Intel.
- An Android device that exposes a supported RNDIS USB control/data pair.
- A data-capable USB cable.
- Administrator authorization once when installing or upgrading the network service.

HoRNDIS runs in user space rather than as a kernel extension, so users do not need to reduce boot security or disable SIP.

## Install

```sh
brew install --cask noahhhi/tap/horndis
```

Or install the package directly:

1. Download the universal `.pkg` from [GitHub Releases](https://github.com/noahhhi/HoRNDIS-Userspace/releases).
2. Try to open the downloaded `.pkg`.
3. If macOS blocks it, open **System Settings → Privacy & Security**.
4. Click **Open Anyway** for the HoRNDIS package.
5. Enter an administrator password when prompted, then complete the installation.

> [!IMPORTANT]
> This project currently uses a free Apple Developer account, which cannot provide the paid Developer ID certificate required to sign and notarize the installer for public distribution. macOS may therefore block the first launch until you approve it with **Open Anyway**. You do not need to disable SIP or reduce system security.

If `/Library/PrivilegedHelperTools` is missing, the installer recreates it with
the standard root-owned permissions before installing the helper. No manual
directory preparation is required.

Enable **USB tethering** in Android settings. The service will discover the RNDIS interfaces automatically while leaving a separate ADB interface available.

## Menu bar

The app uses standard macOS bundle localization and follows the system or per-app language selection. Included languages are English, Simplified Chinese, Traditional Chinese, Japanese, Korean, French, German, Spanish, Brazilian Portuguese, Italian, and Russian. Change the per-app language in **System Settings → General → Language & Region → Applications**, then reopen HoRNDIS Status.

The status item uses Apple SF Symbols and is deliberately compact by default:

- connection state;
- connected Android device name and current duration on one row;
- transmitted and received bytes for the current USB session;
- administrator authorization only when installation or repair is required;
- a checked USB Tethering menu command;
- a checked Launch at Login menu command;
- a Details item that opens a system submenu at the side.

Opening Details shows a native side submenu containing the DHCP address, feth interface, device MAC, service process ID, last service detail, service-log access, a diagnostic-report save action, and a guided bug-report action.

The status item is a native macOS template symbol, and the menu uses dynamic system colors. Both follow the current light or dark appearance automatically, including menu bars whose appearance differs from the app appearance.

On every supported release from macOS 11 onward, HoRNDIS uses AppKit's standard `NSStatusItem`, `NSMenu`, and `NSMenuItem`. AppKit owns the menu's exterior shape, material, shadow, spacing, highlight, selected accent color, checkmarks, keyboard behavior, accessibility, light/dark appearance, and Details submenu animation. HoRNDIS does not draw or clip a replacement menu and does not become the foreground app while the menu is open.

When authorization is valid, the compact summary shows no authorization row. If the root-owned network helper or its LaunchDaemon configuration is missing, incorrectly owned, writable by non-root users, or invalid, the menu reports **Authorization: Required** with a shield and adds the text-only **Authorize and Install…** action directly below it without repeating that icon. The action uses the standard macOS administrator authentication dialog to execute only the fixed `horndis service install` command bundled with the app. HoRNDIS never receives or stores the password. The equivalent terminal workflow is `horndis install`.

The two checked commands rely on AppKit's standard checkmark and do not add a second leading image. Details relies on the native submenu arrow, and Quit relies on its `⌘Q` shortcut. The root-summary SF Symbols use AppKit's off-state image slot, which aligns them with the native checkmarks without marking those information rows as checked or creating a separate image column. Details-submenu information retains ordinary semantic SF Symbols in its independent menu. In the traffic row, the leading symbol is the upload arrow itself; the title starts with the transmitted total and then shows the explicit `↓` received marker.

Clearing the checkmark beside **USB Tethering** pauses the RNDIS bridge but keeps the background service available. Selecting it again restores the checkmark, resumes discovery, and connects when Android USB tethering is enabled. The separate optional **Auto-start USB Tethering** action can request phone-side sharing through authorized ADB.

While a device is connected, HoRNDIS also watches the bridge interface's IPv4 address. If macOS removes the address — for example after a VPN connects or disconnects and reorders the network configuration — HoRNDIS requests a fresh DHCP lease automatically within about fifteen seconds; no manual restart is needed.

The menu bar app reads `/var/run/horndis/status.json` every two seconds while closed and every second while its menu is visible. It updates the existing native menu item titles, enabled states, checkmarks, and submenu rows in place instead of rebuilding the open menu. It does not inspect packet contents or send telemetry. The runtime directory, status file, and control socket are accessible only to the current console user and root. Connection requests go to `/var/run/horndis/control.sock` and also receive a peer-UID check.

## Automatic USB tethering via ADB

Enable USB debugging on the phone, authorize this Mac, then check **Auto-start USB
Tethering**. It is initially off and independent of the Surge master switch. ADB
is detected in Homebrew and Android SDK locations. Use **Details → Choose ADB…**
to select a different executable; **Retry USB Start** permits an explicit retry.

Only one authorized USB ADB phone is acted on. Wireless transports, emulators,
multiple phones, offline devices and unauthorized devices do not trigger startup.
The agent uses the fixed `svc usb setFunctions rndis` command and waits for observed
RNDIS and DHCP/DNS configuration. An acknowledgement alone is not network success.
Unsupported ROMs, denied permissions and a thirty-second startup timeout are shown
in Details. No root or debugging authorization is requested automatically.

Each new ADB USB transport gets an attempt, including a quick reconnect with the
same serial. Only an unconfirmed mode change initiated by this agent inherits its
previous attempt during re-enumeration. An eight-second absence grace is retained
as a fallback for older ADB versions without transport IDs. Command count, time and
trigger are recorded separately from the observed sharing state.
Manual pause blocks automatic commands immediately, and never resumes the HoRNDIS
bridge automatically. Turning this option off stops future attempts and leaves an
existing connection under the regular USB Tethering control.

The independent background queue continues while the menu app is closed or Surge
is unavailable. Its user-private status file is `adb-status.json` in the integration
settings directory. A read-only device probe is available:

```sh
"/Applications/HoRNDIS Status.app/Contents/Helpers/horndis-surge-agent" --inspect-adb
```

## Local network permission

On macOS 15 and later, allow **HoRNDIS Status** local network access when prompted.
The app verifies the DHCP DNS provided by the phone; this is local-network traffic.
If previously denied, use **Surge Integration → Open Local Network Settings…** or
**System Settings → Privacy & Security → Local Network**. Terminal/SSH command-line
success does not establish permission for a user LaunchAgent.

Policy denial is shown explicitly and retried with DHCP metadata preserved. It
does not terminate the agent via SIGPIPE, enable SIM DNS or select SIM-Route while
verification is failing. The LaunchAgent declares its associated app and the app
performs the permission-triggering operation when the phone network is available.

Lifecycle, transition, DNS and publication errors are logged privately to
`~/Library/Application Support/HoRNDIS/Surge/agent.log`, bounded to 1 MiB plus one
rotated file. For local development, `SIGNING_IDENTITY` can select an existing
Apple-issued code-signing identity to stabilize privacy attribution. Ad hoc builds
can require permission again after a rebuild; duplicate app copies can also affect
the system's permission UI.

## Optional Surge integration

Requires Surge Mac 6.8 or later. In **Surge Integration**, select the existing
`SIM DNS` module, then check **Enable Integration** (off by default). Select a
local `.sgmodule` in the active profile directory, with `#!name=SIM DNS` and
numeric IPv4 `server:` mappings in `[Host]`. The active `.conf` is detected in
the same directory, or can be selected explicitly. Its `[Proxy]` section must
contain exactly one `SIM = direct, ...` policy. Included/remote SIM policies
are not edited automatically.

The agent obtains the actual HoRNDIS interface and that service's DHCP DNS and
router options. It requires a valid IPv4 address and a successful `example.com`
lookup through a socket bound to the phone interface. It does not fall back to
Wi-Fi or substitute the gateway for missing DNS. All advertised DNS addresses
are retained in order. Non-numeric mappings such as `server:system` are preserved.

Only differing DNS or SIM interface values cause a file replacement. Unchanged
files retain their bytes, timestamps and formatting, create no backups, and do
not trigger a reload. Changed files receive an adjacent `.horndis-backup` and
retain their permissions, comments and unrelated rules. The changed profile is
validated before replacement. Duplicate modules/policies, symbolic links and
concurrent edits produce an error. Module state is reconciled independently;
actual changes are followed by a Surge DNS cache flush and module readback.

Unplugging, pausing, losing the network configuration or stopping networking
disables the module. Surge absence causes automatic retries (up to 30 seconds
apart). Turning integration off persists pending cleanup until Surge returns.
Use **Retry Now** to check sooner; hover over an error for its full detail.

A separate per-user LaunchAgent is registered on first enable and survives menu
app exit, including `horndis stop`. Connection/settings checks run every second,
with Surge reconciliation every five seconds when stable and DNS probes every
minute. A network status older than ten seconds is treated as disconnected.
Settings, status and the recovery journal live in
`~/Library/Application Support/HoRNDIS/Surge/`. Uninstall waits for module cleanup;
if cleanup is pending, keep the App installed, start Surge and retry uninstalling.

**Automatically Switch Intelligence** is a separate, initially unchecked action
under the integration master switch. Once USB/DNS are ready and SIM DNS is enabled,
it selects `SIM-Route` in the existing `Intelligence` group. Disconnect, pause,
service stop, DNS loss, or turning either switch off restores `新加坡节点`.
Both named members must exist and be enabled. The current verified selection is
shown in the submenu. Existing preferences remain valid when upgrading.

Policy selection uses Surge's CLI, without editing profile files or reloading.
An already-correct selection is a no-op; actual changes are read back and followed
by a DNS cache flush. Module shutdown and policy fallback are attempted independently.
Unfinished fallback survives Surge absence and agent restart. Selections are tracked
per profile: an inactive profile is restored when the user returns to it; HoRNDIS
never changes the active Surge profile to perform cleanup.

This read-only probe reports the detected network, DNS readiness and files that
would need changes without writing configuration or changing module state:

```sh
"/Applications/HoRNDIS Status.app/Contents/Helpers/horndis-surge-agent" --inspect
```

## Command-line status

```sh
horndis status
horndis diagnostics ~/Desktop/HoRNDIS-Diagnostics.txt
horndis probe
scutil --nwi
tail -f /var/log/horndis.log
```

`horndis status` and menu Details show the selected macOS-facing interface. Use that name with `ifconfig` or `ipconfig getsummary`.

If the menu bar app has been quit, reopen it from Applications, Launchpad, or
Spotlight, or run `horndis start`. Use `horndis stop` to hide it without
disabling login startup, and `horndis restart` after troubleshooting. Run
`horndis help` or `man horndis` for the complete command reference.

The Network settings panel lists **HoRNDIS USB**, backed by the actual `bridge<number>` interface carrying DHCP and USB traffic. Menu Details and `horndis status` show that same interface. Pause/disconnect clears its address; reconnect restarts DHCP. The service remains listed while disconnected and is reused on restart, upgrade and reinstall. Its service identifier, custom settings and position in the network service order are retained. A complete uninstall removes the owned service and bridge.

Registration uses private macOS bridge configuration APIs resolved at runtime. If unavailable or unsafe to apply, HoRNDIS logs the reason and falls back to the direct feth path, which is not listed in Network settings. This feature still requires testing on each supported macOS version. The bridge only receives a newly created feth member, never Wi-Fi, Thunderbolt, or a physical adapter. Existing bridge members prevent reuse or removal. Use the HoRNDIS menu to pause/resume; Network settings cannot switch Android tethering on.

## Stuck at Configuring DHCP

Current builds re-enable the selected macOS-facing feth interface and restart the DHCP client after every successful USB/RNDIS connection. This also covers reconnects after boot, login, sleep, cable changes, and Android tethering changes; no new administrator prompt is required.

If an older installed build remains at **Configuring DHCP** after the device name appears, its one-time boot DHCP setup may have been cleared by macOS before the phone connected. Restore that session with:

```sh
sudo ifconfig feth99 up
sudo ipconfig set feth99 DHCP
```

Then turn Android USB tethering off and on. Upgrade or reinstall HoRNDIS to obtain the automatic per-connection repair. If a current build still has no address, use the interface printed by `horndis status` with `ipconfig getsummary <interface>` and inspect `/var/log/horndis.log`; the menu should report a DHCP-refresh error rather than remain indefinitely in the configuring state when the privileged refresh itself fails.

## Upgrade

```sh
brew update
brew upgrade --cask horndis
```

The cask generated from `Packaging/horndis.rb.in` uses the bundled `--homebrew`
cleanup mode. It stops jobs gracefully during replacement without deleting the
network service or changing Surge/ADB preferences. The operation is read from
the invoking Homebrew process's kernel argument list when cleanup runs, so saved
Homebrew JSON cannot freeze an earlier install's choice. Unknown operations keep
the network configuration; explicit `brew uninstall` and `horndis uninstall`
perform complete cleanup.

The first update from an older build must also migrate Homebrew's **installed**
uninstall record before replacement; updating the tap alone does not update that
record. `Scripts/homebrew-maintenance.py` provides the one-time adapter, with a
backup and conditional restoration if installation fails. It changes only the
HoRNDIS cask record, never macOS network preferences or service order.

`Scripts/generate-homebrew-cask.py` binds that definition to the exact package
version, URL and checksum. Release builds attach `horndis.rb` alongside the PKG;
the tap must use the matching definition to obtain replacement-aware cleanup.

Only reinstalling the privileged service requires administrator authorization. Normal boot, reconnect, menu-bar use, and login startup are silent. The resident root process is a minimal supervisor; USB and RNDIS processing runs under the current console user. See [Privilege model](PRIVILEGE_MODEL.md).

## Uninstall

```sh
horndis uninstall
brew uninstall --cask horndis
```

## Testing the phone path

When Wi-Fi or a VPN remains active on the Mac, bind diagnostics to the USB interface:

```sh
ping -b <interface> 8.8.8.8
```

Replace `<interface>` with the value printed by `horndis status`.

VPN applications using fake-IP DNS can return an address reachable only through their tunnel. A failed interface-bound request to that fake address does not indicate an RNDIS failure. Compare the system resolver with the Android DHCP DNS server when diagnosing this case.

For a bug report, reproduce the problem and immediately save a fresh diagnostic report from menu Details or with `horndis diagnostics FILE`. Review the file, then attach it to the required upload in the GitHub bug form. See [Reporting a bug](BUG_REPORTING.md) for the full workflow and privacy details, and [Known limitations](LIMITATIONS.md) before reporting a compatibility problem.
