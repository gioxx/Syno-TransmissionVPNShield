# Transmission VPN Shield (Synology SPK)

👮‍♂️ _To protect and serve Transmission traffic through VPN_ 🙃

![icon](synology/PACKAGE_ICON_256.PNG)

Force Transmission traffic through a VPN interface with UID-based routing, keep LAN access for the web UI/automation, and optionally enforce a kill switch when supported by the NAS kernel.

---

## Features

- **UID-scoped routing**: `ip rule` + a dedicated routing table force all Transmission traffic through the VPN interface. Nothing else on the NAS is affected.
- **Automatic LAN bypass**: directly-connected LAN routes are copied into the VPN table so the Transmission web UI, Sonarr, Radarr, etc. remain reachable on your local network while torrent traffic exits the VPN.
- **Auto-detects Transmission user**: tries `sc-transmission`, `transmission`, `debian-transmission`, or a custom value from `guard.conf`.
- **Kill switch** _(where supported)_: blocks Transmission traffic via `iptables -m owner` if the VPN drops. Falls back gracefully to routing-only protection if the kernel lacks `xt_owner` — still safe, because no VPN route means no traffic.
- **VPN forwarded port push**: set `FORWARDED_PORT` in `guard.conf` and the shield configures Transmission's peer port via RPC on every start.
- **Beginner-friendly web UI**: green/red status banner, icon cards for each check, Transmission running status, raw output in an expandable section.
- **Background public IP refresher**: fetches your public IP _through the VPN tunnel_ every 2 hours (configurable) and shows it in the UI. Never leaks your real WAN IP.
- **Stops Transmission on shutdown**: whenever VPN Shield stops or is uninstalled, Transmission is stopped first so it never runs without protection.
- **Uptime Kuma push monitoring** _(optional)_: outbound-only heartbeats to a Kuma "Push" monitor with the full check state in the message — no inbound port to expose, no DSM auth bypass, the per-monitor URL acts as the token. Includes a cached Transmission `port-test` so a closed forwarded port also flips the alert.
- **Clean uninstall**: `preuninst` removes ip rules, ip routes, and the `rt_tables` entry from the kernel before the package is deleted.

---

## Installation

> **Why the extra step?** DSM 7.2+ blocks unsigned third-party packages from declaring root privileges at install time. The package installs as a normal user, then a one-time Task Scheduler job completes the elevation and applies the routing rules.

### Step 1 — Install the package

