#!/bin/sh
# Transmission VPN Shield - CGI status page

set -eu

PKG_NAME="transmission-vpn-shield"
BASE="/var/packages/${PKG_NAME}"
CTL="${BASE}/scripts/start-stop-status"

# AJAX endpoint: return plain status text only
if echo "${QUERY_STRING:-}" | grep -q 'mode=status'; then
  STATUS_OUTPUT="$("${CTL}" status 2>&1 || printf "Status command unavailable.")"
  echo "Content-type: text/plain"
  echo ""
  printf "%s" "${STATUS_OUTPUT}"
  exit 0
fi

# Defaults
TRANSMISSION_USER="transmission"
VPN_IF="tun0"
RT_TABLE_ID="200"
RT_TABLE_NAME="transmissionvpn"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="1"
CONF_LOADED="(default values)"

for f in \
  "${BASE}/target/conf/guard.conf" \
  "${BASE}/conf/guard.conf"; do
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
    CONF_LOADED="$f"
    break
  fi
done

# Detect actual transmission user (first that exists)
detect_user() {
  for u in "${TRANSMISSION_USER}" "sc-transmission" "transmission" "debian-transmission"; do
    [ -n "$u" ] || continue
    uid=$(id -u "$u" 2>/dev/null) || continue
    TRANSMISSION_USER="$u"
    echo "$uid"
    return
  done
  echo ""
}

first_line_or_empty() { sh -c "$1" 2>/dev/null | head -n1; }

UID_VAL="$(detect_user)"
VPN_UP="no"
[ -n "$(ip link show "${VPN_IF}" 2>/dev/null | head -n1)" ] && \
  ip -4 addr show dev "${VPN_IF}" 2>/dev/null | grep -q 'inet ' && VPN_UP="yes"
VPN_ADDRS="$(ip -4 addr show dev "${VPN_IF}" 2>/dev/null | awk '/inet /{print $2}' | paste -sd, -)"
VPN_IP4="$(ip -4 addr show dev "${VPN_IF}" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)"

