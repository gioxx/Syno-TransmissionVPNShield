#!/bin/sh
# tests/recover-vpn.sh — integration tests for synology/scripts/recover-vpn
#
# Requires: root, Linux, iproute2. A veth pair (tvpr0) stands in for the VPN
# interface; a synowebapi shim takes it down/up on disconnect/connect, so the
# script's real wait loops run against real link state. Table 198 only.
#
# Usage:  sudo sh tests/recover-vpn.sh
#
# Slow on purpose in two cases (tunnel that never goes down: ~30s).

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "${HERE}/.." && pwd)
RV="${REPO}/synology/scripts/recover-vpn"

IFACE="tvpr0"
IFACE_PEER="tvpr0p"
TID="198"
TNAME="tvprtest"
WORK=$(mktemp -d "${HERE}/tvpr-work.XXXXXX" 2>/dev/null || mktemp -d)
SHIM="${WORK}/bin"
PKG_DIR="${WORK}/pkg"
V="${PKG_DIR}/var"
GUARD="${WORK}/guard.conf"
SYNOPKG_LOG="${WORK}/synopkg.log"
WEBAPI_LOG="${WORK}/webapi.log"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
notok(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
check(){ desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else notok "${desc}"; fi; }
check_not(){ desc=$1; shift; if "$@" >/dev/null 2>&1; then notok "${desc}"; else ok "${desc}"; fi; }

RECON_PID=""
FOREIGN_PID=""
cleanup(){
  [ -n "${RECON_PID}" ] && kill "${RECON_PID}" 2>/dev/null
  [ -n "${FOREIGN_PID}" ] && kill "${FOREIGN_PID}" 2>/dev/null
  while ip    rule del uidrange "$(id -u)-$(id -u)" lookup "${TID}" 2>/dev/null; do :; done
  while ip -6 rule del uidrange "$(id -u)-$(id -u)" lookup "${TID}" 2>/dev/null; do :; done
  ip    route flush table "${TID}" 2>/dev/null || true
  ip -6 route flush table "${TID}" 2>/dev/null || true
  ip link del "${IFACE}" 2>/dev/null || true
  sed -i "/^[[:space:]]*${TID}[[:space:]]\+${TNAME}\$/d" /etc/iproute2/rt_tables 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 2; }
command -v ip >/dev/null 2>&1 || { echo "iproute2 'ip' not found"; exit 2; }

mkdir -p "${SHIM}" "${V}" "${PKG_DIR}/scripts"

# --- shims -------------------------------------------------------------------
# synopkg: tracks Transmission's state in a file; "stopfail" makes stop a no-op.
echo running > "${WORK}/tx_status"
cat > "${SHIM}/synopkg" <<EOF
#!/bin/sh
echo "\$@" >> "${SYNOPKG_LOG}"
case "\$1 \$2" in
  "status transmission") echo "{\"package\":\"transmission\",\"status\":\"\$(cat "${WORK}/tx_status")\"}"; exit 0 ;;
  "status "*)            exit 1 ;;
  "stop transmission")   [ -f "${V}/enabled" ] && m=yes || m=no; echo "stop marker=\$m" >> "${WORK}/stops"
                         [ -f "${WORK}/stopfail" ] || echo stop > "${WORK}/tx_status"; exit 0 ;;
  "start transmission")  echo running > "${WORK}/tx_status"; exit 0 ;;
  *)                     exit 0 ;;
esac
EOF

# synowebapi: one profile "TestVPN" (id t1). Behaviour per call is driven by
# files: down_after=N  -> the Nth disconnect call actually drops the link
#        (0 = never); connect_fail -> connect reports failure;
#        disconnect_fail -> disconnect reports failure.
cat > "${SHIM}/synowebapi" <<EOF
#!/bin/sh
echo "\$*" >> "${WEBAPI_LOG}"
case "\$*" in
  *"method=list"*)
    case "\$*" in *OpenVPNWithConf*) ;; *) echo '{ "data" : [] }'; exit 0 ;; esac
    printf '{\n   "confname" : "Other",\n   "id" : "o9"\n}\n{\n   "confname" : "TestVPN",\n   "id" : "t1"\n}\n'
    ;;
  *"method=disconnect"*)
    [ -f "${WORK}/disconnect_fail" ] && { echo '"success" : false'; exit 0; }
    n=\$(( \$(cat "${WORK}/disc_calls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "${WORK}/disc_calls"
    [ "\$n" -eq "\$(cat "${WORK}/down_after" 2>/dev/null || echo 1)" ] && ip link set "${IFACE}" down
    echo '"success" : true'
    ;;
  *"method=connect"*)
    [ -f "${WORK}/connect_fail" ] && { echo '"success" : false'; exit 0; }
    ip link set "${IFACE}" up
    echo '"success" : true'
    ;;
esac
exit 0
EOF

cat > "${SHIM}/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *"X-Transmission-Session-Id"*"session-get"*) echo '{"arguments":{"peer-port":55555},"result":"success"}' ;;
  *"X-Transmission-Session-Id"*"port-test"*)   echo '{"arguments":{"port-is-open":true},"result":"success"}' ;;
  *"X-Transmission-Session-Id"*)               echo '{"result":"success"}' ;;
  *) printf 'X-Transmission-Session-Id: deadbeef\n' ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "${SHIM}/logger"
