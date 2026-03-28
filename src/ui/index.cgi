#!/bin/sh
# Transmission VPN Shield - CGI status page

set +e

PKG_NAME="transmission-vpn-shield"
BASE="/var/packages/${PKG_NAME}"
CTL="${BASE}/scripts/start-stop-status"

# AJAX endpoint: plain status text for Refresh button
if echo "${QUERY_STRING:-}" | grep -q 'mode=status'; then
  STATUS_OUTPUT="$(${CTL} status 2>&1 || printf 'Status command unavailable.')"
  printf 'Content-type: text/plain\r\n\r\n'
  printf '%s' "${STATUS_OUTPUT}"
  exit 0
fi

# ── Defaults (overridden by guard.conf) ──────────────────────────────────────
TRANSMISSION_USER="sc-transmission"
VPN_IF="tun0"
RT_TABLE_ID="200"
RT_TABLE_NAME="transmissionvpn"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="1"
FORWARDED_PORT=""
CONF_LOADED="(defaults)"

for f in \
  "${BASE}/target/conf/guard.conf" \
  "${BASE}/conf/guard.conf"; do
  [ -f "$f" ] || continue
  . "$f"; CONF_LOADED="$f"; break
done

# ── Detect Transmission user ─────────────────────────────────────────────────
detect_user() {
  for u in "${TRANSMISSION_USER}" "sc-transmission" "transmission" "debian-transmission"; do
    [ -n "$u" ] || continue
    uid=$(id -u "$u" 2>/dev/null) || continue
    TRANSMISSION_USER="$u"; echo "$uid"; return
  done
  echo ""
}
first_line_or_empty() { sh -c "$1" 2>/dev/null | head -n1; }

UID_VAL="$(detect_user)"

# ── VPN status ────────────────────────────────────────────────────────────────
VPN_UP="no"
[ -n "$(ip link show "${VPN_IF}" 2>/dev/null | head -n1)" ] && \
  ip -4 addr show dev "${VPN_IF}" 2>/dev/null | grep -q 'inet ' && VPN_UP="yes"
VPN_ADDRS="$(ip -4 addr show dev "${VPN_IF}" 2>/dev/null | awk '/inet /{print $2}' | paste -sd, -)"

# ── Routing checks ────────────────────────────────────────────────────────────
RT_TABLE_ENTRY="$(first_line_or_empty "grep -E '^[[:space:]]*${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}\$' /etc/iproute2/rt_tables")"
RULE_PRESENT="$(first_line_or_empty "ip rule show | grep -E 'uidrange .* lookup ${RT_TABLE_NAME}'")"
ROUTE_PRESENT="$(first_line_or_empty "ip route show table \"${RT_TABLE_NAME}\" | grep '^default dev ${VPN_IF}'")"
KILLSWITCH_RULE="$(first_line_or_empty "iptables -S OUTPUT | grep -- '-m owner --uid-owner ${UID_VAL:-?} ! -o ${VPN_IF} -j DROP'")"

# ── Public IP (VPN-cached, never WAN leak) ────────────────────────────────────
PUB_IP="$(cat "${BASE}/var/public_ip" 2>/dev/null || echo '')"

# ── Overall protection status ────────────────────────────────────────────────
FULLY_PROTECTED="no"
[ "${VPN_UP}" = "yes" ] && [ -n "${RULE_PRESENT}" ] && [ -n "${ROUTE_PRESENT}" ] && FULLY_PROTECTED="yes"

# ── Kill switch state ────────────────────────────────────────────────────────
if [ -n "${KILLSWITCH_RULE}" ]; then
  KS_STATE="active"
elif iptables -m owner -h >/dev/null 2>&1; then
  KS_STATE="inactive"
else
  KS_STATE="unsupported"
fi

# ── Raw status output (for advanced details) ─────────────────────────────────
STATUS_OUTPUT="$(${CTL} status 2>&1 || printf 'Status command unavailable.')"

# ── Helper: yes/no → icon+label ─────────────────────────────────────────────
yn() {
  if [ "$1" = "yes" ]; then
    printf '<span class="badge ok">&#10004; %s</span>' "${2:-OK}"
  else
    printf '<span class="badge fail">&#10008; %s</span>' "${3:-No}"
  fi
}

