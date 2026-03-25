#!/bin/sh
# Transmission VPN Shield - CGI status page
# 0.1.2: beginner-friendly redesign, fixed Content-Type, removed PUB_IP WAN leak

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
TRANSMISSION_USER="transmission"
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
  # $1 = value ("yes"/"no"), $2 = label-ok, $3 = label-fail
  if [ "$1" = "yes" ]; then
    printf '<span class="badge ok">✔ %s</span>' "${2:-OK}"
  else
    printf '<span class="badge fail">✘ %s</span>' "${3:-No}"
  fi
}

# ── Content-Type header — MUST be first output ───────────────────────────────
printf 'Content-type: text/html; charset=utf-8\r\n\r\n'

# ── Compute top-level banner values ──────────────────────────────────────────
if [ "${FULLY_PROTECTED}" = "yes" ]; then
  BANNER_CLASS="banner-ok"
  BANNER_ICON="🛡️"
  BANNER_TITLE="Transmission is protected"
  BANNER_SUB="All traffic is routed through the VPN tunnel (${VPN_IF})"
else
  BANNER_CLASS="banner-fail"
  BANNER_ICON="⚠️"
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

    /* ── Banner ─────────────────────────────────────────── */
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
    .banner-icon { font-size: 3rem; line-height: 1; flex-shrink: 0; }
    .banner-title { font-size: 1.5rem; font-weight: 700; }
    .banner-sub   { font-size: .95rem; opacity: .88; margin-top: 4px; }

    /* ── Grid of cards ──────────────────────────────────── */
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
    .card-header {
      display: flex;
      align-items: center;
      gap: 10px;
      margin-bottom: 12px;
    }
    .card-icon { font-size: 1.5rem; }
    .card-title { font-size: .8rem; font-weight: 600; text-transform: uppercase;
                  letter-spacing: .06em; color: #666; }

    .card-value {
      font-size: 1.15rem;
      font-weight: 700;
      color: #1a1a2e;
      word-break: break-all;
    }
    .card-sub {
      font-size: .8rem;
      color: #888;
      margin-top: 4px;
    }

    /* ── Badges ─────────────────────────────────────────── */
    .badge {
      display: inline-block;
      padding: 3px 10px;
      border-radius: 999px;
      font-size: .85rem;
      font-weight: 600;
    }
    .badge.ok   { background: #d4f8e8; color: #0a7040; }
    .badge.warn { background: #fff3cd; color: #856404; }
    .badge.fail { background: #fde8e8; color: #9b1c1c; }
    .badge.info { background: #e8f0fe; color: #1a56db; }

    /* ── Action bar ─────────────────────────────────────── */
    .actions {
      max-width: 860px;
      margin: 0 auto 24px;
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      align-items: center;
    }
    .btn {
      display: inline-flex; align-items: center; gap: 6px;
      padding: 10px 20px;
      border-radius: 8px;
      font-size: .9rem; font-weight: 600;
      cursor: pointer; border: none; text-decoration: none;
      transition: opacity .15s;
    }
    .btn:hover { opacity: .85; }
    .btn-primary { background: #0b6cff; color: #fff; }
    .btn-secondary { background: #e8edf4; color: #1a1a2e; }
    .btn:disabled { opacity: .5; cursor: progress; }
    #refresh-ts { font-size: .8rem; color: #888; }

    /* ── Details / raw output ───────────────────────────── */
    .details-wrap {
      max-width: 860px;
      margin: 0 auto 24px;
    }
    details {
      background: #fff;
      border-radius: 12px;
      box-shadow: 0 2px 10px rgba(0,0,0,.07);
      overflow: hidden;
    }
    summary {
      padding: 14px 20px;
      font-weight: 600;
      font-size: .9rem;
      cursor: pointer;
      user-select: none;
      color: #444;
    }
    summary:hover { background: #f8f9fb; }
    pre {
      background: #16213e;
      color: #a8d8a8;
      padding: 16px 20px;
      font-size: .8rem;
      line-height: 1.6;
      overflow-x: auto;
      white-space: pre-wrap;
      margin: 0;
    }

    /* ── Footer ─────────────────────────────────────────── */
    footer {
      max-width: 860px;
      margin: 0 auto;
      font-size: .78rem;
      color: #aaa;
      text-align: center;
      line-height: 1.8;
    }
    footer a { color: #0b6cff; text-decoration: none; }
    footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>

<!-- ── Big status banner ──────────────────────────────────────────────────── -->
<div class="banner ${BANNER_CLASS}">
  <div class="banner-icon">${BANNER_ICON}</div>
  <div>
    <div class="banner-title">${BANNER_TITLE}</div>
    <div class="banner-sub">${BANNER_SUB}</div>
  </div>
</div>

<!-- ── Status cards ───────────────────────────────────────────────────────── -->
<div class="grid">

  <div class="card">
    <div class="card-header">
      <span class="card-icon">🔒</span>
      <span class="card-title">VPN Tunnel</span>
    </div>
    <div class="card-value">$(yn "${VPN_UP}" "Connected" "Disconnected")</div>
    <div class="card-sub">Interface: <strong>${VPN_IF}</strong>${VPN_ADDRS:+ · ${VPN_ADDRS}}</div>
  </div>

  <div class="card">
    <div class="card-header">
      <span class="card-icon">🌍</span>
      <span class="card-title">Public IP via VPN</span>
    </div>
    <div class="card-value">${PUB_IP:-<span style="color:#bbb;font-weight:400">not yet fetched</span>}</div>
    <div class="card-sub">Refreshed every 2h by the background daemon</div>
  </div>

  <div class="card">
    <div class="card-header">
      <span class="card-icon">🧭</span>
      <span class="card-title">Traffic Routing</span>
    </div>
    <div class="card-value">$([ -n "${RULE_PRESENT}" ] && [ -n "${ROUTE_PRESENT}" ] && yn "yes" "Active" "Inactive" || yn "no" "Active" "Inactive")</div>
    <div class="card-sub">
      Route table: $([ -n "${RT_TABLE_ENTRY}" ] && echo "✔ present" || echo "✘ missing") ·
      UID rule: $([ -n "${RULE_PRESENT}" ] && echo "✔ present" || echo "✘ missing")
    </div>
  </div>

  <div class="card">
    <div class="card-header">
      <span class="card-icon">🚫</span>
      <span class="card-title">Kill Switch</span>
    </div>
    <div class="card-value">
      $(case "${KS_STATE}" in
          active)      printf '<span class="badge ok">✔ Active</span>' ;;
          inactive)    printf '<span class="badge warn">⚠ Inactive</span>' ;;
          unsupported) printf '<span class="badge info">ℹ Not supported</span>' ;;
        esac)
    </div>
    <div class="card-sub">
      $(case "${KS_STATE}" in
          active)      echo "Blocks Transmission if VPN drops" ;;
          inactive)    echo "Rule not found — restart the package" ;;
          unsupported) echo "Kernel lacks iptables owner match (routing still protects)" ;;
        esac)
    </div>
  </div>

  <div class="card">
    <div class="card-header">
      <span class="card-icon">⚙️</span>
      <span class="card-title">Transmission User</span>
    </div>
    <div class="card-value">${TRANSMISSION_USER}</div>
    <div class="card-sub">UID: ${UID_VAL:-n/a}</div>
  </div>

  <div class="card">
    <div class="card-header">
      <span class="card-icon">🔌</span>
      <span class="card-title">Forwarded Port</span>
    </div>
    <div class="card-value">
      $([ -n "${FORWARDED_PORT}" ] \
        && printf '<span class="badge ok">%s</span>' "${FORWARDED_PORT}" \
        && printf ' <a href="https://www.yougetsignal.com/tools/open-ports/" target="_blank" style="font-size:.75rem;color:#0b6cff;text-decoration:none;">check ↗</a>' \
        || printf '<span class="badge warn">Not configured</span>')
    </div>
    <div class="card-sub">Set FORWARDED_PORT in guard.conf to auto-push to Transmission</div>
  </div>

</div>

<!-- ── Action bar ─────────────────────────────────────────────────────────── -->
<div class="actions">
  <button class="btn btn-primary" id="refresh-btn">↻ Refresh status</button>
  <a class="btn btn-secondary" href="https://www.yougetsignal.com/tools/open-ports/" target="_blank" rel="noopener">🌐 Check open port</a>
  <span id="refresh-ts"></span>
</div>

<!-- ── Advanced / raw output ──────────────────────────────────────────────── -->
<div class="details-wrap">
  <details>
    <summary>🔧 Advanced — raw status output</summary>
    <pre id="status-output">$(printf '%s' "${STATUS_OUTPUT}" | sed 's/&/\&amp;/g; s/</\&lt;/g')</pre>
  </details>
</div>

<!-- ── Footer ─────────────────────────────────────────────────────────────── -->
<footer>
  Lovingly developed by the usually-on-vacation brain cell of Gioxx ❤️ — Flawed by design, just like my code 🚮<br>
  <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/" target="_blank" rel="noopener">GitHub</a> ·
  <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new" target="_blank" rel="noopener">Open an issue</a> ·
  <a href="https://iknowwhatyoudownload.com/" target="_blank" rel="noopener">iknowwhatyoudownload.com</a>
</footer>

<script>
(function () {
  const btn   = document.getElementById('refresh-btn');
  const pre   = document.getElementById('status-output');
  const ts    = document.getElementById('refresh-ts');

  async function doRefresh() {
    btn.disabled = true;
    btn.textContent = '↻ Refreshing…';
    try {
      const res  = await fetch('?mode=status', { cache: 'no-store' });
      const text = await res.text();
      if (pre) pre.textContent = text;
      ts.textContent = 'Last refresh: ' + new Date().toLocaleTimeString();
    } catch (e) {
      ts.textContent = 'Refresh error: ' + e;
    } finally {
      btn.disabled = false;
      btn.textContent = '↻ Refresh status';
    }
  }

  btn.addEventListener('click', doRefresh);
}());
</script>

</body>
</html>
ENDHTML

exit 0
