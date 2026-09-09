#!/bin/sh
# Transmission VPN Shield - CGI status page

set +e

PKG_NAME="transmission-vpn-shield"
BASE="/var/packages/${PKG_NAME}"
CTL="${BASE}/scripts/start-stop-status"
NEEDS_ACTIVATION_FLAG="${BASE}/var/needs-activation"
DOCS_URL="https://synovpnshield.gioxx.org"
REPO_URL="https://github.com/gioxx/Syno-TransmissionVPNShield"

PKG_VERSION="$(sed -n 's/^version="\(.*\)"$/\1/p' "${BASE}/INFO" 2>/dev/null | head -n1)"

# ── AJAX: plain status text ───────────────────────────────────────────────────
if echo "${QUERY_STRING:-}" | grep -q 'mode=status'; then
  STATUS_OUTPUT="$(${CTL} status 2>&1 || printf 'Status command unavailable.')"
  printf 'Content-type: text/plain\r\n\r\n'
  printf '%s' "${STATUS_OUTPUT}"
  exit 0
fi

# ── AJAX: check activation state ─────────────────────────────────────────────
if echo "${QUERY_STRING:-}" | grep -q 'mode=check-activation'; then
  printf 'Content-type: text/plain\r\n\r\n'
  if [ -f "${NEEDS_ACTIVATION_FLAG}" ]; then
    printf 'needs-activation'
  else
    printf 'active'
  fi
  exit 0
fi

# ── AJAX: Transmission status (via RPC port — no root needed) ────────────────
if echo "${QUERY_STRING:-}" | grep -q 'mode=tx-status'; then
  printf 'Content-type: text/plain\r\n\r\n'
  CURL_BIN="$(command -v curl 2>/dev/null || true)"
  if [ -n "${CURL_BIN}" ]; then
    "${CURL_BIN}" -s --max-time 2 http://127.0.0.1:9091/transmission/rpc >/dev/null 2>&1 \
      && printf 'running' || printf 'stopped'
  elif ss -tnl 2>/dev/null | grep -q ':9091'; then
    printf 'running'
  elif netstat -tnl 2>/dev/null | grep -q ':9091'; then
    printf 'running'
  else
    printf 'stopped'
  fi
  exit 0
fi

# ── Defaults (overridden by guard.conf) ──────────────────────────────────────
TRANSMISSION_USER="sc-transmission"
VPN_IF="tun0"
RT_TABLE_ID="200"
RT_TABLE_NAME="transmissionvpn"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="1"
FORWARDED_PORT=""
KUMA_PUSH_URL=""
KUMA_PUSH_INTERVAL_SEC="60"
PORT_TEST_INTERVAL_SEC="600"
RECONCILE_INTERVAL_SEC="30"
IPV6_MODE="route"
AUTOSTART_TRANSMISSION="0"
DSM_VPN_NAME=""
CONF_LOADED="(defaults)"

for f in \
  "${BASE}/target/conf/guard.conf" \
  "${BASE}/etc/guard.conf"; do
  [ -f "$f" ] || continue
  . "$f"; CONF_LOADED="$f"; break
done
# Same fallback as guard-reconcile: a zero/negative/non-numeric guard.conf
# value must not reach arithmetic (freshness math, sleep) unsanitized.
[ "${RECONCILE_INTERVAL_SEC}" -gt 0 ] 2>/dev/null || RECONCILE_INTERVAL_SEC=30
# 0 is a valid "port-test disabled" value (mirrors port_test()'s own check in
# _common.sh) and must stay 0, not fall back to the default — only reject
# negative/non-numeric values.
[ "${PORT_TEST_INTERVAL_SEC}" -ge 0 ] 2>/dev/null || PORT_TEST_INTERVAL_SEC=600
# guard.secret (RPC creds) is 0600 root-only and deliberately NOT read here —
# the web UI runs as the DSM web user and never needs the RPC password.
unset RPC_USER RPC_PASS 2>/dev/null || true
case "${IPV6_MODE}" in route|block|off) ;; *) IPV6_MODE="route" ;; esac

# ── Content-Type header — MUST be first output ───────────────────────────────
printf 'Content-type: text/html; charset=utf-8\r\n\r\n'

