# Transmission VPN Shield (Synology SPK)
👮‍♂️ _To protect and serve Transmission traffic through VPN_ 🙃

![icon](synology/PACKAGE_ICON_256.PNG)

Force Transmission traffic through a VPN interface with UID-based routing, keep LAN access for the web UI/automation, and optionally enforce a kill switch when supported by the NAS iptables build.

> **Current state**: routing + ip rule are enforced; kill switch is applied only if the kernel provides the `owner` match (many DSM builds don’t). The package remains DSM‑friendly (exit 0) even when the kill switch is unsupported.

## Features
- UID‑scoped `ip rule` and dedicated routing table; default route via VPN interface (configurable).
- Automatic LAN bypass: copies directly‑connected LAN routes into the VPN table so the Transmission UI/Sonarr/Radarr remain reachable on LAN while torrent traffic exits the VPN.
- Auto‑detects Transmission user (`sc-transmission`, `transmission`, `debian-transmission`, or custom from config).
- Web UI (`/webman/3rdparty/transmission-vpn-shield/index.cgi`) with live status, refresh, public IP via VPN, and quick link to an external port check.
- Idempotent start/stop scripts; stop cleans ip rule and routes (keeps `rt_tables` entry).
- Monitor-only fallback when kernel lacks iptables owner match (no traffic leak: VPN route still required for the UID).
- Stores VPN public IP in `/var/packages/transmission-vpn-shield/var/public_ip` (fetched via tunnel) and displays it in the UI; shows “unsupported” if kill switch is unavailable.
- Background public-IP refresher (default every 2h; configurable via `PUBLIC_IP_REFRESH_SEC`) plus immediate refresh on start/status.

## Configuration
Edit on the NAS (or in `src/conf/guard.conf` before build):
```
TRANSMISSION_USER="transmission"   # auto-detect overrides if user is missing
VPN_IF="tun0"
RT_TABLE_ID="200"
RT_TABLE_NAME="transmissionvpn"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="1"  # kill switch only if iptables owner is supported
```

## How it works
1. `start`:
   - Loads config and resolves Transmission UID (auto-detect).
   - Ensures `rt_tables` entry; sets default route in the dedicated table via VPN IF.
   - Copies LAN directly-connected routes into the dedicated table (keeps UI reachable on LAN).
   - Adds `ip rule uidrange UID-UID lookup <table>`.
   - Tries to add kill-switch rule `OUTPUT -m owner --uid-owner UID ! -o VPN_IF -j DROP` (skipped/logged if unsupported).
2. `stop`:
   - Removes ip rule and kill switch (if present), flushes routes in the dedicated table, leaves `rt_tables` entry.
3. UI:
   - Shows config, status (rt_tables/ip rule/route/kill switch), public IP via VPN, port-check link, and command output.

## Installation
Use the official Synology Package Builder (or the GitHub Action already set up) pointing to `./src` and `synology/` assets to produce the `.spk`, then install it via DSM Package Center. After install, the UI appears in the Main Menu and at `/webman/3rdparty/transmission-vpn-shield/index.cgi`.

## Files of interest
- `synology/scripts/start-stop-status` – lifecycle logic (routing, ip rule, optional kill switch).
- `src/conf/guard.conf` – runtime defaults (copied to target on install).
- `src/ui/index.cgi` – status page.
- `src/ui/config`, `src/ui/index.conf` – DSM UI registration.
- `synology/PACKAGE_ICON_120.PNG`, `synology/PACKAGE_ICON_256.PNG` – icons.

## Limitations / notes
- Kill switch depends on iptables `owner` match (xt_owner). On kernels without it, you’ll see “kill switch unsupported”; routing still prevents WAN leaks when VPN is down (no valid route for the UID).
- This package doesn’t manage the VPN connection itself; it assumes `VPN_IF` is up (e.g., managed by DSM VPN client).
- If you need a stricter fail-fast when VPN is down, we can add a blackhole route or fwmark-based drop in the table.
- Uninstalling the package removes routes, ip rules, kill switch, and the web UI symlink; only the `rt_tables` entry is left intact (harmless).
- Pre-uninstall now also removes the `rt_tables` entry (`200 transmissionvpn`) on uninstall for a clean teardown.

## Quick checks on NAS
```
/var/packages/transmission-vpn-shield/scripts/start-stop-status start
/var/packages/transmission-vpn-shield/scripts/start-stop-status status
```
Expect `rt_tables entry: yes`, `ip rule: yes`, `route: yes`. Kill switch may be `unsupported` on some DSM builds.
