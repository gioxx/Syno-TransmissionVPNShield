# Transmission VPN Shield (Synology SPK)

👮‍♂️ _To protect and serve Transmission traffic through VPN_ 🙃

![icon](synology/PACKAGE_ICON_256.PNG)

Force Transmission traffic through a VPN interface with UID-based routing, keep LAN access for the web UI/automation, and optionally enforce a kill switch when supported by the NAS kernel.

---

## Features

- **UID-scoped routing**: `ip rule` + a dedicated routing table force all Transmission traffic through the VPN interface, for **both IPv4 and IPv6**. Nothing else on the NAS is affected.
- **Self-healing**: a background reconcile daemon re-applies routing, the ip rules and the fail-closed blackhole every `RECONCILE_INTERVAL_SEC` seconds (default 30). The shield recovers on its own after a VPN reconnect, an unlucky boot order (shield started before the tunnel came up) or a package/Transmission restart — no manual stop/start.
- **Fail-closed, always**: when the VPN is down the shield installs a `blackhole` default route in the dedicated table (v4 and v6), so Transmission traffic is dropped, never leaked — even on kernels without `xt_owner`.
- **IPv6 handled**: `IPV6_MODE` in `guard.conf` — `route` (through the tunnel, default), `block` (blackhole, no IPv6 for torrents), or `off`.
- **Automatic LAN bypass**: directly-connected LAN routes are copied into the VPN table so the Transmission web UI, Sonarr, Radarr, etc. remain reachable on your local network while torrent traffic exits the VPN.
- **Auto-detects Transmission**: resolves the service user (`sc-transmission`, `transmission`, `debian-transmission`, or `guard.conf`) *and* the DSM package name (`transmission`, `Transmission`, `sc-transmission`) so stop/uninstall really stops Transmission.
- **Kill switch** _(where supported)_: additionally blocks Transmission traffic via `iptables -m owner` if the VPN drops. Falls back gracefully to the blackhole route if the kernel lacks `xt_owner` — still fully leak-proof.
- **VPN forwarded port push**: set `FORWARDED_PORT` in `guard.conf` and the shield keeps Transmission's peer port in sync via RPC (with credentials from `guard.secret` when RPC auth is enabled).
- **Beginner-friendly web UI**: green/red status banner, icon cards for each check, Transmission running status, raw output in an expandable section.
- **Background public IP refresher**: fetches your public IP _through the VPN tunnel_ every 2 hours (configurable) and shows it in the UI. Never leaks your real WAN IP.
- **Stops Transmission on shutdown**: whenever VPN Shield stops or is uninstalled, Transmission is stopped first (by its real package name) so it never runs without protection. Optionally (`AUTOSTART_TRANSMISSION=1`) it is restarted on the shield's next start — but only once the VPN is up and routing is applied.
- **Consolidated log**: all shield activity goes to `var/shield.log` (size-capped, no rotation config needed) and is shown in the web UI.
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
/var/packages/transmission-vpn-shield/etc/guard.conf
```

This is the folder DSM actually preserves across upgrades for `support_conf_folder=yes` packages. The historical path `/var/packages/transmission-vpn-shield/target/conf/guard.conf` is a symlink to the same file for convenience (existing notes and Task Scheduler scripts that point there keep working) — but avoid editing through it with tools that replace files instead of writing in place (e.g. `sed -i`), as that detaches the symlink from its persistent target. Edit `etc/guard.conf` directly, or use `activate`/`set-port`, which do this correctly.

> **Upgrading from 0.1.8 or earlier?** Those versions stored `guard.conf` under `conf/guard.conf`, which is *not* preserved by DSM — it is silently reset to defaults on every install/upgrade. If you lost `FORWARDED_PORT` or `KUMA_PUSH_URL` after an upgrade, that's why. From 0.1.9 the file lives under `etc/guard.conf` and survives for good — you'll need to re-enter your settings one last time after upgrading to 0.1.9.

After editing, restart the package from DSM **Package Center**.

| Setting | Default | Description |
|---|---|---|
| `TRANSMISSION_USER` | `sc-transmission` | System user running Transmission. Auto-detected if not set. |
| `VPN_IF` | `tun0` | VPN interface name. Use `ip link show` to find yours. WireGuard is typically `wg0`. |
| `RT_TABLE_ID` | `200` | Internal routing table ID. Change only if it conflicts with another package. |
| `RT_TABLE_NAME` | `transmissionvpn` | Internal routing table name (used in `rt_tables` for readability). |
| `ENFORCE_KILLSWITCH_WHEN_VPN_DOWN` | `1` | `1` = also add the `xt_owner` kill switch when the VPN is down (belt-and-braces on top of the blackhole route). `0` = blackhole only. |
| `RECONCILE_INTERVAL_SEC` | `30` | Seconds between self-heal reconcile passes. Lower = faster recovery after a VPN flap, more wakeups. |
| `IPV6_MODE` | `route` | `route` = policy-route Transmission's IPv6 through the VPN (falls back to blackhole when the tunnel is down). `block` = always blackhole IPv6. `off` = don't touch IPv6 (possible leak). Needs kernel ≥ 4.10 for `route`/`block`. |
| `AUTOSTART_TRANSMISSION` | `0` | `1` = after the shield starts, restart Transmission too — but only when the VPN is up and the default route is already in the dedicated table, so it is never launched unprotected. Saves a manual start after every shield upgrade/reboot. `0` = leave it stopped, start it yourself. |
| `PUBLIC_IP_REFRESH_SEC` | `7200` | Seconds between background VPN IP refreshes. `0` disables it. |
| `FORWARDED_PORT` | *(empty)* | VPN forwarded port — see below. |
| `RPC_PORT` | `9091` | Transmission RPC port used for the peer-port push and `port-test`. |
| `RPC_USER` / `RPC_PASS` | *(empty)* | **Set in `etc/guard.secret`, not here.** Transmission RPC credentials — required only if Transmission has RPC authentication enabled, otherwise the peer-port push fails with HTTP 401. `guard.secret` is a separate `chmod 600` file so the world-readable `guard.conf` never holds the password. |
| `KUMA_PUSH_URL` | *(empty)* | Uptime Kuma "Push" monitor URL. Empty disables the feature. See below. |
| `KUMA_PUSH_INTERVAL_SEC` | `60` | Seconds between heartbeats. Set Kuma's "Heartbeat Interval" slightly higher (e.g. 75s) to tolerate one missed push. |
| `PORT_TEST_INTERVAL_SEC` | `600` | Seconds between Transmission `port-test` RPC calls. Result is cached so the push loop stays cheap. `0` disables port-test. |

New keys introduced by an upgrade are appended to your existing `etc/guard.conf` automatically by `postinst` (with their default values), so you never lose settings and never have to hand-merge the template.

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
/var/packages/transmission-vpn-shield/etc/guard.conf
```
```
FORWARDED_PORT="56460"
```
Then restart the package from Package Center.