# ── Forwarded port card HTML ─────────────────────────────────────────────────
build_port_card() {
  if [ -n "${FORWARDED_PORT}" ]; then
    printf '<div class="card-value"><span class="badge ok">%s</span></div>' "${FORWARDED_PORT}"
    printf '<div class="card-sub">'
    printf 'Pushed to Transmission on every start'
    if [ -n "${PUB_IP}" ]; then
      printf ' &middot; <a href="https://www.yougetsignal.com/tools/open-ports/?remoteAddress=%s&amp;portNumber=%s" target="_blank" rel="noopener" style="color:#0b6cff;text-decoration:none;">check port %s &nearr;</a>' \
        "${PUB_IP}" "${FORWARDED_PORT}" "${FORWARDED_PORT}"
    fi
    printf '</div>'
  else
    printf '<div class="card-value"><span class="badge warn">&#9888; Not configured</span></div>'
    printf '<div class="card-sub">'
    printf 'Set <code>FORWARDED_PORT</code> in <code>guard.conf</code> to improve speeds.<br>'
    printf 'Config file: <code>/var/packages/transmission-vpn-shield/target/conf/guard.conf</code>'
    printf '</div>'
  fi
}

PORT_CARD_HTML="$(build_port_card)"

# ── Content-Type header — MUST be first output ───────────────────────────────
printf 'Content-type: text/html; charset=utf-8\r\n\r\n'

# ── Compute top-level banner values ──────────────────────────────────────────
if [ "${FULLY_PROTECTED}" = "yes" ]; then
  BANNER_CLASS="banner-ok"
  BANNER_TITLE="Transmission is protected"
  BANNER_SUB="All traffic is routed through the VPN tunnel (${VPN_IF})"
else
  BANNER_CLASS="banner-fail"
  BANNER_TITLE="Protection incomplete"
  BANNER_SUB="Check the status cards below to find what is missing"
fi