# ── Shared head + CSS ──────────────────────────────────────────────────────────
cat <<STYLE
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transmission VPN Shield</title>
  <style>
    :root {
      --bg: #f2f4f8;
      --surface: #ffffff;
      --surface-alt: #f7f8fb;
      --border: #e3e6ec;
      --text: #171923;
      --text-dim: #666c7a;
      --accent: #16a34a;
      --accent-2: #0b6cff;
      --warn: #b45309;
      --warn-bg: #fff3cd;
      --warn-border: #f0ad4e;
      --fail: #9b1c1c;
      --fail-bg: #fde8e8;
      --info-bg: #e8f0fe;
      --info-text: #1a56db;
      --code-bg: #eef0f4;
      --pre-bg: #16213e;
      --pre-text: #a8d8a8;
      --radius: 12px;
      --shadow: 0 2px 10px rgba(20,20,40,.06);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0b120f;
        --surface: #101a16;
        --surface-alt: #0c1613;
        --border: rgba(255,255,255,.08);
        --text: #eef5f1;
        --text-dim: #9fb3ac;
        --accent: #22c55e;
        --accent-2: #38bdf8;
        --warn: #facc15;
        --warn-bg: rgba(250,204,21,.12);
        --warn-border: rgba(250,204,21,.4);
        --fail: #f87171;
        --fail-bg: rgba(248,113,113,.14);
        --info-bg: rgba(56,189,248,.14);
        --info-text: #7dd3fc;
        --code-bg: rgba(255,255,255,.07);
        --pre-bg: #08120e;
        --pre-text: #86e7a6;
        --shadow: 0 2px 10px rgba(0,0,0,.35);
      }
    }
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      padding: 0 16px 48px;
    }
    a { color: var(--accent-2); }
    .wrap { max-width: 880px; margin: 0 auto; }

    header.top {
      display: flex; align-items: center; gap: 12px;
      padding: 18px 4px 14px; max-width: 880px; margin: 0 auto;
      flex-wrap: wrap;
    }
    header.top img { width: 34px; height: 34px; border-radius: 8px; flex-shrink: 0; }
    header.top .title { font-weight: 700; font-size: 1.05rem; }
    header.top .version { font-size: .75rem; color: var(--text-dim); font-weight: 600; }
    header.top nav { margin-left: auto; display: flex; gap: 14px; font-size: .85rem; font-weight: 600; }
    header.top nav a { text-decoration: none; color: var(--text-dim); }
    header.top nav a:hover { color: var(--accent-2); }

    .banner {
      border-radius: 16px;
      padding: 24px 28px;
      margin: 0 auto 16px;
      display: flex;
      align-items: center;
      gap: 18px;
      box-shadow: var(--shadow);
      flex-wrap: wrap;
    }
    .banner-ok     { background: linear-gradient(135deg, #16a34a, #22c55e); color: #fff; }
    .banner-warn   { background: linear-gradient(135deg, #d97706, #f59e0b); color: #fff; }
    .banner-fail   { background: linear-gradient(135deg, #b91c1c, #ef4444); color: #fff; }
    .banner-logo   { width: 52px; height: 52px; flex-shrink: 0; border-radius: 12px; }
    .banner-text   { flex: 1; min-width: 200px; }
    .banner-title  { font-size: 1.3rem; font-weight: 700; }
    .banner-sub    { font-size: .9rem; opacity: .9; margin-top: 3px; }
    .banner-action {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 8px 16px; border-radius: 8px;
      font-size: .82rem; font-weight: 600;
      cursor: pointer; text-decoration: none;
      background: rgba(255,255,255,.16); color: #fff;
      border: 1px solid rgba(255,255,255,.4);
      transition: background .15s;
    }
    .banner-action:hover { background: rgba(255,255,255,.28); }

    .fix-hint {
      display: flex; align-items: flex-start; gap: 12px;
      margin: 0 auto 16px;
      background: var(--warn-bg); border-left: 4px solid var(--warn-border);
      border-radius: 0 10px 10px 0;
      padding: 12px 16px; font-size: .87rem; line-height: 1.55; color: var(--warn);
    }
    .fix-hint-icon { font-size: 1.3rem; flex-shrink: 0; margin-top: 1px; }

    .chip-row { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 auto 14px; }
    .chip {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 7px 13px; border-radius: 999px;
      font-size: .82rem; font-weight: 600;
      text-decoration: none; cursor: pointer;
      border: 1px solid transparent;
      transition: transform .12s ease, border-color .12s ease;
    }
    .chip:hover { transform: translateY(-1px); }
    .chip .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .chip.ok   { background: color-mix(in srgb, var(--accent) 14%, transparent); color: var(--accent); border-color: color-mix(in srgb, var(--accent) 30%, transparent); }
    .chip.ok .dot   { background: var(--accent); }
    .chip.warn { background: var(--warn-bg); color: var(--warn); border-color: var(--warn-border); }
    .chip.warn .dot { background: var(--warn); }
    .chip.fail { background: var(--fail-bg); color: var(--fail); border-color: color-mix(in srgb, var(--fail) 35%, transparent); }
    .chip.fail .dot { background: var(--fail); }
    .chip.info { background: var(--info-bg); color: var(--info-text); border-color: color-mix(in srgb, var(--info-text) 30%, transparent); }
    .chip.info .dot { background: var(--info-text); }

    .info-row {
      display: flex; flex-wrap: wrap; gap: 10px 28px;
      background: var(--surface); border-radius: var(--radius);
      box-shadow: var(--shadow); padding: 16px 20px; margin: 0 auto 16px;
    }
    .info-item { display: flex; flex-direction: column; gap: 3px; min-width: 140px; }
    .info-label { font-size: .68rem; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: var(--text-dim); }
    .info-value { font-size: .98rem; font-weight: 700; word-break: break-all; }
    .info-value .muted { color: var(--text-dim); font-weight: 400; }

    .alert-block {
      margin: 0 auto 16px;
      border-radius: var(--radius);
      padding: 14px 18px;
      font-size: .87rem; line-height: 1.55;
      background: var(--fail-bg); color: var(--fail);
      border: 1px solid color-mix(in srgb, var(--fail) 30%, transparent);
    }
    .alert-block code { background: rgba(0,0,0,.08); }

    .badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: .82rem; font-weight: 600; }
    .badge.ok   { background: color-mix(in srgb, var(--accent) 16%, transparent); color: var(--accent); }
    .badge.warn { background: var(--warn-bg); color: var(--warn); }
    .badge.fail { background: var(--fail-bg); color: var(--fail); }
    .badge.info { background: var(--info-bg); color: var(--info-text); }

    .accordions { margin: 0 auto 18px; display: flex; flex-direction: column; gap: 10px; }
    details {
      background: var(--surface); border-radius: var(--radius);
      box-shadow: var(--shadow); overflow: hidden;
      border: 1px solid transparent;
      scroll-margin-top: 16px;
    }
    details[open] { border-color: color-mix(in srgb, var(--accent-2) 25%, transparent); }
    summary {
      padding: 14px 20px; font-weight: 600; font-size: .92rem; cursor: pointer;
      user-select: none; list-style: none; display: flex; align-items: center; gap: 10px;
    }
    summary::-webkit-details-marker { display: none; }
    summary::before { content: '\25B8'; display: inline-block; transition: transform .15s ease; color: var(--text-dim); }
    details[open] summary::before { transform: rotate(90deg); }
    summary:hover { background: var(--surface-alt); }
    .acc-body { padding: 4px 20px 18px; font-size: .87rem; line-height: 1.65; color: var(--text); }
    .acc-body h4 { font-size: .82rem; margin: 14px 0 6px; color: var(--text); text-transform: uppercase; letter-spacing: .04em; }
    .acc-body h4:first-child { margin-top: 0; }
    .acc-body p { margin: 6px 0; }
    .acc-body ol, .acc-body ul { padding-left: 20px; }
    .acc-body li { margin-bottom: 4px; }
    .acc-body code { background: var(--code-bg); padding: 1px 6px; border-radius: 4px; font-size: .82rem; }
    .acc-body .cmd { background: var(--pre-bg); color: var(--pre-text); padding: 8px 14px; border-radius: 6px; font-family: ui-monospace, monospace; font-size: .84rem; margin: 6px 0; display: block; overflow-x: auto; }
    .acc-body .note { background: var(--warn-bg); border-left: 3px solid var(--warn-border); padding: 8px 12px; border-radius: 0 6px 6px 0; margin: 10px 0; font-size: .84rem; color: var(--warn); }
    .task-table-wrap { overflow-x: auto; margin: 8px 0; }
    .task-table { width: 100%; border-collapse: collapse; font-size: .84rem; }
    .task-table td code { white-space: nowrap; }
    .task-table th, .task-table td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
    .task-table th { color: var(--text-dim); font-weight: 600; font-size: .72rem; text-transform: uppercase; letter-spacing: .03em; }
    pre { background: var(--pre-bg); color: var(--pre-text); padding: 14px 18px; font-size: .78rem; line-height: 1.6; overflow-x: auto; white-space: pre-wrap; margin: 0; }

    .actions { margin: 0 auto 16px; display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
    .btn {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 9px 18px; border-radius: 8px;
      font-size: .87rem; font-weight: 600;
      cursor: pointer; border: none; text-decoration: none;
      transition: opacity .15s;
    }
    .btn:hover    { opacity: .85; }
    .btn-primary  { background: var(--accent-2); color: #fff; }
    .btn-secondary{ background: var(--code-bg); color: var(--text); }
    .btn:disabled { opacity: .5; cursor: progress; }
    #status-msg { font-size: .82rem; font-weight: 600; padding: 6px 12px; border-radius: 6px; display: none; }
    #status-msg.ok   { background: color-mix(in srgb, var(--accent) 16%, transparent); color: var(--accent); display: inline-block; }
    #status-msg.fail { background: var(--fail-bg); color: var(--fail); display: inline-block; }

    footer { max-width: 880px; margin: 8px auto 0; font-size: .76rem; color: var(--text-dim); text-align: center; line-height: 1.8; }
    footer a { color: var(--accent-2); text-decoration: none; }
    footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
<div class="wrap">
<header class="top">
  <img src="images/icon_256.png" alt="">
  <span class="title">Transmission VPN Shield</span>
  <span class="version">v${PKG_VERSION:-?}</span>
  <nav>
    <a href="${DOCS_URL}" target="_blank" rel="noopener">Documentation</a>
    <a href="${REPO_URL}" target="_blank" rel="noopener">GitHub</a>
  </nav>
</header>
STYLE

# ── Needs-activation mode ─────────────────────────────────────────────────────
if [ -f "${NEEDS_ACTIVATION_FLAG}" ]; then

cat <<ENDHTML
<div class="banner banner-warn">
  <img src="images/icon_256.png" alt="Transmission VPN Shield" class="banner-logo">
  <div class="banner-text">
    <div class="banner-title">Activation required</div>
    <div class="banner-sub">The package is installed but needs a one-time root setup to start protecting Transmission</div>
  </div>
</div>

<div class="accordions">
  <details open>
    <summary>How to activate Transmission VPN Shield</summary>
    <div class="acc-body">
      <h4>Step 1 — Open Task Scheduler</h4>
      <p>Go to <strong>DSM Control Panel &rarr; Task Scheduler &rarr; Create &rarr; Triggered Task &rarr; User-defined script</strong></p>

      <h4>Step 2 — Configure the task</h4>
      <ul>
        <li>Give it any name (e.g. <em>Activate VPN Shield</em>)</li>
        <li>Set <strong>User</strong> to <code>root</code></li>
        <li>Leave <strong>Enabled</strong> <em>unchecked</em> — you only need to run it once</li>
      </ul>

      <h4>Step 3 — Paste the command</h4>
      <p>In the <strong>Task Settings</strong> tab, paste one of the following:</p>
      <p><strong>Without VPN forwarded port:</strong></p>
      <span class="cmd">/var/packages/transmission-vpn-shield/scripts/activate</span>
      <p><strong>With VPN forwarded port</strong> (recommended — replace <code>56460</code> with your port):</p>
      <span class="cmd">/var/packages/transmission-vpn-shield/scripts/activate 56460</span>
      <div class="note">You can find your forwarded port in your VPN provider's dashboard (e.g. AirVPN &rarr; Client Area &rarr; Forwarded ports). Using a forwarded port significantly improves download speeds.</div>

      <h4>Step 4 — Run the task</h4>
      <p>Click <strong>OK</strong> to save, then select the task in the list and click <strong>Run</strong>.</p>
      <p>After a few seconds, click the button below to verify that the activation completed successfully.</p>
    </div>
  </details>
</div>

<div class="actions">
  <button class="btn btn-primary" id="check-btn" onclick="checkActivation()">&#8635; Check activation status</button>
  <button class="btn btn-secondary" onclick="window.location.reload()">&#8635; Reload page</button>
  <span id="status-msg"></span>
</div>

<footer>
  Lovingly developed by the usually-on-vacation brain cell of Gioxx &#10084;&#65039; &mdash; Flawed by design, just like my code &#128686;<br>
  <a href="${REPO_URL}/" target="_blank" rel="noopener">GitHub</a> &middot;
  <a href="${REPO_URL}/issues/new" target="_blank" rel="noopener">Open an issue</a>
</footer>
</div>

<script>
async function checkActivation() {
  const btn = document.getElementById('check-btn');
  const msg = document.getElementById('status-msg');
  btn.disabled = true;
  btn.textContent = 'Checking…';
  msg.className = '';
  msg.style.display = 'none';
  try {
    const res  = await fetch('?mode=check-activation', { cache: 'no-store' });
    const text = (await res.text()).trim();
    if (text === 'active') {
      msg.className = 'ok';
      msg.textContent = '✔ Activated! Reloading…';
      msg.style.display = 'inline-block';
      setTimeout(() => window.location.reload(), 1500);
    } else {
      msg.className = 'fail';
      msg.textContent = '✘ Not yet activated — run the Task Scheduler task and try again.';
      msg.style.display = 'inline-block';
      btn.disabled = false;
      btn.textContent = '↻ Check activation status';
    }
  } catch (e) {
    msg.className = 'fail';
    msg.textContent = 'Error: ' + e;
    msg.style.display = 'inline-block';
    btn.disabled = false;
    btn.textContent = '↻ Check activation status';
  }
}
</script>
</body>
</html>
ENDHTML

  exit 0
fi

# ── Normal mode (activated) ───────────────────────────────────────────────────

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
RULE_PRESENT="$(first_line_or_empty "ip rule show | grep -E 'uidrange .* lookup (${RT_TABLE_NAME}|${RT_TABLE_ID})'")"
ROUTE_PRESENT="$(first_line_or_empty "ip route show table \"${RT_TABLE_ID}\" | grep '^default dev ${VPN_IF}'")"
ROUTE_BLACKHOLE="$(first_line_or_empty "ip route show table \"${RT_TABLE_ID}\" | grep '^blackhole default'")"
RULE6_PRESENT="$(first_line_or_empty "ip -6 rule show | grep -E 'uidrange .* lookup (${RT_TABLE_NAME}|${RT_TABLE_ID})'")"
ROUTE6_PRESENT="$(first_line_or_empty "ip -6 route show table \"${RT_TABLE_ID}\" | grep '^default dev ${VPN_IF}'")"
ROUTE6_BLACKHOLE="$(first_line_or_empty "ip -6 route show table \"${RT_TABLE_ID}\" | grep '^blackhole default'")"
KILLSWITCH_RULE="$(first_line_or_empty "iptables -S OUTPUT | grep -- '-m owner --uid-owner ${UID_VAL:-?} ! -o ${VPN_IF} -j DROP'")"

# reconcile daemon alive? (CGI is not root — check /proc cmdline, like the Kuma row)
RECON_STATE="stopped"
RPID="$(cat "${BASE}/var/reconcile.pid" 2>/dev/null)"
if [ -n "${RPID}" ] && [ -r "/proc/${RPID}/cmdline" ] \
   && tr '\0' ' ' < "/proc/${RPID}/cmdline" 2>/dev/null | grep -q 'guard-reconcile'; then
  RECON_STATE="running"
fi

# ── Public IP (VPN-cached, never WAN leak) ────────────────────────────────────
PUB_IP="$(cat "${BASE}/var/public_ip" 2>/dev/null || echo '')"

# ── IPv6 protection state (per IPV6_MODE) ────────────────────────────────────
# off  -> user opted out, not a factor
# block-> require the v6 UID rule + a v6 blackhole
# route-> require the v6 UID rule + (v6 default via VPN when up, blackhole when down)
IPV6_OK="yes"
case "${IPV6_MODE}" in
  off) ;;
  block)
    { [ -n "${RULE6_PRESENT}" ] && [ -n "${ROUTE6_BLACKHOLE}" ]; } || IPV6_OK="no" ;;
  *)
    if [ "${VPN_UP}" = "yes" ]; then
      { [ -n "${RULE6_PRESENT}" ] && [ -n "${ROUTE6_PRESENT}" ]; } || IPV6_OK="no"
    else
      { [ -n "${RULE6_PRESENT}" ] && [ -n "${ROUTE6_BLACKHOLE}" ]; } || IPV6_OK="no"
    fi ;;
