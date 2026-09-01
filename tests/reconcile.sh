#!/bin/sh
# tests/reconcile.sh — integration tests for `start-stop-status reconcile`
#
# Requires: root, Linux, iproute2. Uses a throwaway dummy interface (tvps0) and a
# dedicated routing table (199) so it never touches the real VPN or table 200.
#
# Usage:  sudo sh tests/reconcile.sh
#
# Internal testability contract exercised here:
#   - `GUARD_CONF=<file>` makes load_conf source that file instead of the
#     installed guard.conf; env vars already set still win.
#   - the `reconcile` action does NOT check the needs-activation flag.
#   - PATH is prefixed with a shim dir providing fake `synopkg` / `curl` /
#     `logger` so the test does not depend on Transmission or DSM.

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "${HERE}/.." && pwd)
SS="${REPO}/synology/scripts/start-stop-status"
COMMON="${REPO}/synology/scripts/_common.sh"

IFACE="tvps0"
TID="199"
TNAME="tvpstest"
TEST_UID=$(id -u)          # any real uid works for uidrange rules
# Shims are executed via PATH, so WORK must sit on an exec-capable filesystem.
# Synology mounts /tmp noexec, so default mktemp (TMPDIR=/tmp) breaks the shims;
# create WORK next to the test instead (falls back to mktemp default elsewhere).
WORK=$(mktemp -d "${HERE}/tvps-work.XXXXXX" 2>/dev/null || mktemp -d)
SHIM="${WORK}/bin"
GUARD="${WORK}/guard.conf"
RPC_LOG="${WORK}/rpc.log"
SYNOPKG_LOG="${WORK}/synopkg.log"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
notok(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
check(){ # check "desc" "command..."  -> pass if command succeeds
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "${desc}"; else notok "${desc}"; fi
}
check_not(){
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then notok "${desc}"; else ok "${desc}"; fi
}

have_route_v4(){ ip    route show table "${TID}" 2>/dev/null | grep -Eq "$1"; }
have_route_v6(){ ip -6 route show table "${TID}" 2>/dev/null | grep -Eq "$1"; }
have_rule_v4(){  ip    rule show 2>/dev/null | grep -Eq "uidrange ${TEST_UID}-${TEST_UID} .*lookup (${TID}|${TNAME})"; }
have_rule_v6(){  ip -6 rule show 2>/dev/null | grep -Eq "uidrange ${TEST_UID}-${TEST_UID} .*lookup (${TID}|${TNAME})"; }

cleanup(){
  ip -6 rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  ip    rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  ip    route flush table "${TID}" 2>/dev/null || true
  ip -6 route flush table "${TID}" 2>/dev/null || true
  ip link del "${IFACE}" 2>/dev/null || true
  sed -i "/^[[:space:]]*${TID}[[:space:]]\+${TNAME}\$/d" /etc/iproute2/rt_tables 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 2; }
command -v ip >/dev/null 2>&1 || { echo "iproute2 'ip' not found"; exit 2; }
[ -f "${SS}" ] || { echo "missing ${SS}"; exit 2; }

# --- shims -------------------------------------------------------------------
mkdir -p "${SHIM}"

echo running > "${WORK}/tx_status"
cat > "${SHIM}/synopkg" <<EOF
#!/bin/sh
echo "\$@" >> "${SYNOPKG_LOG}"
case "\$1 \$2" in
  "status transmission") echo "{\"package\":\"transmission\",\"status\":\"\$(cat "${WORK}/tx_status" 2>/dev/null || echo running)\"}"; exit 0 ;;
  "status "*)            exit 1 ;;
  *)                     exit 0 ;;
esac
EOF

# curl shim emulates Transmission RPC: 409 handshake then session-get/session-set.
# The "current" peer-port is read from ${WORK}/fake_peerport (default 12345) so
# tests can vary it without relying on env propagation into the shim.
echo 12345 > "${WORK}/fake_peerport"
cat > "${SHIM}/curl" <<EOF
#!/bin/sh
args="\$*"
echo "\${args}" >> "${RPC_LOG}"
pp=\$(cat "${WORK}/fake_peerport" 2>/dev/null || echo 12345)
case "\${args}" in
  *"X-Transmission-Session-Id"*"session-set"*) echo '{"result":"success"}'; exit 0 ;;
  *"X-Transmission-Session-Id"*"session-get"*) echo "{\"arguments\":{\"peer-port\":\${pp}},\"result\":\"success\"}"; exit 0 ;;
  *"X-Transmission-Session-Id"*"port-test"*)   echo '{"arguments":{"port-is-open":true},"result":"success"}'; exit 0 ;;
  *) printf 'X-Transmission-Session-Id: deadbeef\n'; exit 0 ;;