cat <<ENDHTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transmission VPN Shield</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      background: #f0f2f5;
      color: #1a1a2e;
      min-height: 100vh;
      padding: 24px 16px 48px;
    }
    .banner {
      border-radius: 16px;
      padding: 28px 32px;
      max-width: 860px;
      margin: 0 auto 28px;
      display: flex;
      align-items: center;
      gap: 20px;
      box-shadow: 0 4px 20px rgba(0,0,0,.10);
    }
    .banner-ok   { background: linear-gradient(135deg, #1a9e5c, #27ae60); color: #fff; }
    .banner-fail { background: linear-gradient(135deg, #c0392b, #e74c3c); color: #fff; }
    .banner-logo { width: 64px; height: 64px; flex-shrink: 0; border-radius: 12px; }
    .banner-title { font-size: 1.5rem; font-weight: 700; }
    .banner-sub   { font-size: .95rem; opacity: .88; margin-top: 4px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
      gap: 16px;
      max-width: 860px;
      margin: 0 auto 24px;
    }
    .card {
      background: #fff;
      border-radius: 12px;
      padding: 20px;
      box-shadow: 0 2px 10px rgba(0,0,0,.07);
    }
    .card-header { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; }
    .card-icon { font-size: 1.5rem; }
    .card-title { font-size: .8rem; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: #666; }
    .card-value { font-size: 1.15rem; font-weight: 700; color: #1a1a2e; word-break: break-all; }
    .card-sub { font-size: .8rem; color: #888; margin-top: 6px; line-height: 1.5; }
    .card-sub code { background: #f0f0f0; padding: 1px 5px; border-radius: 4px; font-size: .78rem; }
    .badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: .85rem; font-weight: 600; }
    .badge.ok   { background: #d4f8e8; color: #0a7040; }
    .badge.warn { background: #fff3cd; color: #856404; }
    .badge.fail { background: #fde8e8; color: #9b1c1c; }
    .badge.info { background: #e8f0fe; color: #1a56db; }
    .actions { max-width: 860px; margin: 0 auto 24px; display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
    .btn {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 10px 20px; border-radius: 8px;
      font-size: .9rem; font-weight: 600;
      cursor: pointer; border: none; text-decoration: none;
      transition: opacity .15s;
    }
    .btn:hover { opacity: .85; }
    .btn-primary { background: #0b6cff; color: #fff; }
    .btn-secondary { background: #e8edf4; color: #1a1a2e; }
    .btn:disabled { opacity: .5; cursor: progress; }
    #refresh-ts { font-size: .8rem; color: #888; }
    .details-wrap { max-width: 860px; margin: 0 auto 24px; }
    details { background: #fff; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,.07); overflow: hidden; margin-bottom: 12px; }
    summary { padding: 14px 20px; font-weight: 600; font-size: .9rem; cursor: pointer; user-select: none; color: #444; }
    summary:hover { background: #f8f9fb; }
    pre { background: #16213e; color: #a8d8a8; padding: 16px 20px; font-size: .8rem; line-height: 1.6; overflow-x: auto; white-space: pre-wrap; margin: 0; }
    .guide { padding: 16px 20px; font-size: .87rem; line-height: 1.7; color: #333; }
    .guide h3 { font-size: .95rem; margin: 16px 0 6px; color: #1a1a2e; }
    .guide h3:first-child { margin-top: 0; }
    .guide ol, .guide ul { padding-left: 20px; }
    .guide li { margin-bottom: 4px; }
    .guide code { background: #f0f0f0; padding: 1px 6px; border-radius: 4px; font-size: .82rem; }
    .guide .note { background: #fff3cd; border-left: 3px solid #f0ad4e; padding: 8px 12px; border-radius: 0 6px 6px 0; margin: 10px 0; font-size: .83rem; color: #6b4c00; }
    footer { max-width: 860px; margin: 0 auto; font-size: .78rem; color: #aaa; text-align: center; line-height: 1.8; }
    footer a { color: #0b6cff; text-decoration: none; }
    footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>

<div class="banner ${BANNER_CLASS}">
  <img src="images/icon_256.png" alt="Transmission VPN Shield" class="banner-logo">
  <div>
    <div class="banner-title">${BANNER_TITLE}</div>
    <div class="banner-sub">${BANNER_SUB}</div>
  </div>
</div>

<div class="grid">

  <div class="card">
    <div class="card-header"><span class="card-icon">&#128274;</span><span class="card-title">VPN Tunnel</span></div>
    <div class="card-value">$(yn "${VPN_UP}" "Connected" "Disconnected")</div>
    <div class="card-sub">Interface: <strong>${VPN_IF}</strong>${VPN_ADDRS:+ &middot; ${VPN_ADDRS}}</div>
  </div>

  <div class="card">
    <div class="card-header"><span class="card-icon">&#127758;</span><span class="card-title">Public IP via VPN</span></div>
    <div class="card-value">${PUB_IP:-<span style="color:#bbb;font-weight:400">not yet fetched</span>}</div>
    <div class="card-sub">Refreshed every 2&nbsp;h via <a href="https://ip.gioxx.org" target="_blank" rel="noopener" style="color:#0b6cff;text-decoration:none;">ip.gioxx.org</a> (fallback: <a href="https://api.ipify.org" target="_blank" rel="noopener" style="color:#0b6cff;text-decoration:none;">api.ipify.org</a>), bound to <strong>${VPN_IF}</strong></div>
  </div>

  <div class="card">
    <div class="card-header"><span class="card-icon">&#129517;</span><span class="card-title">Traffic Routing</span></div>
    <div class="card-value">$([ -n "${RULE_PRESENT}" ] && [ -n "${ROUTE_PRESENT}" ] && yn "yes" "Active" || yn "no" "" "Inactive")</div>
    <div class="card-sub">
      Route table: $([ -n "${RT_TABLE_ENTRY}" ] && echo "&#10004; present" || echo "&#10008; missing") &middot;
      UID rule: $([ -n "${RULE_PRESENT}" ] && echo "&#10004; present" || echo "&#10008; missing")
    </div>
  </div>

  <div class="card">
    <div class="card-header"><span class="card-icon">&#128683;</span><span class="card-title">Kill Switch</span></div>
    <div class="card-value">
      $(case "${KS_STATE}" in
          active)      printf '<span class="badge ok">&#10004; Active</span>' ;;
          inactive)    printf '<span class="badge warn">&#9888; Inactive</span>' ;;
          unsupported) printf '<span class="badge info">&#8505; Not supported</span>' ;;
        esac)
    </div>
    <div class="card-sub">
      $(case "${KS_STATE}" in
          active)      echo "Blocks Transmission if VPN drops" ;;
          inactive)    echo "Rule not found &mdash; restart the package" ;;
          unsupported) echo "Kernel lacks iptables owner match (routing still protects)" ;;
        esac)
    </div>
  </div>

  <div class="card">
    <div class="card-header"><span class="card-icon">&#9881;</span><span class="card-title">Transmission User</span></div>
    <div class="card-value">${TRANSMISSION_USER}</div>
    <div class="card-sub">UID: ${UID_VAL:-n/a}</div>
  </div>

  <div class="card">
    <div class="card-header"><span class="card-icon">&#128268;</span><span class="card-title">Forwarded Port</span></div>
    ${PORT_CARD_HTML}
  </div>

</div>

<div class="actions">
  <button class="btn btn-primary" id="refresh-btn">&#8635; Refresh status</button>
  <button class="btn btn-secondary" onclick="window.location.reload()">&#8635; Refresh page</button>
  <span id="refresh-ts"></span>
</div>

<div class="details-wrap">

  <details>
    <summary>&#128218; Setup &amp; configuration guide</summary>
    <div class="guide">
      <h3>First install — one-time activation</h3>
      <p>Because DSM 7.2+ blocks unsigned packages from running as root at install time, after installing the SPK the package will appear in <strong>Error</strong> state. This is expected. Complete the setup with a Task Scheduler job:</p>
      <ol>
        <li>Go to <strong>Control Panel &rarr; Task Scheduler &rarr; Create &rarr; Triggered Task &rarr; User-defined script</strong></li>
        <li>Set <strong>User</strong> to <code>root</code>, leave <strong>Enabled</strong> unchecked</li>
        <li>In the <strong>Task Settings</strong> tab, paste this command:<br><code>/var/packages/transmission-vpn-shield/scripts/activate</code></li>
        <li>Save, then select the task and click <strong>Run</strong></li>
        <li>After a few seconds the package should show as <strong>Running</strong> in Package Center</li>
      </ol>
      <div class="note">You only need to run this once per install or upgrade. After activation the package starts automatically on every DSM reboot.</div>

      <h3>Changing the VPN forwarded port</h3>
      <p>Option A — edit the config file directly:</p>
      <ol>
        <li>Open <code>/var/packages/transmission-vpn-shield/target/conf/guard.conf</code> in a text editor (DSM Text Editor or SSH)</li>
        <li>Set or update the line: <code>FORWARDED_PORT="12345"</code></li>
        <li>Restart the package from Package Center</li>
      </ol>
      <p style="margin-top:10px;">Option B — use the helper script from Task Scheduler (no SSH needed):</p>
      <ol>
        <li>Create a new task as <code>root</code> with this command (replace the port number):<br><code>/var/packages/transmission-vpn-shield/scripts/set-port 12345</code></li>
        <li>Run the task — it updates <code>guard.conf</code> and restarts the package automatically</li>
      </ol>

      <h3>Config file location</h3>
      <p><code>/var/packages/transmission-vpn-shield/target/conf/guard.conf</code></p>
    </div>
  </details>

  <details>
    <summary>&#128295; Advanced &mdash; raw status output</summary>
    <pre id="status-output">$(printf '%s' "${STATUS_OUTPUT}" | sed 's/&/\&amp;/g; s/</\&lt;/g')</pre>
  </details>

</div>

<footer>
  Lovingly developed by the usually-on-vacation brain cell of Gioxx &#10084;&#65039; &mdash; Flawed by design, just like my code &#128174;<br>
  <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/" target="_blank" rel="noopener">GitHub</a> &middot;
  <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new" target="_blank" rel="noopener">Open an issue</a> &middot;
  <a href="https://iknowwhatyoudownload.com/" target="_blank" rel="noopener">iknowwhatyoudownload.com</a>
</footer>

<script>
(function () {
  const btn = document.getElementById('refresh-btn');
  const pre = document.getElementById('status-output');
  const ts  = document.getElementById('refresh-ts');
  async function doRefresh() {
    btn.disabled = true;
    btn.textContent = 'Refreshing\u2026';
    try {
      const res  = await fetch('?mode=status', { cache: 'no-store' });
      const text = await res.text();
      if (pre) pre.textContent = text;
      ts.textContent = 'Last refresh: ' + new Date().toLocaleTimeString();
    } catch (e) {
      ts.textContent = 'Refresh error: ' + e;
    } finally {
      btn.disabled = false;
      btn.innerHTML = '\u8635 Refresh status';
    }
  }
  btn.addEventListener('click', doRefresh);
}());
</script>

</body>
</html>
ENDHTML

exit 0