esac

# ── Overall protection status ────────────────────────────────────────────────
FULLY_PROTECTED="no"
[ "${VPN_UP}" = "yes" ] && [ -n "${RULE_PRESENT}" ] && [ -n "${ROUTE_PRESENT}" ] \
  && [ "${IPV6_OK}" = "yes" ] && FULLY_PROTECTED="yes"

ROUTING_OK="no"
{ [ -n "${ROUTE_PRESENT}" ] || [ -n "${ROUTE_BLACKHOLE}" ]; } && [ -n "${RULE_PRESENT}" ] \
  && [ "${IPV6_OK}" = "yes" ] && ROUTING_OK="yes"

# ── Transmission package status ───────────────────────────────────────────────
TX_PKG_RUNNING="no"
if command -v synopkg >/dev/null 2>&1; then
  for _p in transmission Transmission sc-transmission; do
    if synopkg status "${_p}" 2>/dev/null | grep -q '"status"'; then
      synopkg status "${_p}" 2>/dev/null | grep -q '"status":"running"' && TX_PKG_RUNNING="yes"
      break
    fi
  done
fi

# ── Kill switch state ────────────────────────────────────────────────────────
if [ -n "${KILLSWITCH_RULE}" ]; then
  KS_STATE="active"
elif iptables -m owner -h >/dev/null 2>&1; then
  KS_STATE="inactive"