printf '#!/bin/sh\nexit 0\n' > "${SHIM}/pidof"
chmod +x "${SHIM}"/*
PATH="${SHIM}:${PATH}"
export PATH PKG_DIR
export SYNOWEBAPI="${SHIM}/synowebapi"

cat > "${GUARD}" <<EOF
TRANSMISSION_USER="$(id -un)"
VPN_IF="${IFACE}"
RT_TABLE_ID="${TID}"
RT_TABLE_NAME="${TNAME}"
ENFORCE_KILLSWITCH_WHEN_VPN_DOWN="0"
PUBLIC_IP_REFRESH_SEC="0"
FORWARDED_PORT="55555"
IPV6_MODE="off"
KUMA_PUSH_URL=""
DSM_VPN_NAME="TestVPN"
EOF
export GUARD_CONF="${GUARD}"

mk_iface(){
  ip link del "${IFACE}" 2>/dev/null || true
  ip link add "${IFACE}" type veth peer name "${IFACE_PEER}"
  ip link set "${IFACE_PEER}" up
  ip link set "${IFACE}" up
  ip addr add 10.9.8.2/24 dev "${IFACE}"
  _i=0
  while ip link show "${IFACE}" | head -n1 | grep -q "state DOWN" && [ "${_i}" -lt 30 ]; do _i=$((_i+1)); sleep 0.1; done
}

# A live process whose cmdline says guard-reconcile: recover-vpn only restarts
# Transmission when the shield's reconcile daemon is running.
printf '#!/bin/sh\ntrap "kill \\$! 2>/dev/null; exit 0" TERM\nsleep 600 & wait\n' > "${WORK}/guard-reconcile"
chmod +x "${WORK}/guard-reconcile"
"${WORK}/guard-reconcile" >/dev/null 2>&1 &
RECON_PID=$!

# reset <extra setup...>: fresh state for one scenario
reset(){
  mk_iface
  rm -rf "${V:?}"/* "${V}/recover-vpn.lock"
  rm -f "${WORK}/stopfail" "${WORK}/connect_fail" "${WORK}/disconnect_fail" "${WORK}/disc_calls"
  echo 1 > "${WORK}/down_after"
  echo running > "${WORK}/tx_status"
  : > "${SYNOPKG_LOG}"; : > "${WEBAPI_LOG}"
  : > "${V}/enabled"
  echo "${RECON_PID}" > "${V}/reconcile.pid"
}
run_rv(){ sh "${RV}" "$@" >"${WORK}/out" 2>&1; RC=$?; }
called(){ grep -q "$1" "$2"; }
webapi_count(){ grep -c "method=$1" "${WEBAPI_LOG}"; }

echo "# recover-vpn integration tests (iface=${IFACE} table=${TID})"

# ============ 1. happy path ============
reset
echo "$(date +%s) closed 55555" > "${V}/port-test.cache"
echo 2 > "${V}/port-closed.count"
run_rv
check     "happy: exits 0"                                  test "${RC}" -eq 0
check     "happy: looks up the profile id by name"          called "id=t1" "${WEBAPI_LOG}"
check     "happy: disconnect before connect"                sh -c "grep -n 'method=disconnect' '${WEBAPI_LOG}' | head -n1 | cut -d: -f1 | xargs -I{} sh -c 'test {} -lt \$(grep -n method=connect \"${WEBAPI_LOG}\" | head -n1 | cut -d: -f1)'"
check     "happy: Transmission stopped then started"        sh -c "grep -q '^stop transmission' '${SYNOPKG_LOG}' && grep -q '^start transmission' '${SYNOPKG_LOG}'"
check     "happy: Transmission running at the end"          grep -q running "${WORK}/tx_status"
check_not "happy: held marker cleared"                      test -f "${V}/tx-held-by-recover"
check_not "happy: lock released"                            test -d "${V}/recover-vpn.lock"
check_not "happy: stale port-test cache dropped"            test -f "${V}/port-test.cache"
check_not "happy: closed streak reset"                      test -f "${V}/port-closed.count"
check     "happy: steps logged to shield.log"               grep -q "recover-vpn: Recovery sequence complete" "${V}/shield.log"

# ============ 2. first disconnect doesn't drop the tunnel ============
reset
echo 2 > "${WORK}/down_after"
run_rv
check "retry: disconnect re-issued once"                    test "$(webapi_count disconnect)" -eq 2
check "retry: recovery completes"                           test "${RC}" -eq 0

# ============ 3. tunnel never goes down ============
reset
echo 0 > "${WORK}/down_after"
run_rv
check     "stuck: exits non-zero"                           test "${RC}" -ne 0
check_not "stuck: never calls connect"                      called "method=connect" "${WEBAPI_LOG}"
check     "stuck: Transmission left held (marker)"          test -f "${V}/tx-held-by-recover"
check_not "stuck: Transmission not started"                 called "^start" "${SYNOPKG_LOG}"
check_not "stuck: lock released on error exit"              test -d "${V}/recover-vpn.lock"

# ============ 4. synopkg stop doesn't stop Transmission ============
reset
touch "${WORK}/stopfail"
run_rv
check     "stopfail: exits non-zero"                        test "${RC}" -ne 0
check_not "stopfail: VPN never touched"                     called "method=disconnect" "${WEBAPI_LOG}"
check_not "stopfail: no held marker"                        test -f "${V}/tx-held-by-recover"

# ============ 5. connect fails ============
reset
touch "${WORK}/connect_fail"
run_rv
check     "connectfail: exits non-zero"                     test "${RC}" -ne 0
check     "connectfail: Transmission left held"             test -f "${V}/tx-held-by-recover"

# ============ 6. tunnel already down, disconnect refused ============
reset
ip link set "${IFACE}" down
touch "${WORK}/disconnect_fail"
run_rv
check "alreadydown: connects anyway"                        called "method=connect" "${WEBAPI_LOG}"
check "alreadydown: recovery completes"                     test "${RC}" -eq 0

# ============ 7. another run in progress ============
reset
printf '#!/bin/sh\ntrap "kill \\$! 2>/dev/null; exit 0" TERM\nsleep 300 & wait\n' > "${WORK}/recover-vpn-busy"; chmod +x "${WORK}/recover-vpn-busy"
"${WORK}/recover-vpn-busy" >/dev/null 2>&1 &
FOREIGN_PID=$!
mkdir -p "${V}/recover-vpn.lock"; echo "${FOREIGN_PID}" > "${V}/recover-vpn.lock/pid"
run_rv
check     "lock: second run exits 0"                        test "${RC}" -eq 0
check_not "lock: second run does nothing"                   called "stop" "${SYNOPKG_LOG}"
check     "lock: first run's lock left alone"               test -d "${V}/recover-vpn.lock"
kill "${FOREIGN_PID}" 2>/dev/null; FOREIGN_PID=""

# ============ 8. stale lock from a dead run ============
reset
mkdir -p "${V}/recover-vpn.lock"; echo 99999999 > "${V}/recover-vpn.lock/pid"
run_rv
check "stalelock: taken over, recovery completes"           test "${RC}" -eq 0

# ============ 8b. lock PID recycled by an unrelated process ============
reset
sleep 300 >/dev/null 2>&1 &
FOREIGN_PID=$!
mkdir -p "${V}/recover-vpn.lock"; echo "${FOREIGN_PID}" > "${V}/recover-vpn.lock/pid"
run_rv
check "recycled lock PID: taken over, recovery completes"   test "${RC}" -eq 0
kill "${FOREIGN_PID}" 2>/dev/null; FOREIGN_PID=""

# ============ 9. reconcile daemon not running ============
reset
rm -f "${V}/reconcile.pid"
run_rv
check     "noshield: exits non-zero"                        test "${RC}" -ne 0
check_not "noshield: Transmission not started"              called "^start" "${SYNOPKG_LOG}"
check     "noshield: Transmission left held"                test -f "${V}/tx-held-by-recover"

# ============ 9b. shield stopped (run marker gone) ============
reset
rm -f "${V}/enabled"
run_rv
check     "stopped shield: exits non-zero"                  test "${RC}" -ne 0
check_not "stopped shield: Transmission not started"        called "^start" "${SYNOPKG_LOG}"

# ============ 9c. package stop clears the run marker before stopping Transmission ============
reset
rm -f "${WORK}/stops"
sh "${REPO}/synology/scripts/start-stop-status" stop >/dev/null 2>&1
check "stop: run marker already gone when Transmission is stopped" grep -q "stop marker=no" "${WORK}/stops"
check "stop: held marker cleared"                           test ! -f "${V}/tx-held-by-recover"
# stop killed the stand-in reconcile daemon; later scenarios need it back
"${WORK}/guard-reconcile" >/dev/null 2>&1 &
RECON_PID=$!

# ============ 10. no profile name ============
reset
sed -i 's/^DSM_VPN_NAME=.*/DSM_VPN_NAME=""/' "${GUARD}"
run_rv
check     "noname: exits non-zero"                          test "${RC}" -ne 0
check_not "noname: nothing stopped"                         called "stop" "${SYNOPKG_LOG}"
run_rv TestVPN
check     "noname: profile passed as argument works"        test "${RC}" -eq 0
sed -i 's/^DSM_VPN_NAME=.*/DSM_VPN_NAME="TestVPN"/' "${GUARD}"

# ============ 11. unknown profile ============
reset
run_rv NoSuchVPN
check     "unknown profile: exits non-zero"                 test "${RC}" -ne 0
check_not "unknown profile: nothing stopped"                called "stop" "${SYNOPKG_LOG}"

echo "# ---------------------------------------------"
echo "# PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