1. Download the latest `.spk` from the [Releases page](https://github.com/gioxx/Syno-TransmissionVPNShield/releases).
2. In DSM → **Package Center** → top-right menu → **Manual Install**, upload the `.spk`.
3. The package will show as **Installed** (not running). Open its web UI — it will display an activation guide.

### Step 2 — One-time activation via Task Scheduler

This step applies the routing rules as root. Run it once after install and again after any upgrade.

1. In DSM → **Control Panel** → **Task Scheduler** → **Create** → **Triggered Task** → **User-defined script**.
2. Fill in the form:
   - **Task name**: `Activate Transmission VPN Shield` (or anything you like)
   - **User**: `root`
   - **Enabled**: leave it **unchecked**
3. Switch to the **Task Settings** tab and paste one of these commands:

   **Without VPN forwarded port:**
   ```
   /var/packages/transmission-vpn-shield/scripts/activate
   ```
   **With VPN forwarded port** (replace `56460` with yours):
   ```
   /var/packages/transmission-vpn-shield/scripts/activate 56460
   ```

4. Click **OK**, then select the task in the list and click **Run**.
5. After a few seconds, open the web UI — the shield should show as active.

The activation page in the web UI has a **Check activation status** button that confirms when it's done.

### Step 3 — Start Transmission

Once the shield is active, start Transmission from **DSM → Package Center → Transmission → Start**. This ensures Transmission launches through the VPN tunnel.

The web UI shows a **Transmission** status row (Running / Stopped) when the shield is fully active.

### Step 4 — Web UI

The shield icon appears in the DSM Main Menu. The web UI is also directly accessible at:
```
http://<your-nas-ip>:5000/webman/3rdparty/transmission-vpn-shield/index.cgi
```

---

## Configuration

The config file lives on the NAS at:
```
/var/packages/transmission-vpn-shield/target/conf/guard.conf
```

After editing, restart the package from DSM **Package Center**.

| Setting | Default | Description |
|---|---|---|
| `TRANSMISSION_USER` | `sc-transmission` | System user running Transmission. Auto-detected if not set. |
| `VPN_IF` | `tun0` | VPN interface name. Use `ip link show` to find yours. WireGuard is typically `wg0`. |
| `RT_TABLE_ID` | `200` | Internal routing table ID. Change only if it conflicts with another package. |
| `RT_TABLE_NAME` | `transmissionvpn` | Internal routing table name (used in `rt_tables` for readability). |
| `ENFORCE_KILLSWITCH_WHEN_VPN_DOWN` | `1` | `1` = block Transmission if VPN drops. `0` = allow fallback (not recommended). |
| `PUBLIC_IP_REFRESH_SEC` | `7200` | Seconds between background VPN IP refreshes. `0` disables it. |
| `FORWARDED_PORT` | *(empty)* | VPN forwarded port — see below. |
| `KUMA_PUSH_URL` | *(empty)* | Uptime Kuma "Push" monitor URL. Empty disables the feature. See below. |
| `KUMA_PUSH_INTERVAL_SEC` | `60` | Seconds between heartbeats. Set Kuma's "Heartbeat Interval" slightly higher (e.g. 75s) to tolerate one missed push. |
| `PORT_TEST_INTERVAL_SEC` | `600` | Seconds between Transmission `port-test` RPC calls. Result is cached so the push loop stays cheap. `0` disables port-test. |

---

## VPN forwarded port (recommended for better speeds)

Some VPN providers let you **forward a port** through the VPN tunnel, allowing other peers to connect directly to you. This significantly improves speeds and seeding ratios.

**You do NOT need to open this port on your router or DSM firewall.** Traffic enters through the VPN tunnel.

### How to set it up

**Option A — at activation time** (easiest, no SSH):
```
/var/packages/transmission-vpn-shield/scripts/activate 56460
```

**Option B — after activation**, via Task Scheduler as root:
```
/var/packages/transmission-vpn-shield/scripts/set-port 56460
```

**Option C — edit `guard.conf` directly:**
```
FORWARDED_PORT="56460"
```
Then restart the package from Package Center.

The web UI shows the configured port with a link to check if it's reachable from the internet.

---

## Uptime Kuma push monitoring (optional)

If you run [Uptime Kuma](https://github.com/louislam/uptime-kuma) somewhere on your network (a separate VM, a Docker host, a Raspberry Pi…) you can have the shield push its health to a "Push" monitor every minute. The NAS only makes outbound HTTPS requests — **nothing new is exposed on the LAN**, and the per-monitor URL Kuma generates acts as a token, so no extra authentication is needed.

### Why a push monitor (and not a pull endpoint)?

The shield's web UI lives under DSM's `/webman/3rdparty/...`, which always requires a valid DSM session. A pull-based health endpoint would either need an authenticated Kuma client (fragile) or a brand-new listener exposed on a separate port (extra attack surface). Pushing to Kuma sidesteps both: the NAS initiates the connection, and missing heartbeats are themselves the alert signal.

### What gets reported

On every tick the daemon evaluates the same checks shown in the web UI:

- VPN interface up with a valid IPv4 address
- `rt_tables` entry, ip rule for the Transmission UID, default route via the VPN
- Kill switch presence (reported, but does not flip the status — see below)
- Transmission `port-test` RPC against the forwarded port (cached between calls)

The status is `up` only when VPN, routing rules, route and ip rule are all in place **and** the port-test result is not `closed`. Otherwise it's `down`. The full check state is sent in the `msg` field, so Kuma displays something like:

```
vpn=yes rt=yes rule=yes route=yes ks=yes port=open
```

Kill-switch state is reported but does not alone flip the alert, because on DSM kernels without `xt_owner` it stays `no` by design while routing alone still protects traffic. If you'd rather have a stricter policy, open an issue and we can make it configurable.

### How to set it up

1. **In Uptime Kuma**: create a new monitor, type **Push**. Copy the unique URL it generates (looks like `https://kuma.example.com/api/push/abc123`). Set "Heartbeat Interval" to roughly your push interval plus some slack — for example, push every 60s, heartbeat 75s.
2. **On the NAS**: edit `/var/packages/transmission-vpn-shield/target/conf/guard.conf` and set:
   ```
   KUMA_PUSH_URL="https://kuma.example.com/api/push/abc123"
   ```
   (Optionally tune `KUMA_PUSH_INTERVAL_SEC` and `PORT_TEST_INTERVAL_SEC`.)
3. **Restart the package** from DSM Package Center, or via SSH:
   ```
   sudo synopkg restart transmission-vpn-shield
   ```

The push daemon starts automatically together with the shield, and is killed on stop. When the package is stopped cleanly, the daemon sends one final `down` heartbeat so Kuma flips the monitor immediately instead of waiting for the heartbeat to time out.

### Test from SSH

```
sudo /var/packages/transmission-vpn-shield/scripts/guard-push once
```

This runs a single check and pushes one heartbeat to Kuma, then exits — useful to verify connectivity without restarting the package. Logs go to `/var/log/messages` under tag `transmission-vpn-shield-push`.

### Disabling

Leave `KUMA_PUSH_URL=""` (the default). With an empty URL the daemon never starts and no outbound calls are made.

---

## How it works

### `activate` (run as root via Task Scheduler)
1. Optionally writes `FORWARDED_PORT` to `guard.conf`.
2. Runs `postinst` as root — updates the privilege file so DSM calls `start`/`stop`/`status` as root on subsequent boots; removes the needs-activation flag.
3. Calls `start-stop-status start` **directly as root** — applies routing rules immediately without waiting for DSM.
4. Notifies DSM via `synopkg start` to register the package as running.

### `start`
1. Loads config and resolves Transmission UID.
2. Adds entry to `/etc/iproute2/rt_tables` for the dedicated routing table (by name, for readability — all `ip` commands use the numeric ID directly so this is optional).
3. Sets a default route via the VPN interface in the dedicated table (using table ID `200`).
4. Copies LAN directly-connected routes into the dedicated table (keeps the web UI reachable locally).
5. Adds `ip rule uidrange UID-UID lookup 200`.
6. Optionally adds kill-switch rule: `OUTPUT -m owner --uid-owner UID ! -o VPN_IF -j DROP` (skipped with a log entry if `xt_owner` is unsupported by the kernel).
7. Pushes `FORWARDED_PORT` to Transmission via RPC (if configured).
8. Starts background public-IP refresher daemon.
9. Starts the Kuma push daemon (only if `KUMA_PUSH_URL` is set).

### `stop` / `prestop`
Removes ip rules, kill switch (if present), flushes routes in the dedicated table, stops Transmission first, kills the public-IP and Kuma push daemons, and (if `KUMA_PUSH_URL` is set) sends a final `down` heartbeat so Kuma flips immediately. `prestop` also removes the `rt_tables` entry.

> **Note on stop via Package Center**: DSM calls `stop`/`prestop` as `package` user (not root) unless the privilege file has been updated by `activate`. If the privilege elevation is in place, stop/prestop run as root and clean up correctly. If not, the kernel rules remain until the next reboot.

### Web UI (`index.cgi`)
Runs as the DSM web server user (not root). Displays: VPN tunnel status, public IP via VPN, traffic routing (ip rule + route checks), kill switch, Transmission user, forwarded port, and Transmission running status (checked via the RPC port). All status checks use read-only commands that don't require root.

---

## Files of interest

| File | Purpose |
|---|---|
| `synology/scripts/start-stop-status` | Lifecycle logic: routing, ip rule, kill switch, RPC port push, daemon supervision |
| `synology/scripts/guard-push` | Uptime Kuma push daemon (loop / once / final-down modes); cached Transmission `port-test` |
| `synology/scripts/activate` | One-time activation: applies privilege elevation and routing rules as root |
| `synology/scripts/_elevate` | Writes the final `privilege` file with `run-as:root` for all ctrl-script actions (no `jq` needed) |
| `synology/scripts/set-port` | Updates `FORWARDED_PORT` in `guard.conf` and restarts the package |
| `synology/conf/privilege` | Ships with `run-as:package` so DSM accepts the unsigned package; updated by `_elevate` at activation |
| `src/conf/guard.conf` | Runtime configuration (copied to NAS on install) |
| `src/ui/index.cgi` | Web status page (CGI shell script, runs without root) |

---

## Limitations

- **VPN not managed**: this package does not manage the VPN connection itself. It assumes `VPN_IF` is already up (e.g. managed by DSM VPN Center or a third-party OpenVPN/WireGuard client).
- **Kill switch requires `xt_owner`**: many DSM builds ship without it — the shield logs this and continues in routing-only mode, which is still safe.
- **Kill switch not removed on Package Center stop**: DSM may call `stop` without root (if the privilege file hasn't been updated by `activate`), so kill switch rules added at activation time may persist until reboot. Routing rules have the same behaviour.
- **Re-run activate after upgrade**: DSM overwrites the privilege file on upgrade, so `activate` must be run again after each package update.
- **RPC port**: `FORWARDED_PORT` push requires Transmission's RPC to be enabled and reachable at `127.0.0.1:9091`.
- **Kuma push not added on upgrade**: `postinst` does not overwrite an existing `guard.conf`, so users upgrading from a previous version need to add the new `KUMA_PUSH_URL` / `KUMA_PUSH_INTERVAL_SEC` / `PORT_TEST_INTERVAL_SEC` lines manually (they default to off, so existing setups are unaffected if the variables are missing).

---

## Changelog

### Unreleased
- **New**: Uptime Kuma push monitoring. Outbound-only heartbeats from the NAS to a Kuma "Push" monitor; status flips `down` if VPN, routing rules, route, ip rule, or Transmission `port-test` fail. Configured via `KUMA_PUSH_URL` (empty = disabled) plus optional `KUMA_PUSH_INTERVAL_SEC` and `PORT_TEST_INTERVAL_SEC` in `guard.conf`.
- **New**: `synology/scripts/guard-push` daemon (modes: `loop`, `once`, `final-down`) supervised by `start-stop-status`; sends a final `down` heartbeat on stop so Kuma flips immediately instead of waiting on heartbeat timeout.
- **New**: cached Transmission `port-test` RPC check — a closed forwarded port now also flips the alert, catching scenarios where the tunnel is up but inbound peer connections are broken.

### 0.1.4
- **Fix**: package name `transmission-vpn-shield` now used consistently in all scripts, paths, and UI — a previous commit had incorrectly changed them all to `TransmissionVpnShield`, which broke config loading, webman symlinks, and the activation flow
- **Fix**: routing rules now use the numeric table ID (`200`) directly in all `ip route`/`ip rule` commands — bypasses the `/etc/iproute2/rt_tables` write dependency so rules apply even if the file is read-only
- **Fix**: `_elevate` now writes the final privilege file directly via heredoc instead of using `jq` to merge — removes external dependency that silently failed on NAS builds without `jq`
- **Fix**: `activate` now calls `start-stop-status start` directly as root before notifying DSM — routing rules are applied immediately regardless of whether DSM re-reads the privilege file
- **Fix**: `preuninst` now calls `start-stop-status prestop` directly before removing the package — ensures ip rules and routes are cleaned from the kernel on uninstall
- **New**: package no longer goes into **Error** state on install — `postinst` always returns 0 and creates a `needs-activation` flag; the web UI shows an activation guide
- **New**: web UI activation page with exact Task Scheduler commands (with and without forwarded port) and a **Check activation status** button
- **New**: web UI shows a **Transmission status** row (Running / Stopped, checked via RPC port) when the shield is fully active
- **New**: yellow notice bar when routing rules are not yet active, with exact instructions to stop/start the package
- **Improvement**: "Refresh raw output" button moved inside the Advanced panel; top-level action is just "Reload page"
- **Improvement**: kill switch card honestly describes the DSM stop limitation and routing-only fallback

### 0.1.3
- **Fix**: build workflow reverted to `synology-package-builder@1.3.0` with `arch: kvmx64`
- **New**: `scripts/activate` — one-shot root script; accepts optional port argument
- **New**: `scripts/set-port` — updates `FORWARDED_PORT` and restarts the package
- **Improvement**: web UI icon, IP source info, refresh button, collapsible setup guide

### 0.1.2
- **Fix**: `Content-Type` emitted first in `index.cgi`; removed WAN IP leak
- **New**: `FORWARDED_PORT` in `guard.conf` with RPC push on start
- **New**: `prestop` command for full cleanup on uninstall
- **Improvement**: web UI redesigned with banner and icon cards

### 0.1.1
- Package now requests root privileges to survive DSM reboots

### 0.1.0
- Initial release

---

## About

**License**: MIT
**Author**: [Gioxx](https://github.com/gioxx)
**Issues / feature requests**: [open an issue](https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new)