else
  KS_STATE="unsupported"
fi

# ── Kuma push monitor state ──────────────────────────────────────────────────
# disabled = no URL configured; inactive = URL set but daemon not alive;
# active = URL set and daemon process visible in /proc.
# We use [ -d /proc/<pid> ] (instead of kill -0) because the CGI runs as the
# DSM web user and cannot signal a root-owned process.
KUMA_PID_FILE="${BASE}/var/kuma-push.pid"
KUMA_STATE="disabled"
KUMA_HOST=""
if [ -n "${KUMA_PUSH_URL}" ]; then
  # Strip scheme + userinfo so a basic-auth form like
  # "https://user:pass@host/..." never renders credentials in the UI.
  KUMA_HOST="$(printf '%s' "${KUMA_PUSH_URL}" \
    | sed -nE 's|^https?://([^/?]*).*|\1|p' \
    | sed 's/.*@//')"
  KUMA_STATE="inactive"
  if [ -f "${KUMA_PID_FILE}" ]; then
    KPID="$(cat "${KUMA_PID_FILE}" 2>/dev/null)"
    # Verify identity via /proc/<pid>/cmdline so a recycled PID
    # (daemon died, kernel reassigned the PID to some unrelated
    # process) does not falsely report Active.
    if [ -n "${KPID}" ] && [ -r "/proc/${KPID}/cmdline" ] \
       && tr '\0' ' ' < "/proc/${KPID}/cmdline" 2>/dev/null \
          | grep -q 'guard-push'; then
      KUMA_STATE="active"
    fi
  fi
