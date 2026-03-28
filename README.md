# Transmission VPN Shield (Synology SPK)

👮‍♂️ _To protect and serve Transmission traffic through VPN_ 🙃

![icon](synology/PACKAGE_ICON_256.PNG)

Force Transmission traffic through a VPN interface with UID-based routing, keep LAN access for the web UI/automation, and optionally enforce a kill switch when supported by the NAS iptables build.

---

## Features

- **UID-scoped routing**: `ip rule` + dedicated routing table force all Transmission traffic through the VPN interface. Nothing else on the NAS is affected.
- **Automatic LAN bypass**: directly-connected LAN routes are copied into the VPN table so the Transmission web UI, Sonarr, Radarr, etc. remain reachable on your local network while torrent traffic exits the VPN.
- **Auto-detects Transmission user**: tries `sc-transmission`, `transmission`, `debian-transmission`, or a custom value from config.
- **Kill switch**: optionally blocks Transmission traffic via `iptables -m owner` if the VPN drops. Falls back gracefully to routing-only protection if the kernel lacks `xt_owner` (still safe — no VPN route = no traffic).
- **VPN forwarded port push**: if your VPN provider assigns you a forwarded port, set `FORWARDED_PORT` in `guard.conf` and the shield will automatically configure Transmission's peer port via RPC on every start.
- **Beginner-friendly web UI**: big green/red status banner, icon cards for each check, raw output hidden in an expandable section for advanced users.
- **Background public IP refresher**: fetches your public IP *through the VPN tunnel* every 2 hours (configurable) and displays it in the UI. Never leaks your real WAN IP.
- **Survives reboots**: after the one-time activation (see below), the package runs as root automatically on every DSM boot — no SSH needed.
- **Clean install/uninstall**: idempotent start/stop; `prestop` removes the `rt_tables` entry on uninstall for a full teardown.

---

## Installation

> **Why the extra step?** DSM 7.2+ blocks unsigned third-party packages from declaring root privileges at install time. The package installs as a normal user, then a one-time Task Scheduler job completes the elevation. After that, everything runs automatically including on reboots.

### Step 1 — Install the package