The web UI shows the configured port with a link to check if it's reachable from the internet.

### RPC authentication

The shield sets Transmission's peer port over RPC (`127.0.0.1:${RPC_PORT}`). If Transmission has **"Enable authentication"** checked in its Remote Access settings, unauthenticated RPC calls get an HTTP 401 and the port push silently fails. Put the credentials in the root-only secret file:

```
/var/packages/transmission-vpn-shield/etc/guard.secret
```
```
RPC_USER="youruser"
RPC_PASS="yourpass"
```

`guard.secret` is created (empty) on install and `chmod 600`, so the world-readable `guard.conf` never carries the password. Restart the package after editing.

---

## Uptime Kuma push monitoring (optional)

If you run [Uptime Kuma](https://github.com/louislam/uptime-kuma) somewhere on your network (a separate VM, a Docker host, a Raspberry Pi…) you can have the shield push its health to a "Push" monitor every minute. The NAS only makes outbound HTTPS requests — **nothing new is exposed on the LAN**, and the per-monitor URL Kuma generates acts as a token, so no extra authentication is needed.

### Why a push monitor (and not a pull endpoint)?

The shield's web UI lives under DSM's `/webman/3rdparty/...`, which always requires a valid DSM session. A pull-based health endpoint would either need an authenticated Kuma client (fragile) or a brand-new listener exposed on a separate port (extra attack surface). Pushing to Kuma sidesteps both: the NAS initiates the connection, and missing heartbeats are themselves the alert signal.

### What gets reported

On every tick the daemon evaluates the same checks shown in the web UI:

- VPN interface up with a valid IPv4 address
- `rt_tables` entry, IPv4 UID rule, default route via the VPN
- IPv6 UID rule + route matching `IPV6_MODE` (`v6=` in the message; `na` when `IPV6_MODE=off`)
- reconcile daemon alive (`recon=`)
- Kill switch presence (reported, but does not flip the status — see below)
- Transmission `port-test` RPC against the forwarded port (cached between calls)

The status is `up` only when VPN, the IPv4 route + rule, and the IPv6 protection (unless `IPV6_MODE=off`) are all in place **and** the port-test result is not `closed`. Otherwise it's `down`. The full check state is sent in the `msg` field, so Kuma displays something like:

```
vpn=yes rt=yes rule=yes route=yes v6=yes ks=yes recon=yes port=open
```

Kill-switch state is reported but does not alone flip the alert, because on DSM kernels without `xt_owner` it stays `no` by design while routing alone still protects traffic. If you'd rather have a stricter policy, open an issue and we can make it configurable.

### How to set it up

1. **In Uptime Kuma**: create a new monitor, type **Push**. Copy the unique URL it generates (looks like `https://kuma.example.com/api/push/abc123`). Set "Heartbeat Interval" to roughly your push interval plus some slack — for example, push every 60s, heartbeat 75s.
2. **On the NAS**: edit `/var/packages/transmission-vpn-shield/etc/guard.conf` and set:
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

This runs a single check and pushes one heartbeat to Kuma, then exits — useful to verify connectivity without restarting the package. Output is in `var/shield.log`.

### Disabling

Leave `KUMA_PUSH_URL=""` (the default). With an empty URL the daemon never starts and no outbound calls are made.

### Recovering from a heartbeat down

Since 0.2.0 the reconcile daemon fixes most "down" causes on its own within `RECONCILE_INTERVAL_SEC` — try `sudo /var/packages/transmission-vpn-shield/scripts/start-stop-status reconcile` first. If it's still down, the full reset is: stop Transmission, stop the shield, start the shield, start Transmission. `synology/scripts/recover-heartbeat` automates that in one shot.

1. In DSM → **Control Panel** → **Task Scheduler** → **Create** → **Triggered Task** → **User-defined script**.
2. Fill in the form:
   - **Task name**: `Recover Transmission VPN Shield heartbeat` (or anything you like)
   - **User**: `root`
   - **Enabled**: leave it **unchecked** (run on demand, not scheduled)
3. In the **Task Settings** tab, paste:
   ```
   /var/packages/transmission-vpn-shield/scripts/recover-heartbeat
   ```
4. Click **OK**. Whenever you see a heartbeat down alert, select the task and click **Run** — check the run log for the step-by-step output.

---

## How it works

### `activate` (run as root via Task Scheduler)
1. Optionally writes `FORWARDED_PORT` to `guard.conf`.
2. Runs `postinst` as root — updates the privilege file so DSM calls `start`/`stop`/`status` as root on subsequent boots; removes the needs-activation flag.
3. Calls `start-stop-status start` **directly as root** — applies routing rules immediately without waiting for DSM.
4. Notifies DSM via `synopkg start` to register the package as running.

### `reconcile` (the heart — run once by `start`, then on a timer by the daemon)
Idempotent, silent unless something actually changes:
1. Loads config, resolves the Transmission UID.
2. **IPv4 table 200**: VPN up → `default dev VPN_IF` (+ LAN routes synced in); VPN down → `blackhole default`. The table is never left empty, so there is no window where Transmission traffic falls through to `main` and leaks.
3. **IPv6 table 200** (per `IPV6_MODE`): `route` → mirror of IPv4; `block` → always `blackhole default`; `off` → untouched.
4. `ip rule` / `ip -6 rule` `uidrange UID-UID lookup 200` (v6 skipped in `off` mode; a one-time warning is logged if the kernel is too old for per-UID v6 rules).
5. Kill switch (`xt_owner`) re-asserted where supported.
6. Pushes `FORWARDED_PORT` to Transmission via RPC **only if** the current peer port differs (no RPC churn every tick).

### `start`
1. Resolves the Transmission UID, runs one `reconcile`.
2. Starts the background daemons: public-IP refresher, **reconcile** (`RECONCILE_INTERVAL_SEC`), and Kuma push (only if `KUMA_PUSH_URL` is set).
3. If `AUTOSTART_TRANSMISSION=1` **and** the VPN is up **and** the default route is in the dedicated table, restarts Transmission (never into an unprotected state). Otherwise Transmission stays stopped — the shield never starts it by default, so after a shield upgrade you start it yourself once the UI is green.

### `status`
Prints the current v4/v6 route + rule state, kill-switch state, forwarded port and the reconcile-daemon state. If called **as root** and a run marker (`var/enabled`, created by `start`, removed by `stop`/`prestop`) is present, it also restarts the reconcile daemon should its PID be stale — so a crashed daemon recovers on the next poll, but a `status` call after a clean `stop` never brings the package back up. The web UI's `status` call runs as the unprivileged web user and has no such side effect.

### `stop` / `prestop`
Stops the reconcile daemon **first** (so it can't re-add routes after the flush), then removes v4+v6 ip rules, the kill switch, flushes v4+v6 routes, stops the other daemons, stops Transmission (by its resolved package name), and sends a final Kuma `down`. `prestop` also removes the `rt_tables` entry.

> **Note on stop via Package Center**: DSM calls `stop`/`prestop` as `package` user (not root) unless the privilege file has been updated by `activate`. If the privilege elevation is in place, stop/prestop run as root and clean up correctly. If not, the kernel rules remain until the next reboot.

### Web UI (`index.cgi`)
Runs as the DSM web server user (not root). Displays: VPN tunnel status, public IP via VPN, traffic routing (v4 + v6 route/rule, blackhole state), auto-heal daemon state, kill switch, Transmission user, forwarded port, Transmission running status, and a tail of `shield.log`. All checks use read-only commands that don't require root. It never reads `guard.secret`.

---

## Files of interest

| File | Purpose |
|---|---|
| `synology/scripts/_common.sh` | Shared library sourced by all daemons: config loading, identity/package resolution, route/rule/killswitch helpers, `rpc_call`, logging |
| `synology/scripts/start-stop-status` | Lifecycle logic + the idempotent `reconcile` action; daemon supervision |
| `synology/scripts/guard-reconcile` | Self-heal daemon: `start-stop-status reconcile` every `RECONCILE_INTERVAL_SEC` |
| `synology/scripts/guard-push` | Uptime Kuma push daemon (loop / once / final-down modes); cached Transmission `port-test` |
| `synology/conf/guard.secret` | Template for the `chmod 600` RPC-credentials file (`RPC_USER` / `RPC_PASS`) |
| `tests/reconcile.sh` | Root integration test for `reconcile` (veth fixture + dedicated table 199) |
| `synology/scripts/activate` | One-time activation: applies privilege elevation and routing rules as root |
| `synology/scripts/recover-heartbeat` | One-shot Task Scheduler script: stop Transmission → restart shield → start Transmission, to recover from a Kuma heartbeat down |
| `synology/scripts/_elevate` | Writes the final `privilege` file with `run-as:root` for all ctrl-script actions (no `jq` needed) |
| `synology/scripts/set-port` | Updates `FORWARDED_PORT` in `guard.conf` and restarts the package |
| `synology/conf/privilege` | Ships with `run-as:package` so DSM accepts the unsigned package; updated by `_elevate` at activation |
| `synology/conf/guard.conf` | Shipped default template only — NOT persistent, re-extracted from the package archive on every install/upgrade. `postinst` seeds `etc/guard.conf` from it on first install. |
| `synology/scripts/preupgrade` | One-time migration shim that rescues an existing `conf/guard.conf` into the persistent `etc/guard.conf` before it gets overwritten by the incoming version. |
| `src/ui/index.cgi` | Web status page (CGI shell script, runs without root) |

---

## Limitations

- **VPN not managed**: this package does not manage the VPN connection itself. It assumes `VPN_IF` is already up (e.g. managed by DSM VPN Center or a third-party OpenVPN/WireGuard client). It also does not follow an interface *rename* (e.g. `tun0` → `tun1` when a stale session lingers); it logs a warning if `VPN_IF` is down while another `tun*/wg*` is up.
- **Recovery latency, not instant**: the reconcile daemon is a timer (default 30 s), not event-driven. A VPN flap is healed within one interval, not immediately. If the daemon process itself dies and the web UI is never opened, recovery waits until the next `start`/`status`. Event-driven reaction is planned for a later release.
- **IPv6 per-UID rules need kernel ≥ 4.10**: older DSM 7.0/7.1 low-end models (kernel 4.4) can't policy-route IPv6 by UID. There the shield protects IPv4 fully, logs a one-time warning, and you should set `IPV6_MODE="off"` to silence it.
- **Kill switch requires `xt_owner`**: many DSM builds ship without it. Protection does not depend on it — the `blackhole` default route already fails Transmission closed when the VPN is down.
- **Rules not removed on a non-root Package Center stop**: DSM may call `stop` without root (if the privilege file hasn't been updated by `activate`), so ip rules / routes added at activation may persist until reboot.
- **Re-run activate after upgrade**: DSM overwrites the privilege file on upgrade, so `activate` must be run again after each package update.
- **RPC**: the peer-port push requires Transmission's RPC reachable at `127.0.0.1:${RPC_PORT}`; if RPC auth is on, set `RPC_USER`/`RPC_PASS` in `etc/guard.secret`.
- **New variables on upgrade**: from 0.2.0, `postinst` appends any missing known keys to your `etc/guard.conf` automatically (with default values), so no hand-merging is needed.

---

## Changelog

### 0.2.1
- **Fix**: `_common.sh` now sources `etc/guard.secret` only when the caller can actually read it (`-r`), not merely when it exists (`-f`). The file is `chmod 600`, so a non-root caller — the web UI running `start-stop-status status` as the DSM web user — hit a "Permission denied" line that surfaced in the *Advanced → raw status output* panel. Non-root callers now simply run without RPC credentials (which they never need).

### 0.2.0
- **New — self-heal**: a supervised `guard-reconcile` daemon runs the new idempotent `start-stop-status reconcile` action every `RECONCILE_INTERVAL_SEC` (default 30s). The shield now recovers on its own from a VPN reconnect, an unlucky boot order (shield started before `tun0` existed — the exact failure this release was written for) or a package/Transmission restart. `do_status` also resurrects the daemon if its PID goes stale.
- **New — fail-closed blackhole**: when the VPN is down the dedicated table gets a `blackhole default` route (v4 **and** v6) instead of being left empty. No more window where Transmission traffic falls through to `main` and exits in the clear. Works even without `xt_owner`.
- **New — IPv6**: `IPV6_MODE` = `route` (through the tunnel, default) / `block` (blackhole) / `off`. `stop`/`prestop` now clean up the v6 rule and v6 table too.
- **Fix — RPC auth**: `apply_forwarded_port` (and the Kuma `port-test`) now send credentials. Previously, with Transmission's RPC authentication enabled, every peer-port push got an HTTP 401 and failed silently — so `FORWARDED_PORT` in `guard.conf` never actually reached Transmission. Credentials go in the new `chmod 600` `etc/guard.secret` (`RPC_USER` / `RPC_PASS`), keeping them out of the world-readable `guard.conf`. The push now also runs only when the port actually differs.
- **Fix — stop really stops Transmission**: `stop_transmission` / `recover-heartbeat` resolved the package as `Transmission` only. SynoCommunity installs it as `transmission` (lowercase), so on those systems Transmission was never stopped when the shield went down. Both now auto-detect `transmission` / `Transmission` / `sc-transmission`.
- **New — logging**: everything is written to `var/shield.log` (size-capped at 512 KB, trimmed in-place — no `logrotate` needed) in addition to `logger`, and the last 120 lines are shown in the web UI. `logger -t` output was not reaching `/var/log/messages` on some DSM builds.
- **New — config migration**: `postinst` appends any missing known keys to your existing `etc/guard.conf` on upgrade, with defaults. No more manual template merging.
- **Refactor**: shared logic (config loading, identity/package resolution, route/rule/killswitch helpers, `rpc_call`, logging) moved into `synology/scripts/_common.sh`, sourced by `start-stop-status`, `guard-reconcile` and `guard-push`.
- **New — tests + CI**: `tests/reconcile.sh` (root integration test, veth fixture, dedicated table 199) and a `shellcheck` + `sh -n` GitHub Actions lint job.
- **Docs**: web UI gains "Traffic Routing" v4/v6 detail, an "Auto-heal" card, a shield-log panel, and RPC-auth / IPv6 / self-heal notes in the config guide.

> **Upgrading**: re-run `activate` after the upgrade (DSM resets the privilege file). If Transmission has RPC auth enabled, add `RPC_USER`/`RPC_PASS` to `/var/packages/transmission-vpn-shield/etc/guard.secret` and restart. IPv6 for Transmission is routed through the tunnel by default (`IPV6_MODE="route"`) — set it to `block` or `off` if you don't want that.

### 0.1.9
- **Fix**: `guard.conf` is now genuinely preserved across upgrades. The 0.1.7 fix moved it to `${PKG_DIR}/conf/guard.conf`, assuming `support_conf_folder=yes` protects that folder — it doesn't. DSM only preserves `${PKG_DIR}/etc/` (symlinked to `/volume1/@appconf/<pkg>`), so `conf/` was silently reset to the shipped default on every install/upgrade, wiping `FORWARDED_PORT`, `KUMA_PUSH_URL`, and any other customization. The persistent file is now `/var/packages/transmission-vpn-shield/etc/guard.conf`; `postinst` seeds it from the template once on first install and never touches it again.
- **Fix**: `activate` and `set-port` now write directly to the persistent `etc/guard.conf` instead of through the `target/conf/guard.conf` symlink. `sed -i` replaces files rather than editing them in place, which was detaching that symlink from its target on the very first port change — the edit landed only in the upgrade-ephemeral `target/` tree and silently vanished on the next upgrade (and in some cases meant the port change never even took effect until a manual restart).
- **New**: `preupgrade` now rescues an existing `conf/guard.conf` into the persistent `etc/guard.conf` before it gets overwritten, best-effort, for anyone still catching up from 0.1.8 or earlier.
- **Docs**: README and the in-app configuration guide now point to `/var/packages/transmission-vpn-shield/etc/guard.conf` as the canonical, truly persistent location.

### 0.1.8
- **New**: `synology/scripts/recover-heartbeat` — one-shot Task Scheduler script (root, run on demand) that stops Transmission, restarts the shield, and starts Transmission again, automating the manual recovery sequence for a Kuma heartbeat down.

### 0.1.7
- **Fix**: `guard.conf` is now **preserved across upgrades**. The default ships from `synology/conf/` (the package conf folder protected by `support_conf_folder=yes`) and `postinst` exposes it under `target/conf/` via a symlink, so all consumers (start-stop-status, guard-push, index.cgi, set-port, activate) keep finding it where they always did. The previous "non-destructive on upgrade" check in `postinst` was dead code — it tested for a file that never existed, and `target/conf/guard.conf` was rebuilt from the new package on every update.
- **New**: `synology/scripts/preupgrade` — one-time migration shim that copies the user's `guard.conf` from the old `target/conf/` location into the persistent folder before DSM rebuilds the target tree. Triggers automatically on the 0.1.6 → 0.1.7 upgrade for users on a DSM build that runs the new package's `preupgrade`; users on builds where it does not run will need to re-create `guard.conf` once and then it will persist from then on.
- **Docs**: README and the in-app configuration guide now point to the canonical persistent location `/var/packages/transmission-vpn-shield/conf/guard.conf`. The historical `target/conf/guard.conf` path keeps working via the symlink, so existing Task Scheduler scripts and notes are not broken.

### 0.1.6
- **New**: "Kuma Monitoring" status row below the protection grid with three states (Active / Inactive / Not configured). When active it shows the push interval and the Kuma host extracted from `KUMA_PUSH_URL` — the per-monitor token is never rendered in the page.
- **New**: web UI configuration guide includes a copy-pasteable "Enable Uptime Kuma push monitoring" memo (Push monitor setup, three `KUMA_*` / `PORT_TEST_INTERVAL_SEC` vars, restart command, SSH `guard-push once` test command, log tag).
- **Improvement**: shared CSS between Transmission and Kuma rows generalised to `.status-*` (was `.tx-status-*`) so both rows below the grid use the same styling.
- **Robustness**: the Kuma host extraction strips URL userinfo, so a `https://user:pass@host/...` form (e.g. basic-auth in front of a reverse proxy) no longer leaks credentials into the rendered row.
- **Robustness**: the daemon-alive check now validates `/proc/<pid>/cmdline` instead of just `[ -d /proc/<pid> ]`, so a recycled PID (daemon died, kernel reassigned the PID to an unrelated process) cannot falsely report the Kuma row as Active.

### 0.1.5
- **New**: Uptime Kuma push monitoring. Outbound-only heartbeats from the NAS to a Kuma "Push" monitor; status flips `down` if VPN, routing rules, route, ip rule, or Transmission `port-test` fail. Configured via `KUMA_PUSH_URL` (empty = disabled) plus optional `KUMA_PUSH_INTERVAL_SEC` and `PORT_TEST_INTERVAL_SEC` in `guard.conf`.
- **New**: `synology/scripts/guard-push` daemon (modes: `loop`, `once`, `final-down`) supervised by `start-stop-status`; sends a final `down` heartbeat on stop so Kuma flips immediately instead of waiting on heartbeat timeout.
- **New**: cached Transmission `port-test` RPC check — a closed forwarded port now also flips the alert, catching scenarios where the tunnel is up but inbound peer connections are broken.
- **Robustness**: `KUMA_PUSH_URL` is normalised before each request — pasting Kuma's full example URL with the trailing `?status=up&msg=OK&ping=` no longer produces duplicate query keys.
- **Robustness**: the Kuma daemon starts after `apply_forwarded_port` so its first `port-test` cannot race against the RPC peer-port update and cache a stale `closed` result.
- **Robustness**: a missing/unresolvable Transmission UID (monitor mode) now flips the Kuma status to `down` instead of silently reporting `up` while traffic is not policy-routed.

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