fi

# ── Raw status output ─────────────────────────────────────────────────────────
STATUS_OUTPUT="$(${CTL} status 2>&1 || printf 'Status command unavailable.')"

# ── Helper: yes/no → icon+label ──────────────────────────────────────────────
yn() {
  if [ "$1" = "yes" ]; then
    printf '<span class="badge ok">&#10004; %s</span>' "${2:-OK}"
  else
    printf '<span class="badge fail">&#10008; %s</span>' "${3:-No}"
  fi
}

# ── RPC port-push state (written by apply_forwarded_port on every reconcile) ──
# Lets the UI catch a stuck "auth failed" loop instead of showing a clean
# "kept in sync" line while guard.conf/guard.secret never actually reaches
# Transmission (the exact failure that hides behind an all-green dashboard).
RPC_PUSH_STATE="unknown"
RPC_PUSH_AGE=""
if [ -n "${FORWARDED_PORT}" ] && [ -f "${BASE}/var/rpc_port_status" ]; then
  read -r RPC_PUSH_STATE _rpc_ts _rpc_port < "${BASE}/var/rpc_port_status" 2>/dev/null
  case "${_rpc_ts}" in ''|*[!0-9]*) _rpc_ts="" ;; esac
  [ -n "${_rpc_ts}" ] && RPC_PUSH_AGE=$(( $(date +%s) - _rpc_ts ))
  # A record written for a port we are no longer configured to forward
  # (e.g. set-port ran while the VPN was down, so the record predates the
  # change) says nothing about the *current* FORWARDED_PORT — discard it.
  [ "${_rpc_port}" = "${FORWARDED_PORT}" ] || RPC_PUSH_STATE="unknown"
fi
# A recorded "ok" or "fail" is only meaningful while the reconcile daemon
# that wrote it is still alive and recent — otherwise a crashed daemon, a VPN
# that dropped after the last attempt, or curl going missing would leave a
# stale verdict (success *or* failure) on screen forever: a stale "fail"
# would send someone chasing valid credentials for nothing. Downgrade either
# to "unknown" (unverified) once no reconcile pass could plausibly have run.
case "${RPC_PUSH_STATE}" in
  ok|fail)
    _stale_after=$(( ${RECONCILE_INTERVAL_SEC:-30} * 3 ))
    if [ "${RECON_STATE}" != "running" ] \
       || { [ -n "${RPC_PUSH_AGE}" ] && [ "${RPC_PUSH_AGE}" -gt "${_stale_after}" ]; }; then
      RPC_PUSH_STATE="unknown"
    fi
    ;;
esac

# ── Cached port-test (open/closed/unknown) — refreshed by reconcile every ────
# PORT_TEST_INTERVAL_SEC regardless of whether Kuma is configured, so real
# port reachability shows up here even without Kuma. A successful RPC push
# only means "Transmission was told to listen on this port" — this is what
# actually caught the AirVPN case where the tunnel and RPC push both looked
# fine but the provider never rebound the forwarded port.
PORT_TEST_STATE="unknown"
PORT_TEST_AGE=""
if [ "${PORT_TEST_INTERVAL_SEC}" -gt 0 ] 2>/dev/null \
   && [ -n "${FORWARDED_PORT}" ] && [ -f "${BASE}/var/port-test.cache" ]; then
  read -r _pt_ts PORT_TEST_STATE _pt_port < "${BASE}/var/port-test.cache" 2>/dev/null
  case "${_pt_ts}" in ''|*[!0-9]*) _pt_ts="" ;; esac
  [ -n "${_pt_ts}" ] && PORT_TEST_AGE=$(( $(date +%s) - _pt_ts ))
  [ -z "${_pt_port}" ] || [ "${_pt_port}" = "${FORWARDED_PORT}" ] || PORT_TEST_STATE="unknown"
fi
case "${PORT_TEST_STATE}" in
  open|closed)
    _pt_stale_after=$(( PORT_TEST_INTERVAL_SEC * 3 ))
    if [ "${RECON_STATE}" != "running" ] \
       || { [ -n "${PORT_TEST_AGE}" ] && [ "${PORT_TEST_AGE}" -gt "${_pt_stale_after}" ]; }; then
      PORT_TEST_STATE="unknown"
    fi
    ;;
esac

# ── Chip helpers ──────────────────────────────────────────────────────────────
chip() {
  # chip STATE LABEL TARGET_ID
  printf '<a class="chip %s" href="#%s" onclick="return openAcc(this)"><span class="dot"></span>%s</a>' "$1" "$3" "$2"
}

