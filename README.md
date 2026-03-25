# Transmission VPN Shield (Synology SPK)

👮‍♂️ _To protect and serve Transmission traffic through VPN_ 🙃

![icon](synology/PACKAGE_ICON_256.PNG)

Force Transmission traffic through a VPN interface with UID-based routing, keep LAN access for the web UI/automation, and optionally enforce a kill switch when supported by the NAS iptables build.

> **Current state**: routing + ip rule are enforced; kill switch is applied only if the kernel provides the `owner` match (many DSM builds don't). The package remains DSM-friendly (exit 0) even when the kill switch is unsupported. The service always runs as root thanks to `synology/conf/privilege`, so it survives DSM reboots without manual intervention.

---

## Features

- **UID-scoped routing**: `ip rule` + dedicated routing table force all Transmission traffic through the VPN interface. Nothing else on the NAS is affected.
- **Automatic LAN bypass**: directly-connected LAN routes are copied into the VPN table so the Transmission web UI, Sonarr, Radarr, etc. remain reachable on your local network while torrent traffic exits the VPN.
- **Auto-detects Transmission user**: tries `sc-transmission`, `transmission`, `debian-transmission`, or a custom value from config.
- **Kill switch**: optionally blocks Transmission traffic via `iptables -m owner` if the VPN drops. Falls back gracefully to routing-only protection if the kernel lacks `xt_owner` (still safe — no VPN route = no traffic).
- **VPN forwarded port push**: if your VPN provider assigns you a forwarded port, set `FORWARDED_PORT` in `guard.conf` and the shield will automatically configure Transmission's peer port via RPC on every start.
- **Beginner-friendly web UI**: big green/red status banner, icon cards for each check, raw output hidden in an expandable section for advanced users.
- **Background public IP refresher**: fetches your public IP *through the VPN tunnel* every 2 hours (configurable) and displays it in the UI. Never leaks your real WAN IP.
- **Survives reboots**: runs as root via `synology/conf/privilege` — no manual SSH intervention needed after a DSM reboot.
- **Clean install/uninstall**: idempotent start/stop; `prestop` removes the `rt_tables` entry on uninstall for a full teardown.

---

## Installation

1. Download the latest `.spk` from the [Releases page](https://github.com/gioxx/Syno-TransmissionVPNShield/releases).
2. In DSM → **Package Center** → **Manual Install**, upload the `.spk`.
3. The shield icon appears in the Main Menu. The web UI is also at:
   `/webman/3rdparty/transmission-vpn-shield/index.cgi`
4. Edit the config file if needed (see [Configuration](#configuration)) and restart the package.

---

## Configuration

The config file lives on the NAS at:
```
/var/packages/transmission-vpn-shield/target/conf/guard.conf
```

After editing, restart the package from DSM Package Center, or via SSH:
```sh
sudo synopkg restart transmission-vpn-shield
```

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
3. Edit `guard.conf` on the NAS and set:
   ```
   FORWARDED_PORT="56460"
   ```
4. Save the file and restart the package.

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
| `synology/conf/privilege` | Tells DSM to run the package scripts as root (required for ip/iptables) |
| `src/conf/guard.conf` | Runtime configuration (copied to NAS on install) |
| `src/ui/index.cgi` | Web status page (CGI shell script) |
| `src/ui/config` | DSM UI registration (JSON) |
| `src/ui/index.conf` | DSM webman integration |
| `synology/PACKAGE_ICON_120.PNG` / `_256.PNG` | Package icons |

---

## Quick checks on NAS

```sh
# Check current status
sudo /var/packages/transmission-vpn-shield/scripts/start-stop-status status

# Manually start (e.g. after editing guard.conf)
sudo /var/packages/transmission-vpn-shield/scripts/start-stop-status restart

# Verify Transmission traffic exits the VPN (should show VPN IP, not your real IP)
curl --interface tun0 https://api.ipify.org
```

Expected output from `status`:
```
rt_tables entry present: yes
ip rule present: yes
route present: yes
killswitch present: yes  (or "unsupported" on some DSM kernels — that's OK)
```

---

## Limitations / notes

- This package does **not** manage the VPN connection itself. It assumes `VPN_IF` is already up (e.g. managed by DSM VPN Center or a third-party OpenVPN/WireGuard client).
- Kill switch requires `xt_owner` in the kernel. Many DSM builds ship without it — the shield logs this and continues in routing-only mode, which is still safe.
- The RPC port push (`FORWARDED_PORT`) requires Transmission's RPC to be enabled and reachable at `127.0.0.1:9091`. Adjust the URL in `start-stop-status` if your setup differs.
- `guard.conf` is preserved on upgrade — new settings are only added if missing (non-destructive migration in `postupgrade`).

---

## Changelog

### 0.1.2
- **Fix**: `index.cgi` now emits `Content-Type` via `printf` as the very first output — fixes blank page regression introduced in 0.1.1
- **Fix**: removed WAN IP leak in `index.cgi` (was fetching real public IP instead of VPN IP)
- **New**: `synology/conf/privilege` — package always runs as root; no manual SSH needed after DSM reboot
- **New**: `FORWARDED_PORT` in `guard.conf` — automatically pushes your VPN forwarded port to Transmission via RPC on every start
- **New**: `prestop` command — full cleanup including `rt_tables` entry on uninstall
- **Improvement**: web UI completely redesigned — big green/red banner, icon cards, beginner-friendly layout
- **Improvement**: `guard.conf` rewritten with detailed step-by-step comments for every setting
- **Improvement**: GitHub Action pinned back to `synology-package-builder@1.3.0` (v2.x broke CGI loading) and `actions/checkout@v4`
- **Improvement**: `arch` changed from `x86_64` to `noarch` (supports ARM NAS models too)
- **Improvement**: `ip route replace` instead of `ip route add` — idempotent, no errors on restart

### 0.1.1
- Package now runs as root to survive DSM reboots (partially — completed properly in 0.1.2 with `privilege` file)
- Bumped GitHub Actions dependencies

### 0.1.0
- Initial release

---

## About

**License**: MIT  
**Author**: [Gioxx](https://github.com/gioxx)  
**Issues / feature requests**: [open an issue](https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new)