get_public_ip_vpn() {
  [ "${VPN_UP}" = "yes" ] || { echo ""; return; }
  CURL_BIN="$(command -v curl 2>/dev/null || true)"
  WGET_BIN="$(command -v wget 2>/dev/null || true)"
  if [ -n "${CURL_BIN}" ]; then
    ip=$("${CURL_BIN}" -s --max-time 3 --interface "${VPN_IF}" https://ip.gioxx.org 2>/dev/null | head -n1)
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip=$("${CURL_BIN}" -s --max-time 3 --interface "${VPN_IF}" https://api.ipify.org 2>/dev/null | head -n1)
    [ -n "$ip" ] && { echo "$ip"; return; }
  fi
  if [ -n "${WGET_BIN}" ] && [ -n "${VPN_IP4}" ] && "${WGET_BIN}" --help 2>&1 | grep -q -- "--bind-address"; then
    ip=$("${WGET_BIN}" -qO- --timeout=3 --bind-address="${VPN_IP4}" https://ip.gioxx.org 2>/dev/null | head -n1)
    [ -n "$ip" ] && { echo "$ip"; return; }
  fi
  echo ""
}
PUB_IP="$(get_public_ip_vpn)"
PUB_IP="$(wget -qO- -t1 -T2 https://ifconfig.co 2>/dev/null || curl -s --max-time 2 https://ifconfig.co 2>/dev/null || dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | head -n1)"

RT_TABLE_ENTRY="$(first_line_or_empty "grep -E '^[[:space:]]*${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}\$' /etc/iproute2/rt_tables")"
RULE_PRESENT="$(first_line_or_empty "ip rule show | grep -E 'uidrange .* lookup ${RT_TABLE_NAME}'")"
ROUTE_PRESENT="$(first_line_or_empty "ip route show table \"${RT_TABLE_NAME}\" | grep '^default dev ${VPN_IF}'")"
KILLSWITCH_RULE="$(first_line_or_empty "iptables -S OUTPUT | grep -- '-m owner --uid-owner ${UID_VAL:-?} ! -o ${VPN_IF} -j DROP'")"

STATUS_OUTPUT="$("${CTL}" status 2>&1 || printf "Status command unavailable.")"

# Derived summary
if [ -n "${RULE_PRESENT}" ] && [ -n "${ROUTE_PRESENT}" ]; then
  PROTECTED_STATUS="yes (uid rule + vpn default route active)"
else
  PROTECTED_STATUS="no (missing uid rule or vpn route)"
fi

if [ -n "${KILLSWITCH_RULE}" ]; then
  KS_STATE="present"
  KS_DESC="-A OUTPUT -m owner --uid-owner ${UID_VAL:-?} ! -o ${VPN_IF} -j DROP"
elif echo "${STATUS_OUTPUT}" | grep -q "Kill switch unsupported"; then
  KS_STATE="unsupported"
  KS_DESC="iptables owner match not available on this NAS"
else
  KS_STATE="absent"
  KS_DESC="not installed"
fi

echo "Content-type: text/html"
echo ""

cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Transmission VPN Shield</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f4f6f8; margin: 0; padding: 20px; }
    .box { background: #fff; padding: 20px; border-radius: 8px; max-width: 900px; box-shadow: 0 2px 6px rgba(0,0,0,.1); line-height: 1.5; }
    h1 { margin-top: 0; }
    code { background: #eee; padding: 2px 4px; border-radius: 4px; }
    pre { background: #111; color: #eee; padding: 12px; border-radius: 6px; overflow-x: auto; }
    .status-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; }
    .pill-ok { background: #d6f6e2; color: #0a7a2f; }
    .pill-bad { background: #ffe0e0; color: #9b1c1c; }
    button { background: #0b6cff; color: #fff; border: none; border-radius: 6px; padding: 8px 14px; font-size: 14px; cursor: pointer; }
    button:disabled { opacity: 0.7; cursor: progress; }
    .toolbar { display: flex; align-items: center; gap: 8px; margin: 4px 0 12px; }
  </style>
</head>
<body>
  <div class="box">
    <div style="display:flex; align-items:center; gap:12px; flex-wrap:wrap;">
      <img src="images/icon_120.png" alt="Transmission VPN Shield" width="56" height="56" style="border-radius:12px;">
      <div>
        <h1 style="margin:0;">Transmission VPN Shield</h1>
        <p style="margin:4px 0 0;">Forces Transmission traffic through VPN, keeps LAN access for UI/automation, kill switch when supported.</p>
      </div>
    </div>

    <h2>Active config</h2>
    <div class="status-grid">
      <div>Loaded file: <code>${CONF_LOADED}</code></div>
      <div>Transmission user: <code>${TRANSMISSION_USER}</code> (UID ${UID_VAL:-n/a})</div>
      <div>VPN interface: <code>${VPN_IF}</code></div>
      <div>Routing table: <code>${RT_TABLE_ID} ${RT_TABLE_NAME}</code></div>
      <div>Kill switch if VPN down: <code>${ENFORCE_KILLSWITCH_WHEN_VPN_DOWN}</code></div>
      <div>VPN addresses: <code>${VPN_ADDRS:-n/a}</code></div>
      <div>Public IP (via VPN): <code>$(cat /var/packages/transmission-vpn-shield/var/public_ip 2>/dev/null || echo n/a)</code> <a href="https://www.yougetsignal.com/tools/open-ports/" target="_blank" rel="noopener" style="font-size:12px; margin-left:8px; color:#0b6cff; text-decoration:none;">Check port</a></div>
    </div>

    <h2>Protection status</h2>
    <ul>
      <li>VPN up:
        <span class="pill $( [ "${VPN_UP}" = "yes" ] && echo pill-ok || echo pill-bad)">
          $( [ "${VPN_UP}" = "yes" ] && echo "yes" || echo "no" )
        </span>
      </li>
      <li>Transmission protected: <code>${PROTECTED_STATUS}</code></li>
      <li>ip rule present: <code>${RULE_PRESENT:-no}</code></li>
      <li>Default route in table: <code>${ROUTE_PRESENT:-no}</code></li>
      <li>Kill switch: <code>${KS_STATE}</code> (${KS_DESC})</li>
      <li>rt_tables entry: <code>${RT_TABLE_ENTRY:-no}</code></li>
    </ul>

    <h2>Status command output</h2>
    <div class="toolbar">
      <button id="refresh-btn">Refresh status</button>
      <span id="status-updated-at">Last update: page load</span>
    </div>
    <pre id="status-output">$(printf "%s" "${STATUS_OUTPUT}" | sed 's/&/&amp;/g; s/</\&lt;/g')</pre>

    <p>Use Package Center to start/stop the guard. This page recomputes on each open.</p>
    <hr>
    <p style="margin-top:20px; color:#555; font-size:14px;">
      Lovingly developed by the usually-on-vacation brain cell of Gioxx ❤️ — Flawed by design, just like my code 🚮<br>
      Transmission VPN Shield is an open source project, source code is available on <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/" target="_blank" rel="noopener" style="color:#0b6cff; text-decoration:none;">GitHub</a> - Need support? <a href="https://github.com/gioxx/Syno-TransmissionVPNShield/issues/new" target="_blank" rel="noopener" style="color:#0b6cff; text-decoration:none;">Open an issue</a>.<br>
      Curious what your IP has torrented? Try <a href="https://iknowwhatyoudownload.com/" target="_blank" rel="noopener" style="color:#0b6cff; text-decoration:none;">iknowwhatyoudownload.com</a> :-)
    </p>
  </div>
  <script>
    (function() {
      const btn = document.getElementById('refresh-btn');
      const pre = document.getElementById('status-output');
      const badge = document.getElementById('status-updated-at');
      async function refresh() {
        btn.disabled = true;
        const orig = btn.textContent;
        btn.textContent = 'Refreshing...';
        try {
          const res = await fetch('?mode=status', { cache: 'no-store' });
          const text = await res.text();
          pre.textContent = text;
          badge.textContent = 'Last update: ' + new Date().toLocaleString();
        } catch (e) {
          pre.textContent = 'Refresh error: ' + e;
        } finally {
          btn.disabled = false;
          btn.textContent = orig;
        }
      }
      btn.addEventListener('click', refresh);
    }());
  </script>
</body>
</html>
EOF

exit 0