PORT_CHIP_STATE="info"; PORT_CHIP_LABEL="No port"
if [ -n "${FORWARDED_PORT}" ]; then
  case "${RPC_PUSH_STATE}" in
    fail) PORT_CHIP_STATE="fail"; PORT_CHIP_LABEL="Port push failing" ;;
    ok)
      case "${PORT_TEST_STATE}" in
        open)   PORT_CHIP_STATE="ok";   PORT_CHIP_LABEL="Port ${FORWARDED_PORT}" ;;
        closed) PORT_CHIP_STATE="fail"; PORT_CHIP_LABEL="Port ${FORWARDED_PORT} closed" ;;
        *)      PORT_CHIP_STATE="warn"; PORT_CHIP_LABEL="Port ${FORWARDED_PORT} unverified" ;;
      esac
      ;;
    *)    PORT_CHIP_STATE="warn"; PORT_CHIP_LABEL="Port not verified" ;;
  esac
fi

# ── Banner values ─────────────────────────────────────────────────────────────
if [ "${FULLY_PROTECTED}" = "yes" ]; then
  BANNER_CLASS="banner-ok"
  BANNER_TITLE="Transmission is protected"
  BANNER_SUB="All traffic is routed through the VPN tunnel (${VPN_IF})"
else
  BANNER_CLASS="banner-fail"
  BANNER_TITLE="Protection incomplete"
  BANNER_SUB="Check the status chips below to find what is missing"
fi

cat <<ENDHTML
<div class="banner ${BANNER_CLASS}">
  <img src="images/icon_256.png" alt="Transmission VPN Shield" class="banner-logo">
  <div class="banner-text">
    <div class="banner-title">${BANNER_TITLE}</div>
    <div class="banner-sub">${BANNER_SUB}</div>
  </div>
  <a href="#" class="banner-action" onclick="window.location.reload();return false;">&#8635; Reload</a>
</div>

$([ "${FULLY_PROTECTED}" != "yes" ] && cat <<'FIXHINT'
<div class="fix-hint">
  <div class="fix-hint-icon">&#9881;</div>
  <div>
    <strong>Routing rules are not active yet.</strong>
    Go to <strong>DSM &rarr; Package Center &rarr; Transmission VPN Shield</strong>, click <strong>Stop</strong>, then <strong>Start</strong>.
    This applies the routing rules and activates protection. Reload this page afterwards to verify.
  </div>
</div>
FIXHINT
)

<div class="chip-row">
$(yn_state() { [ "$1" = "yes" ] && echo ok || echo fail; }
  chip "$(yn_state "${VPN_UP}")" "VPN $([ "${VPN_UP}" = yes ] && echo Connected || echo Disconnected)" "acc-routing"
  chip "$(yn_state "${ROUTING_OK}")" "Routing $([ "${ROUTING_OK}" = yes ] && echo Active || echo Inactive)" "acc-routing"
  case "${KS_STATE}" in
    active)      chip ok   "Kill Switch Active" "acc-killswitch" ;;
    inactive)    chip warn "Kill Switch Inactive" "acc-killswitch" ;;
    unsupported) chip info "Kill Switch N/A" "acc-killswitch" ;;
  esac
  chip "$(yn_state "$([ "${RECON_STATE}" = running ] && echo yes || echo no)")" "Auto-heal $([ "${RECON_STATE}" = running ] && echo Running || echo Stopped)" "acc-routing"
  chip "${PORT_CHIP_STATE}" "${PORT_CHIP_LABEL}" "acc-config"
  case "${KUMA_STATE}" in
    active)   chip ok   "Kuma Active" "acc-kuma" ;;
    inactive) chip warn "Kuma Inactive" "acc-kuma" ;;
    disabled) chip info "Kuma Off" "acc-kuma" ;;
  esac
)
  <a class="chip info" id="tx-chip" href="#" onclick="return false"><span class="dot"></span>Transmission&hellip;</a>
</div>