1. Download the latest `.spk` from the [Releases page](https://github.com/gioxx/Syno-TransmissionVPNShield/releases).
2. In DSM → **Package Center** → top-right menu → **Manual Install**, upload the `.spk`.
3. The package will end up in **Error** state. **This is expected** — it means the privilege elevation hasn't happened yet.

### Step 2 — One-time activation via Task Scheduler

This step elevates the package privileges so it can manage routing rules. You only need to do this once per install or upgrade.

1. In DSM → **Control Panel** → **Task Scheduler** → **Create** → **Triggered Task** → **User-defined script**.
2. Fill in the form:
   - **Task name**: `Activate Transmission VPN Shield` (or anything you like)
   - **User**: `root`
   - **Event**: `Boot-up` (or leave as Manual)
   - **Enabled**: leave it **unchecked** — you don't want this to run on every boot
3. Switch to the **Task Settings** tab and paste this command:
   ```
   /var/packages/TransmissionVpnShield/scripts/activate
   ```
4. Click **OK** to save the task.
5. Back in the Task Scheduler list, select the task and click **Run** to execute it immediately.
6. After a few seconds, go back to **Package Center** — the package should now show as **Running**.

That's it. The package will start automatically on every subsequent DSM boot without any further manual steps.

### Step 3 — Web UI

The shield icon appears in the DSM Main Menu. The web UI is also directly accessible at:
```
http://<your-nas-ip>:5000/webman/3rdparty/TransmissionVpnShield/index.cgi
```

---

## Configuration

The config file lives on the NAS at:
```
/var/packages/TransmissionVpnShield/target/conf/guard.conf
```

After editing, restart the package from DSM **Package Center**.

| Setting | Default | Description |
|---|---|---|
| `TRANSMISSION_USER` | `sc-transmission` | System user running Transmission. Auto-detected if not found. |
| `VPN_IF` | `tun0` | VPN interface name. Use `ip link show` to check yours. WireGuard is typically `wg0`. |
| `RT_TABLE_ID` | `200` | Internal routing table ID. Change only if it conflicts with another package. |
| `RT_TABLE_NAME` | `transmissionvpn` | Internal routing table name. |
| `ENFORCE_KILLSWITCH_WHEN_VPN_DOWN` | `1` | `1` = block Transmission if VPN drops. `0` = allow fallback (not recommended). |
| `PUBLIC_IP_REFRESH_SEC` | `7200` | Seconds between background VPN IP refreshes. `0` disables it. |
| `FORWARDED_PORT` | *(empty)* | VPN forwarded port — see below. |

---

## VPN forwarded port (recommended for better speeds)

Some VPN providers let you **forward a port** through the VPN tunnel, allowing other BitTorrent peers to connect directly to you. This significantly improves download/upload speeds and seeding ratios.

**You do NOT need to open this port on your router or DSM firewall.** Traffic enters through the VPN tunnel and never touches your local network's firewall.

### How to set it up (example: AirVPN)

1. Log in to the [AirVPN client area](https://airvpn.org/ports/).
2. Go to **Client Area → Forwarded ports** and create/note your port (e.g. `56460`).
3. Edit `guard.conf` on the NAS (`/var/packages/TransmissionVpnShield/target/conf/guard.conf`) and set:
   ```
   FORWARDED_PORT="56460"
   ```
4. Save the file and restart the package from Package Center.

The shield will call Transmission's RPC API on every start and set the peer port automatically. No manual configuration in Transmission needed.

The web UI shows the configured port with a direct link to check if it's reachable from the internet.

### Other providers

The same principle applies to any provider that supports port forwarding (ProtonVPN, Mullvad, PIA, etc.). Find the forwarded port number in your provider's dashboard and set it in `guard.conf`.

---

## How it works

### `start`
1. Loads config and resolves Transmission UID (auto-detect fallback chain).
2. Ensures `rt_tables` entry for the dedicated routing table.
3. Sets a default route via the VPN interface in the dedicated table.
4. Copies LAN directly-connected routes into the dedicated table (keeps UI reachable).
5. Adds `ip rule uidrange UID-UID lookup transmissionvpn`.
6. Optionally adds kill-switch rule: `OUTPUT -m owner --uid-owner UID ! -o VPN_IF -j DROP` (skipped with a log entry if `xt_owner` is unsupported).
7. Pushes `FORWARDED_PORT` to Transmission via RPC (if configured).
8. Starts background public-IP refresher daemon.

### `stop`
Removes ip rule, kill switch (if present), flushes routes in the dedicated table, stops the IP refresher. The `rt_tables` entry is kept (harmless).

### `prestop` (pre-uninstall)
Runs full stop + removes the `rt_tables` entry for a clean teardown.

### Web UI
Displays a green/red banner for at-a-glance status, plus individual cards for: VPN tunnel, public IP via VPN, traffic routing, kill switch, Transmission user, and forwarded port. Raw `status` output is available in an expandable "Advanced" section.

---

## Files of interest

| File | Purpose |
|---|---|
| `synology/scripts/start-stop-status` | Lifecycle logic: routing, ip rule, kill switch, RPC port push |
| `synology/scripts/activate` | One-time post-install activation script (run from Task Scheduler as root) |
| `synology/scripts/_elevate` | Merges `privilege.elevated` into `privilege` at activation time |
| `synology/conf/privilege` | Tells DSM to install the package as a normal user (required for DSM 7.2+) |
| `synology/conf/privilege.elevated` | Root privilege declarations, merged in at activation time |
| `src/conf/guard.conf` | Runtime configuration (copied to NAS on install) |
| `src/ui/index.cgi` | Web status page (CGI shell script) |

---

## Limitations / notes

- This package does **not** manage the VPN connection itself. It assumes `VPN_IF` is already up (e.g. managed by DSM VPN Center or a third-party OpenVPN/WireGuard client).
- Kill switch requires `xt_owner` in the kernel. Many DSM builds ship without it — the shield logs this and continues in routing-only mode, which is still safe.
- The RPC port push (`FORWARDED_PORT`) requires Transmission's RPC to be enabled and reachable at `127.0.0.1:9091`. Adjust the URL in `start-stop-status` if your setup differs.
- `guard.conf` is preserved on upgrade — new settings are only added if missing (non-destructive migration in `postupgrade`).

---

## Changelog

### 0.1.3
- **Fix**: build workflow reverted to `synology-package-builder@1.3.0` with `arch: noarch` — the Dependabot-triggered upgrade to v2.2.5 combined with `arch: kvmx64` caused the builder to embed `kvmx64` into the INFO file, making DSM reject the package on any physical NAS
- **Fix**: `activate`, `set-port` and `_elevate` now use `TransmissionVpnShield` as the package name — the builder transforms `transmission-vpn-shield` from `package.json` into `TransmissionVpnShield` in the INFO file, so all scripts and paths were broken
- **Fix**: `_elevate` now works when called without DSM environment variables (e.g. from Task Scheduler), no longer requires `env SYNOPKG_PKG_STATUS=…` prefix
- **Fix**: port card in web UI showed duplicate text outside the card due to a `printf` argument mismatch — now fixed
- **New**: `scripts/activate` — one-shot script to complete privilege elevation and start the package; accepts an optional port argument (`activate 56460`) to set `FORWARDED_PORT` in `guard.conf` at the same time; eliminates the need for SSH access during setup
- **New**: `scripts/set-port` — helper script to update `FORWARDED_PORT` in `guard.conf` and restart the package; run it from Task Scheduler as root (`set-port 56460`) whenever your VPN forwarded port changes
- **Improvement**: web UI uses the official package icon in the banner instead of a generic emoji
- **Improvement**: web UI "Public IP via VPN" card now shows the services used to fetch the IP (`ip.gioxx.org` / `api.ipify.org`)
- **Improvement**: web UI has a "Refresh page" button for a full page reload alongside the existing AJAX refresh
- **Improvement**: web UI has a collapsible setup guide with step-by-step instructions for activation and port configuration
- **Improvement**: web UI shows the full `guard.conf` path when `FORWARDED_PORT` is not configured

### 0.1.2
- **Fix**: `index.cgi` now emits `Content-Type` via `printf` as the very first output — fixes blank page regression introduced in 0.1.1
- **Fix**: removed WAN IP leak in `index.cgi` (was fetching real public IP instead of VPN IP)
- **New**: `FORWARDED_PORT` in `guard.conf` — automatically pushes your VPN forwarded port to Transmission via RPC on every start
- **New**: `prestop` command — full cleanup including `rt_tables` entry on uninstall
- **Improvement**: web UI completely redesigned — big green/red banner, icon cards, beginner-friendly layout
- **Improvement**: `guard.conf` rewritten with detailed step-by-step comments for every setting

### 0.1.1
- Package now runs as root to survive DSM reboots

### 0.1.0
- Initial release

---

## About

**License**: MIT
**Author**: [Gioxx](https://github.com/gioxx)
**Issues / feature requests**: [open an issue](https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new)