esac
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "${SHIM}"/*
PATH="${SHIM}:${PATH}"
export PATH

# --- config ----------------------------------------------------------------
cat > "${GUARD}" <<EOF
TRANSMISSION_USER="$(id -un)"
VPN_IF="${IFACE}"
RT_TABLE_ID="${TID}"
RT_TABLE_NAME="${TNAME}"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="1"
PUBLIC_IP_REFRESH_SEC="0"
FORWARDED_PORT="55555"
RECONCILE_INTERVAL_SEC="30"
IPV6_MODE="route"
RPC_PORT="9091"
RPC_USER=""
RPC_PASS=""
KUMA_PUSH_URL=""
EOF
export GUARD_CONF="${GUARD}"

reconcile(){ IPV6_MODE="${1:-route}" GUARD_CONF="${GUARD}" sh "${SS}" reconcile >/dev/null 2>&1; }

# A veth pair stands in for the VPN interface: unlike an unattached tun, IFACE
# gets carrier as soon as both ends are up (no NO-CARRIER / "state DOWN"), so
# vpn_is_up() reads it as up deterministically. reconcile only inspects link
# state + addresses, never the link type. IFACE down == VPN down.
IFACE_PEER="${IFACE}p"
mk_iface(){
  ip link del "${IFACE}" 2>/dev/null || true
  _i=0
  while ip link show "${IFACE}" >/dev/null 2>&1 && [ "${_i}" -lt 30 ]; do _i=$((_i+1)); sleep 0.1; done
  ip link add "${IFACE}" type veth peer name "${IFACE_PEER}"
  ip link set "${IFACE_PEER}" up
  ip link set "${IFACE}" up
  ip addr add 10.9.9.2/24 dev "${IFACE}"
  ip -6 addr add fdcc:9::2/64 dev "${IFACE}" 2>/dev/null || true
  _i=0
  while ip link show "${IFACE}" 2>/dev/null | head -n1 | grep -q "state DOWN" && [ "${_i}" -lt 30 ]; do _i=$((_i+1)); sleep 0.1; done
}

echo "# reconcile integration tests (iface=${IFACE} table=${TID})"

# ============ 1. VPN up ============
mk_iface
reconcile route
check     "vpn up: v4 default via ${IFACE} in table ${TID}"  have_route_v4 "^default dev ${IFACE}"
check     "vpn up: v6 default via ${IFACE} in table ${TID}"  have_route_v6 "^default dev ${IFACE}"
check     "vpn up: v4 ip rule for uid present"               have_rule_v4
check     "vpn up: v6 ip rule for uid present"               have_rule_v6

# ============ 2. VPN down -> fail closed ============
ip link set "${IFACE}" down
reconcile route
check     "vpn down: v4 blackhole default in table ${TID}"   have_route_v4 "^blackhole default"
check     "vpn down: v6 blackhole default in table ${TID}"   have_route_v6 "^blackhole default"
check     "vpn down: v4 ip rule still present (no leak gap)"  have_rule_v4
check_not "vpn down: v4 table has NO fallthrough-to-main gap" have_route_v4 "^default dev (eth|en|wl)"

# ============ 3. VPN recovers (tunnel re-established) ============
mk_iface
reconcile route
check     "vpn recovered: v4 default via ${IFACE} restored"  have_route_v4 "^default dev ${IFACE}"
check     "vpn recovered: v6 default via ${IFACE} restored"  have_route_v6 "^default dev ${IFACE}"

# ============ 4. IPV6_MODE=block ============
mk_iface
reconcile block
check     "mode=block: v6 blackhole even with tunnel up"     have_route_v6 "^blackhole default"
check     "mode=block: v4 still routed via ${IFACE}"         have_route_v4 "^default dev ${IFACE}"

# ============ 5. IPV6_MODE=off ============
ip -6 rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
ip -6 route flush table "${TID}" 2>/dev/null || true
mk_iface
reconcile off
check_not "mode=off: no v6 ip rule added"                    have_rule_v6

# ============ 6. peer-port push only on mismatch ============
mk_iface
echo 12345 > "${WORK}/fake_peerport"
: > "${RPC_LOG}"
reconcile route
check     "peer-port: session-set called when current != FORWARDED_PORT" \
          grep -q "session-set" "${RPC_LOG}"

echo 55555 > "${WORK}/fake_peerport"
: > "${RPC_LOG}"
reconcile route
check_not "peer-port: session-set NOT called when already correct" \
          grep -q "session-set" "${RPC_LOG}"

# ============ 7. resolve_tx_pkg via _common.sh ============
if [ -f "${COMMON}" ]; then
  : > "${SYNOPKG_LOG}"
  # shellcheck disable=SC1090
  pkg=$( . "${COMMON}"; resolve_tx_pkg 2>/dev/null )
  check "resolve_tx_pkg returns 'transmission' (lowercase)" test "${pkg}" = "transmission"
else
  notok "resolve_tx_pkg via _common.sh (missing ${COMMON})"
fi

# ============ 8b. AUTOSTART_TRANSMISSION opt-in ============
if [ -f "${COMMON}" ]; then
  mk_iface
  # full protected state in the test table: v4+v6 default routes AND UID rules
  ip    route replace default dev "${IFACE}" table "${TID}" 2>/dev/null
  ip -6 route replace default dev "${IFACE}" table "${TID}" 2>/dev/null
  ip    rule add uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  ip -6 rule add uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true

  autostart_probe() { # $1=AUTOSTART value, $2=vpn up|down
    [ "$2" = "down" ] && ip link set "${IFACE}" down || ip link set "${IFACE}" up
    echo stop > "${WORK}/tx_status"
    : > "${SYNOPKG_LOG}"
    # shellcheck disable=SC1090
    ( . "${COMMON}"
      export GUARD_CONF="${GUARD}" PATH="${SHIM}:${PATH}"
      # consumed inside _common.sh (load_conf env-wins / start_transmission)
      # shellcheck disable=SC2034
      { VPN_IF="${IFACE}"; RT_TABLE_ID="${TID}"; RT_TABLE_NAME="${TNAME}"; AUTOSTART_TRANSMISSION="$1"; }
      load_conf
      start_transmission )
    grep -q '^start transmission' "${SYNOPKG_LOG}"
  }
  autostart_probe 1 up   && ok    "autostart=1 + VPN up + routes + rules: starts Transmission" \
                         || notok "autostart=1 + VPN up + routes + rules: starts Transmission"
  autostart_probe 1 down && notok "autostart=1 + VPN down: leaves Transmission stopped" \
                         || ok    "autostart=1 + VPN down: leaves Transmission stopped"
  autostart_probe 0 up   && notok "autostart=0: never starts Transmission" \
                         || ok    "autostart=0: never starts Transmission"

  # IPv6 UID rule missing while IPV6_MODE=route -> must NOT start (leak guard)
  ip -6 rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  autostart_probe 1 up   && notok "autostart: missing IPv6 UID rule keeps Transmission stopped" \
                         || ok    "autostart: missing IPv6 UID rule keeps Transmission stopped"

  ip    rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  ip -6 rule del uidrange "${TEST_UID}-${TEST_UID}" lookup "${TID}" 2>/dev/null || true
  ip    route flush table "${TID}" 2>/dev/null || true
  ip -6 route flush table "${TID}" 2>/dev/null || true
  ip link set "${IFACE}" up
fi

# ============ 8. daemon_running rejects stale / foreign PIDs ============
if [ -f "${COMMON}" ]; then
  sleep 300 &
  FOREIGN_PID=$!
  echo "${FOREIGN_PID}" > "${WORK}/foreign.pid"
  echo "99999999" > "${WORK}/dead.pid"
  # shellcheck disable=SC1090
  ( . "${COMMON}"; daemon_running "${WORK}/foreign.pid" ) \
    && notok "daemon_running: rejects a live PID that is not a shield daemon" \
    || ok    "daemon_running: rejects a live PID that is not a shield daemon"
  # shellcheck disable=SC1090
  ( . "${COMMON}"; daemon_running "${WORK}/dead.pid" ) \
    && notok "daemon_running: rejects a non-existent PID" \
    || ok    "daemon_running: rejects a non-existent PID"
  kill "${FOREIGN_PID}" 2>/dev/null || true
fi

echo "# ---------------------------------------------"
echo "# PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