<div class="info-row">
  <div class="info-item">
    <span class="info-label">Public IP via VPN</span>
    <span class="info-value">${PUB_IP:-<span class=\"muted\">not yet fetched</span>}</span>
  </div>
  <div class="info-item">
    <span class="info-label">VPN interface</span>
    <span class="info-value">${VPN_IF}${VPN_ADDRS:+ <span class=\"muted\">(${VPN_ADDRS})</span>}</span>
  </div>
  <div class="info-item">
    <span class="info-label">Transmission user</span>
    <span class="info-value">${TRANSMISSION_USER} <span class="muted">UID ${UID_VAL:-n/a}</span></span>
  </div>
  <div class="info-item" id="tx-hint-wrap" style="display:none">
    <span class="info-label">Transmission</span>
    <span class="info-value" id="tx-hint"></span>
  </div>
</div>

$(if [ "${RPC_PUSH_STATE}" = "fail" ]; then
cat <<ALERT
<div class="alert-block">
  <strong>RPC push failing for port ${FORWARDED_PORT}.</strong> Every ${RECONCILE_INTERVAL_SEC}s reconcile pass has failed to push this port to Transmission over RPC. Check <code>RPC_USER</code>/<code>RPC_PASS</code> in <code>etc/guard.secret</code> match the Transmission web UI login — see <a href="${DOCS_URL}/documentation.html#forwarded-port" target="_blank" rel="noopener">RPC authentication</a> in the docs.
</div>
ALERT
elif [ "${RPC_PUSH_STATE}" = "ok" ] && [ "${PORT_TEST_STATE}" = "closed" ]; then
cat <<ALERT
<div class="alert-block">
  <strong>Port ${FORWARDED_PORT} tests closed from the internet</strong>, even though it was pushed to Transmission successfully. The tunnel and RPC are fine — the problem is one layer down, between the VPN tunnel and your provider's port-forwarding (some providers, AirVPN included, don't rebind a forwarded port to every new tunnel session).
  $([ -n "${DSM_VPN_NAME}" ] \
    && printf 'If you use DSM VPN Center, run <code>recover-vpn</code> from Task Scheduler to reconnect the tunnel — see the <a href="#acc-tasks" onclick="return openAcc(this)">Task Scheduler scripts</a> section below.' \
    || printf 'See <a href="%s/documentation.html#forwarded-port" target="_blank" rel="noopener">Forwarded port</a> in the docs.' "${DOCS_URL}")
</div>
ALERT
fi)

<div class="accordions">

  <details id="acc-routing">
    <summary>Traffic routing &amp; auto-heal</summary>
    <div class="acc-body">
      <p><strong>IPv4:</strong> $(if [ -n "${ROUTE_PRESENT}" ]; then echo "&#10004; via ${VPN_IF}"; elif [ -n "${ROUTE_BLACKHOLE}" ]; then echo "&#9888; blackhole (VPN down &mdash; fail-closed)"; else echo "&#10008; missing"; fi)</p>
      <p><strong>IPv6</strong> (mode=<code>${IPV6_MODE}</code>): $(
        case "${IPV6_MODE}" in
          off)   echo "not managed" ;;
          block) [ -n "${ROUTE6_BLACKHOLE}" ] && echo "&#10004; blocked (blackhole)" || echo "&#10008; not applied" ;;
          *)     if [ -n "${ROUTE6_PRESENT}" ]; then echo "&#10004; via ${VPN_IF}"; elif [ -n "${ROUTE6_BLACKHOLE}" ]; then echo "&#9888; blackhole (VPN down)"; else echo "&#10008; not applied"; fi ;;
        esac)</p>
      <p><strong>Route table entry:</strong> $([ -n "${RT_TABLE_ENTRY}" ] && echo "&#10004; present" || echo "&#10008; missing")</p>
      <p><strong>UID rule v4 / v6:</strong> $([ -n "${RULE_PRESENT}" ] && echo "&#10004;" || echo "&#10008;") / $([ -n "${RULE6_PRESENT}" ] && echo "&#10004;" || echo "&#10008;")</p>
      <h4>Auto-heal</h4>
      <p>Reconcile daemon: $([ "${RECON_STATE}" = "running" ] && printf '<span class="badge ok">&#10004; Running</span>' || printf '<span class="badge fail">&#10008; Stopped</span>')</p>
      <p>Re-applies routing &amp; the fail-closed blackhole every <strong>${RECONCILE_INTERVAL_SEC}s</strong>, so the shield recovers on its own after a VPN reconnect or reboot.</p>
    </div>
  </details>

  <details id="acc-killswitch">
    <summary>Kill switch</summary>
    <div class="acc-body">
      <p>$(case "${KS_STATE}" in
          active)      printf '<span class="badge ok">&#10004; Active</span>' ;;
          inactive)    printf '<span class="badge warn">&#9888; Inactive</span>' ;;
          unsupported) printf '<span class="badge info">&#8505; Not supported</span>' ;;
        esac)</p>
      <p>$(case "${KS_STATE}" in
          active)      echo "Applied at activation &mdash; blocks Transmission if VPN drops. Note: not removed automatically when the package is stopped (DSM limitation)." ;;
          inactive)    echo "Rule not found &mdash; re-run the activate script as root to apply it." ;;
          unsupported) echo "Kernel lacks iptables owner match. Fail-closed protection is still enforced &mdash; when the VPN is down the shield installs a <em>blackhole</em> default route in the dedicated table, so Transmission traffic is dropped, never leaked." ;;
        esac)</p>
      <p>Set <code>ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="0"</code> in <code>guard.conf</code> to keep it routing-only (blackhole) instead of also dropping via <code>iptables</code>.</p>
    </div>
  </details>

  <details id="acc-kuma">
    <summary>Uptime Kuma push monitor</summary>
    <div class="acc-body">
      <p><strong>Monitoring:</strong> $(case "${KUMA_STATE}" in
        active)   printf '<span class="badge ok">&#10004; Active</span>' ;;
        inactive) printf '<span class="badge warn">&#9888; Inactive</span>' ;;
        disabled) printf '<span class="badge info">&#8505; Off</span>' ;;
      esac)</p>
      $(if [ "${KUMA_STATE}" != "disabled" ]; then
          printf '<p><strong>Heartbeat:</strong> every %ss</p>' "${KUMA_PUSH_INTERVAL_SEC}"
          [ -n "${KUMA_HOST}" ] && printf '<p><strong>Server:</strong> %s</p>' "${KUMA_HOST}"
        fi)
      $(case "${KUMA_STATE}" in
          inactive) printf '<p>URL set but the push daemon is not running &mdash; restart the package from <strong>DSM &rarr; Package Center</strong> to start it.</p>' ;;
          disabled) printf '<p>Set <code>KUMA_PUSH_URL</code> in <code>guard.conf</code> to push health to <a href="https://github.com/louislam/uptime-kuma" target="_blank" rel="noopener">Uptime Kuma</a>. Full setup in the <a href="%s/documentation.html#kuma" target="_blank" rel="noopener">docs</a>.</p>' "${DOCS_URL}" ;;
        esac)
    </div>
  </details>

  <details id="acc-tasks">
    <summary>Task Scheduler scripts</summary>
    <div class="acc-body">
      <p>One-time or on-demand scripts run as <code>root</code> via DSM <strong>Control Panel &rarr; Task Scheduler &rarr; Create &rarr; Triggered Task &rarr; User-defined script</strong>. None need <strong>Enabled</strong> checked.</p>
      <div class="task-table-wrap">
      <table class="task-table">
        <thead><tr><th>Script</th><th>Command</th><th>When</th></tr></thead>
        <tbody>
          <tr><td><code>activate</code></td><td><code>/var/packages/transmission-vpn-shield/scripts/activate</code></td><td>After install / upgrade</td></tr>
          <tr><td><code>activate</code> (with port)</td><td><code>/var/packages/transmission-vpn-shield/scripts/activate 56460</code></td><td>Same, replace <code>56460</code> with your forwarded port</td></tr>
          <tr><td><code>set-port</code></td><td><code>/var/packages/transmission-vpn-shield/scripts/set-port 56460</code></td><td>Change forwarded port, replace <code>56460</code> with yours</td></tr>
          <tr><td><code>recover-heartbeat</code></td><td><code>/var/packages/transmission-vpn-shield/scripts/recover-heartbeat</code></td><td>Kuma heartbeat stuck down</td></tr>
          <tr><td><code>recover-vpn</code></td><td><code>/var/packages/transmission-vpn-shield/scripts/recover-vpn AirVPN</code></td><td>Port closed, shield green (DSM VPN Center, replace <code>AirVPN</code> with your profile or omit if set via <code>DSM_VPN_NAME</code>)</td></tr>
        </tbody>
      </table>
      </div>
      <p><a href="${DOCS_URL}/documentation.html#task-scheduler-scripts" target="_blank" rel="noopener">Full documentation &rarr;</a></p>
    </div>
  </details>

  <details id="acc-config">
    <summary>Quick configuration</summary>
    <div class="acc-body">
      <p>Config file: <code>/var/packages/transmission-vpn-shield/etc/guard.conf</code> (edit, then restart the package)</p>
      <p><strong>Forwarded port:</strong> set <code>FORWARDED_PORT="56460"</code>, or run <code>set-port</code> from Task Scheduler (see above).</p>
      <p><strong>RPC auth:</strong> if Transmission has authentication enabled, put credentials in the root-only <code>etc/guard.secret</code> (<code>RPC_USER</code> / <code>RPC_PASS</code>) or the port push fails silently with HTTP 401.</p>
      $([ -z "${DSM_VPN_NAME}" ] && printf '<p><strong>DSM VPN Center recovery:</strong> no default profile set &mdash; set <code>DSM_VPN_NAME</code>, or pass the profile name directly: <code>recover-vpn AirVPN</code>.</p>' || printf '<p><strong>DSM VPN Center recovery:</strong> configured for profile <code>%s</code>.</p>' "${DSM_VPN_NAME}")
      <p>For the full guide (Kuma setup, IPv6 modes, RPC auth, forwarded ports) see the <a href="${DOCS_URL}/documentation.html" target="_blank" rel="noopener">online documentation</a>.</p>
    </div>
  </details>

  <details id="acc-advanced">
    <summary>Advanced &mdash; raw status output</summary>
    <div class="acc-body" style="padding-bottom:0;">
      <button class="btn btn-secondary" id="refresh-btn" style="font-size:.78rem;padding:6px 14px;margin-bottom:10px;">&#8635; Refresh raw output</button>
    </div>
    <pre id="status-output">$(printf '%s' "${STATUS_OUTPUT}" | sed 's/&/\&amp;/g; s/</\&lt;/g')</pre>
  </details>

  <details id="acc-log">
    <summary>Shield log (last 120 lines)</summary>
    <pre>$(tail -n 120 "${BASE}/var/shield.log" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g' || printf '(no log yet)')</pre>
  </details>

</div>

<footer>
  Lovingly developed by the usually-on-vacation brain cell of Gioxx &#10084;&#65039; &mdash; Flawed by design, just like my code &#128686;<br>
  Use <a href="https://iknowwhatyoudownload.com/" target="_blank" rel="noopener">iknowwhatyoudownload.com</a> if you want to check if your real IP is associated with any public torrent activity.<br>
  <a href="${DOCS_URL}" target="_blank" rel="noopener">Documentation</a> &middot;
  <a href="${REPO_URL}/" target="_blank" rel="noopener">GitHub</a> &middot;
  <a href="${REPO_URL}/issues/new" target="_blank" rel="noopener">Open an issue</a>
</footer>
</div>

<script>
function openAcc(a) {
  var id = a.getAttribute('href').slice(1);
  var el = document.getElementById(id);
  if (el) {
    el.open = true;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  return false;
}

(function () {
  const btn = document.getElementById('refresh-btn');
  const pre = document.getElementById('status-output');
  if (!btn) return;
  async function doRefresh() {
    btn.disabled = true;
    btn.textContent = 'Refreshing…';
    try {
      const res  = await fetch('?mode=status', { cache: 'no-store' });
      const text = await res.text();
      if (pre) pre.textContent = text;
    } catch (e) {
      if (pre) pre.textContent = 'Refresh error: ' + e;
    } finally {
      btn.disabled = false;
      btn.innerHTML = '↻ Refresh status';
    }
  }
  btn.addEventListener('click', doRefresh);
}());

(async function checkTxStatus() {
  const chipEl = document.getElementById('tx-chip');
  const hintWrap = document.getElementById('tx-hint-wrap');
  const hint = document.getElementById('tx-hint');
  if (!chipEl) return;
  try {
    const res  = await fetch('?mode=tx-status', { cache: 'no-store' });
    const text = (await res.text()).trim();
    if (text === 'running') {
      chipEl.className = 'chip ok';
      chipEl.innerHTML = '<span class="dot"></span>Transmission Running';
      if (hintWrap) hintWrap.style.display = 'none';
    } else {
      chipEl.className = 'chip warn';
      chipEl.innerHTML = '<span class="dot"></span>Transmission Stopped';
      if (hintWrap && hint) {
        hint.innerHTML = 'Stopped — start it from <strong>Package Center</strong>';
        hintWrap.style.display = 'flex';
      }
    }
  } catch (e) {
    chipEl.className = 'chip info';
    chipEl.innerHTML = '<span class="dot"></span>Transmission unknown';
  }
})();
</script>
</body>
</html>
ENDHTML

exit 0
