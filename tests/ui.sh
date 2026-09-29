#!/bin/sh
# tests/ui.sh — smoke tests for the web UI (src/ui/index.cgi)
#
# Renders the page against a throwaway PKG_DIR with hand-written state files
# and checks the alerts a user relies on. Linux only (reads /proc), no root.
#
# Usage:  sh tests/ui.sh

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "${HERE}/.." && pwd)
CGI="${REPO}/src/ui/index.cgi"
WORK=$(mktemp -d "${HERE}/tvpu-work.XXXXXX" 2>/dev/null || mktemp -d)
P="${WORK}/pkg"
SHIM="${WORK}/bin"
RECON_PID=""
trap '[ -n "${RECON_PID}" ] && kill "${RECON_PID}" 2>/dev/null; rm -rf "${WORK}"' EXIT INT TERM

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
notok(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
has()   { if grep -qF -- "$2" "${WORK}/page"; then ok "$1"; else notok "$1"; fi; }
hasnt() { if grep -qF -- "$2" "${WORK}/page"; then notok "$1"; else ok "$1"; fi; }

mkdir -p "${P}/target/conf" "${P}/var" "${SHIM}"
# synopkg: Transmission's state comes from a file; no file = synopkg can't tell
cat > "${SHIM}/synopkg" <<EOF
#!/bin/sh
[ -f "${WORK}/tx_state" ] || exit 1
[ "\$1 \$2" = "status transmission" ] || exit 1
echo "{\"package\":\"transmission\",\"status\":\"\$(cat "${WORK}/tx_state")\"}"
EOF
printf '#!/bin/sh\nexit 7\n' > "${SHIM}/curl"
# pidof: the transmission-daemon PID comes from a file (none = not running)
cat > "${SHIM}/pidof" <<EOF
#!/bin/sh
cat "${WORK}/tx_pid" 2>/dev/null
EOF
chmod +x "${SHIM}"/*
PATH="${SHIM}:${PATH}"
export PATH

# the UI checks the reconcile daemon's cmdline, so give it a real one
printf '#!/bin/sh\ntrap "kill \\$! 2>/dev/null; exit 0" TERM\nsleep 600 & wait\n' > "${WORK}/guard-reconcile"
chmod +x "${WORK}/guard-reconcile"
"${WORK}/guard-reconcile" >/dev/null 2>&1 &
RECON_PID=$!
echo "${RECON_PID}" > "${P}/var/reconcile.pid"

conf() { # conf <extra lines>
  cat > "${P}/target/conf/guard.conf" <<EOF
VPN_IF="tvpu0"
FORWARDED_PORT="55555"
PORT_TEST_INTERVAL_SEC="600"
$1
EOF
}
state() { # state <rpc ok|fail> <port-test open|closed> [age-seconds]
  now=$(date +%s); ts=$((now - ${3:-10}))
  echo "$1 ${now} 55555" > "${P}/var/rpc_port_status"
  echo "${ts} $2 55555" > "${P}/var/port-test.cache"
}
render() { PKG_DIR="${P}" QUERY_STRING="${1:-}" sh "${CGI}" > "${WORK}/page" 2>/dev/null; }

echo "# web UI smoke tests"

conf 'DSM_VPN_NAME="TestVPN"'
state ok closed
render
has   "page: CGI header first"                          "Content-type: text/html"
has   "closed port: alert shown"                        "tests closed from the internet"
has   "closed port + DSM profile: auto-recover explained" "reconnects DSM VPN profile <code>TestVPN</code> automatically"

conf 'DSM_VPN_NAME="TestVPN"
AUTO_RECOVER_VPN="0"'
render
has   "closed port + AUTO_RECOVER_VPN=0: manual run suggested" "Automatic reconnect is off"

conf ''
render
has   "closed port, no DSM profile: points at DSM_VPN_NAME" "Set <code>DSM_VPN_NAME</code>"

conf 'DSM_VPN_NAME="TestVPN"'
state ok open
render
hasnt "open port: no closed-port alert"                 "tests closed from the internet"

state ok closed 99999
render
hasnt "stale closed verdict: not shown as closed"       "tests closed from the internet"

state fail closed
render
has   "RPC push failing, Transmission state unknown: credentials alert" "RPC push failing for port 55555"

echo running > "${WORK}/tx_state"
render
has   "RPC push failing, Transmission running: credentials alert" "RPC push failing for port 55555"

# As non-root, synopkg says "stop" for a running Transmission: the daemon's
# PID must win.
echo stop > "${WORK}/tx_state"; echo 4242 > "${WORK}/tx_pid"
render
has   "non-root synopkg says stop but the daemon runs: credentials alert" "RPC push failing for port 55555"
hasnt "non-root synopkg says stop but the daemon runs: not called stopped" "Transmission is stopped"
rm -f "${WORK}/tx_pid"

echo stop > "${WORK}/tx_state"
render
has   "Transmission stopped: says so instead"           "Transmission is stopped"
hasnt "Transmission stopped: no credentials alert"      "RPC push failing"
has   "Transmission stopped: port chip waits for it"    "Port 55555 waiting for Transmission"
has   "Transmission stopped, autostart off: suggests it" 'AUTOSTART_TRANSMISSION="1"'
conf 'DSM_VPN_NAME="TestVPN"
AUTOSTART_TRANSMISSION="1"'
render
hasnt "Transmission stopped, autostart on: no autostart hint" 'AUTOSTART_TRANSMISSION="1"'
rm -f "${WORK}/tx_state"

render "mode=check-activation"
has   "check-activation: active without the flag"       "active"
touch "${P}/var/needs-activation"
render "mode=check-activation"
has   "check-activation: needs-activation with the flag" "needs-activation"

echo "# ---------------------------------------------"
echo "# PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
