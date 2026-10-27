# Privilege Model

HoRNDIS uses one administrator-authorized installation and does not persist an administrator password. Reboot, login, USB hot-plug, Android tethering changes, pause/resume, and menu-bar startup do not request authorization again.

## Why any root component remains

On macOS, `/dev/bpf*` is `root:wheel` with mode `0600`, and only the super-user may create or modify network interfaces. HoRNDIS needs both operations to connect a user-space USB implementation to the macOS TCP/IP stack.

Changing BPF device permissions, adding a broad passwordless sudo rule, or installing a setuid executable would widen access more than a fixed LaunchDaemon and is intentionally avoided.

## Process boundary

```text
root LaunchDaemon supervisor
  ├─ select and exclusively create an unused feth pair
  ├─ register an owned Network Service/bridge (direct feth fallback)
  ├─ start system DHCP on the selected macOS-facing interface
  ├─ open and bind one BPF descriptor
  └─ fork + exec, pass that descriptor and a fixed DHCP-refresh channel
                    │
                    ▼
console-user data agent
  ├─ IOUSBHost discovery and interface ownership
  ├─ RNDIS initialization and parsing
  ├─ Ethernet frame forwarding through inherited BPF
  ├─ atomic runtime status
  └─ authenticated local pause/resume control

console-user Swift menu bar
  └─ read status and request pause/resume

optional console-user Surge LaunchAgent
  ├─ read runtime status and the phone service's DHCP options
  ├─ probe DHCP DNS through the detected interface
  ├─ reconcile user-selected local Surge files and module state
  └─ optional independent ADB queue for authorized USB tethering startup
```

The child permanently drops supplementary groups, group ID, and user ID before `exec`. It cannot reopen BPF devices, reconfigure interfaces, modify the installed helper, or regain root. After each successful RNDIS initialization, it sends one fixed `refresh DHCP` request and waits for a one-byte success/failure response before reporting the session as connected. The request carries no interface name, command arguments, packet content, or other device-controlled data. The root supervisor validates the fixed request, raises both prevalidated feth interfaces, restarts the macOS DHCP client, and then blocks on the channel again. It never receives or parses USB-controlled bytes.

This per-session handshake prevents a boot-order race in which macOS networking clears the temporary DHCP state after the LaunchDaemon's initial setup but before an Android device connects. If the privileged refresh fails, the data agent publishes an error and retries instead of leaving the menu indefinitely at **Configuring DHCP**.

Automatic selection prefers `feth99`/`feth98`, then scans downward in odd/even pairs. A pair is eligible only when both names are absent. HoRNDIS never adopts, reconfigures, or destroys an interface that already existed; it removes only the pair created by the current supervisor. Explicit environment overrides remain available but must name two absent, distinct `feth<number>` interfaces.

The runtime directory is assigned to the current console user after privileged setup with mode `0700`. Status and control endpoints use mode `0600`. The local control socket additionally validates the connecting peer against the current console user.

## Installation lifecycle

`horndis install` delegates exactly one operation to `sudo horndis service install`; the Homebrew Cask and GitHub Release package perform the same operation inside the administrator-authorized Installer process. That privileged step:

1. ensure `/Library/PrivilegedHelperTools` exists as `root:wheel` with the
   standard `01755` permissions, creating it when absent;
2. copy the exact executable to `/Library/PrivilegedHelperTools/io.github.noahhhi.horndis`;
3. set root ownership and non-writable executable permissions;
4. install the root-owned LaunchDaemon plist;
5. bootstrap the service.

The Homebrew command-line path's password is handled by `sudo`, while the package path uses macOS Installer authorization. The menu app provides a third entry point: it verifies that the helper and LaunchDaemon plist are root-owned, non-writable by ordinary users, and structurally valid; when they are not, **Authorize and Install…** asks the macOS Security Agent to run only the fixed bundled `horndis service install` command. HoRNDIS never reads or stores a credential in any path. The LaunchDaemon supplies persistence, so storing credentials in a script, Skill, Keychain lookup, environment variable, or sudoers exception is unnecessary. The menu LaunchAgent runs as the console user and needs no additional authorization.

## Remaining risk

The optional Surge integration runs in a separately signed helper inside the app
bundle, never as root and never inside the USB forwarding loop. It uses public
SystemConfiguration DHCP APIs and the installed Surge CLI. No shell interpolation,
HTTP API credentials or additional privileged requests are involved. The agent
survives menu app exit, persists incomplete cleanup and uses bounded subprocess
timeouts. Its configuration and recovery files are user-private; managed Surge
files retain their permissions. Unchanged configuration is never rewritten.

Optional automatic USB startup uses the same ordinary-user helper, with its own
queue and status file. It invokes the detected/selected ADB executable with fixed
arguments and an explicitly selected authorized USB serial, never shell text.
Remote ADB server redirection is excluded. ADB debugging, host authorization and
root access are not enabled automatically. Pause intent is scoped to the current
data-agent PID and rechecked immediately before the USB mode command. A mode
change acknowledgement is followed by observed RNDIS and interface-bound DNS
readiness, not treated as network success by itself.

The ordinary-user integration agent requires macOS local-network authorization
for phone DNS probes. Its LaunchAgent declares `AssociatedBundleIdentifiers`, and
the app supplies a localized usage description. No global local-network exemptions
or root DNS probes are used. SIGPIPE is ignored before Foundation/network work so
an EPIPE returns through the error path; Network.framework identifies actual local
policy denial. Known file paths carry explicit file/directory roles. Private bounded
logs preserve failures and transitions instead of silently leaving stale status.

The owned **HoRNDIS USB** Network Service uses a registered bridge with a
feth member registered in both runtime and system bridge preferences. The member
is removed from both on pause/close and restored on connection, so System Settings
can determine the real bridge status. Bridge registration uses dynamically resolved private
SystemConfiguration APIs, with direct feth fallback if unavailable or unsafe.
The preferences session is locked and uses the default system domain. Bridge
options record ownership and the service ID; existing members prevent reuse or
removal. The supervisor never attaches physical network interfaces. A second
fixed, argument-free request clears DHCP and lowers the owned feth pair after
disconnect/pause; channel closure also suspends the network after an agent crash.

The package cleanup script accepts a replacement mode that only stops its fixed
launchd jobs and waits for graceful exit. It never deletes the persistent network
service in this mode. The cask passes a constant `--homebrew` argument; a read-only
helper classifies the nearest Homebrew ancestor using `proc_pidpath`, bounded
`KERN_PROCARGS2` decoding and exact operation arguments. Unknown contexts preserve
configuration. No commands are constructed from process arguments. Explicit full
uninstall retains the existing ownership-checked network-service removal.

The supervisor is still a root process and the feth/BPF backend depends on macOS behavior that Apple does not promise as a stable public ABI. Its input surface is deliberately small and fixed, but it is not equivalent to a formally sandboxed or Apple-entitled DriverKit component.

A future backend could replace BPF/feth with a suitable public unprivileged API if Apple provides one. The current source separates USB, RNDIS, Ethernet, service, control, and UI layers to keep that migration bounded.
