#!/bin/sh
# _common.sh — shared library for Transmission VPN Shield.
# Sourced by start-stop-status, guard-reconcile and guard-push.
# MUST NOT run anything on source, MUST NOT call exit.
#
# Testability: set GUARD_CONF=<file> to load an alternate guard.conf. Env vars
# already exported for VPN_IF, RT_TABLE_ID, RT_TABLE_NAME, TRANSMISSION_USER,
# IPV6_MODE and FORWARDED_PORT win over whatever the conf file sets.

# Several constants below are the library's API, consumed only by the scripts
# that source this file; shellcheck cannot see that use from here.
# shellcheck disable=SC2034  # (file-wide) API constants used by sourcing scripts
PKG_NAME="transmission-vpn-shield"
: "${PKG_DIR:=/var/packages/${PKG_NAME}}"
VAR_DIR="${PKG_DIR}/var"
CONF_DEFAULT="${PKG_DIR}/target/conf/guard.conf"
CONF_FALLBACK="${PKG_DIR}/etc/guard.conf"
# RPC credentials live in a separate 0600 file so guard.conf can stay
# world-readable for the (non-root) web UI without exposing the password.
SECRET_CONF="${PKG_DIR}/etc/guard.secret"

LOG_FILE="${VAR_DIR}/shield.log"
LOG_MAX_BYTES=524288

PUB_IP_FILE="${VAR_DIR}/public_ip"
PUB_IP_PID="${VAR_DIR}/public_ip.pid"
KUMA_PUSH_PID="${VAR_DIR}/kuma-push.pid"
RECONCILE_PID="${VAR_DIR}/reconcile.pid"
# Serializes a reconcile pass against stop/prestop teardown so an in-flight
# `start-stop-status reconcile` child cannot re-add rules after cleanup.
RECONCILE_LOCK="${VAR_DIR}/reconcile.lock"
# Present only while the package is meant to be running: `start` creates it,
# `stop`/`prestop` remove it. `status` uses it to decide whether resurrecting a
# crashed daemon is appropriate — so a status poll after a clean stop does NOT
# bring the package back up.
RUN_MARKER="${VAR_DIR}/enabled"

KILL_SUPPORT="unknown"

# --------------------------------------------------------------------------
# logging
# --------------------------------------------------------------------------
log() {
  _line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  mkdir -p "${VAR_DIR}" 2>/dev/null || true
  printf '%s\n' "${_line}" >> "${LOG_FILE}" 2>/dev/null || true
  logger -t "${PKG_NAME}" "$*" 2>/dev/null || true
  # also echo to stdout when attached to a terminal (manual runs)
  if [ -t 1 ]; then printf '%s\n' "$*"; fi
}

rotate_log_if_big() {
  [ -f "${LOG_FILE}" ] || return 0
  _sz=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
  [ "${_sz}" -gt "${LOG_MAX_BYTES}" ] 2>/dev/null || return 0
  _half=$((LOG_MAX_BYTES / 2))
  if tail -c "${_half}" "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null; then
    mv "${LOG_FILE}.tmp" "${LOG_FILE}" 2>/dev/null || true
  else
    rm -f "${LOG_FILE}.tmp" 2>/dev/null || true
  fi
}

# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------
load_conf() {
  _env_TRANSMISSION_USER="${TRANSMISSION_USER:-}"
  _env_VPN_IF="${VPN_IF:-}"
  _env_RT_TABLE_ID="${RT_TABLE_ID:-}"
  _env_RT_TABLE_NAME="${RT_TABLE_NAME:-}"
  _env_IPV6_MODE="${IPV6_MODE:-}"
  _env_FORWARDED_PORT="${FORWARDED_PORT:-}"

  # These are runtime config files, not shell libraries — path is intentionally
  # dynamic and there is nothing for shellcheck to follow.
  for _f in "${GUARD_CONF:-}" "${CONF_DEFAULT}" "${CONF_FALLBACK}"; do
    # shellcheck disable=SC1090
    [ -n "${_f}" ] && [ -f "${_f}" ] && { . "${_f}"; break; }
  done
  # optional secret overlay (RPC_USER / RPC_PASS)
  # shellcheck disable=SC1090
  [ -n "${GUARD_SECRET:-}" ] && [ -f "${GUARD_SECRET}" ] && . "${GUARD_SECRET}"
  # shellcheck disable=SC1090
  [ -z "${GUARD_SECRET:-}" ] && [ -f "${SECRET_CONF}" ] && . "${SECRET_CONF}"

  [ -n "${_env_TRANSMISSION_USER}" ] && TRANSMISSION_USER="${_env_TRANSMISSION_USER}"
  [ -n "${_env_VPN_IF}" ]           && VPN_IF="${_env_VPN_IF}"
  [ -n "${_env_RT_TABLE_ID}" ]      && RT_TABLE_ID="${_env_RT_TABLE_ID}"
  [ -n "${_env_RT_TABLE_NAME}" ]    && RT_TABLE_NAME="${_env_RT_TABLE_NAME}"
  [ -n "${_env_IPV6_MODE}" ]        && IPV6_MODE="${_env_IPV6_MODE}"
  [ -n "${_env_FORWARDED_PORT}" ]   && FORWARDED_PORT="${_env_FORWARDED_PORT}"

  : "${TRANSMISSION_USER:=sc-transmission}"
  : "${VPN_IF:=tun0}"
  : "${RT_TABLE_ID:=200}"
  : "${RT_TABLE_NAME:=transmissionvpn}"
  : "${ENFORCE_KILLSWITCH_WHEN_VPN_DOWN:=1}"
  : "${PUBLIC_IP_REFRESH_SEC:=7200}"
  : "${FORWARDED_PORT:=}"
  : "${RECONCILE_INTERVAL_SEC:=30}"
  : "${IPV6_MODE:=route}"
  : "${RPC_PORT:=9091}"
  : "${RPC_USER:=}"
  : "${RPC_PASS:=}"
  : "${KUMA_PUSH_URL:=}"
  : "${KUMA_PUSH_INTERVAL_SEC:=60}"
  : "${PORT_TEST_INTERVAL_SEC:=600}"

  case "${IPV6_MODE}" in route|block|off) ;; *) IPV6_MODE="route" ;; esac
}

# --------------------------------------------------------------------------
# identity resolution
# --------------------------------------------------------------------------
resolve_tx_uid() {
  for _u in "${TRANSMISSION_USER}" sc-transmission transmission debian-transmission; do
    [ -n "${_u}" ] || continue
    _uid=$(id -u "${_u}" 2>/dev/null) || continue
    TRANSMISSION_USER="${_u}"
    echo "${_uid}"
    return 0
  done
  echo ""
}

# Echo the DSM package name Transmission is actually installed as.
resolve_tx_pkg() {
  [ -n "${_TX_PKG:-}" ] && { echo "${_TX_PKG}"; return 0; }
  command -v synopkg >/dev/null 2>&1 || return 1
  for _p in transmission Transmission sc-transmission; do
    if synopkg status "${_p}" 2>/dev/null | grep -q '"status"'; then
      _TX_PKG="${_p}"
      echo "${_p}"
      return 0
    fi
  done
  return 1
}

# --------------------------------------------------------------------------
# VPN interface state
# --------------------------------------------------------------------------
vpn_is_up() {
  command -v ip >/dev/null 2>&1 || return 1
  _l=$(ip link show "${VPN_IF}" 2>/dev/null | head -n1)
  [ -n "${_l}" ] || return 1
  # tun devices report "state UNKNOWN" when up, "state DOWN" when admin-down.
  # Reject DOWN, and require the UP flag in the <...> flag block.
  case "${_l}" in *"state DOWN"*) return 1 ;; esac
  case "${_l}" in *UP*) ;; *) return 1 ;; esac
  ip -4 addr show dev "${VPN_IF}" 2>/dev/null | grep -q "inet "
}

vpn_has_v6() {
  ip -6 addr show dev "${VPN_IF}" scope global 2>/dev/null | grep -q "inet6 "
}

# --------------------------------------------------------------------------
# rt_tables
# --------------------------------------------------------------------------
check_rt_table_present() {
  grep -Eq "^[[:space:]]*${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}\$" /etc/iproute2/rt_tables 2>/dev/null
}
ensure_rt_table_entry() {
  check_rt_table_present && return 0
  echo "${RT_TABLE_ID} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables 2>/dev/null || return 1
}
remove_rt_table_entry() {
  sed -i "/^[[:space:]]*${RT_TABLE_ID}[[:space:]]\+${RT_TABLE_NAME}\$/d" /etc/iproute2/rt_tables 2>/dev/null || true
}

# --------------------------------------------------------------------------
# routes in the dedicated table
# --------------------------------------------------------------------------
route_v4_is_default(){ ip    route show table "${RT_TABLE_ID}" 2>/dev/null | grep -Eq "^default dev ${VPN_IF}( |\$)"; }
route_v4_is_blackhole(){ ip  route show table "${RT_TABLE_ID}" 2>/dev/null | grep -Eq "^blackhole default"; }
route_v6_is_default(){ ip -6 route show table "${RT_TABLE_ID}" 2>/dev/null | grep -Eq "^default dev ${VPN_IF}( |\$)"; }
route_v6_is_blackhole(){ ip -6 route show table "${RT_TABLE_ID}" 2>/dev/null | grep -Eq "^blackhole default"; }

ensure_route_v4() {
  if vpn_is_up; then
    route_v4_is_default && return 0
    ip route replace default dev "${VPN_IF}" table "${RT_TABLE_ID}" 2>/dev/null && echo "v4route=via-${VPN_IF}"
  else
    route_v4_is_blackhole && return 0
    ip route replace blackhole default table "${RT_TABLE_ID}" 2>/dev/null && echo "v4route=blackhole"
  fi
}

ensure_route_v6() {
  case "${IPV6_MODE}" in
    off) return 0 ;;
    block)
      route_v6_is_blackhole && return 0
      ip -6 route replace blackhole default table "${RT_TABLE_ID}" 2>/dev/null && echo "v6route=blackhole"
      ;;
    route|*)
      if vpn_is_up && vpn_has_v6; then
        route_v6_is_default && return 0
        ip -6 route replace default dev "${VPN_IF}" table "${RT_TABLE_ID}" 2>/dev/null && echo "v6route=via-${VPN_IF}"
      else
        route_v6_is_blackhole && return 0
        ip -6 route replace blackhole default table "${RT_TABLE_ID}" 2>/dev/null && echo "v6route=blackhole"
      fi
      ;;
  esac
}

ensure_lan_routes_v4() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -4 route show table main scope link 2>/dev/null | grep -Ev " dev (${VPN_IF}|lo)( |\$)" | while read -r _line; do
    [ -n "${_line}" ] || continue
    # shellcheck disable=SC2086
    ip route replace ${_line} table "${RT_TABLE_ID}" 2>/dev/null || true
  done
}

ensure_lan_routes_v6() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 route show table main scope link 2>/dev/null | grep -Ev " dev (${VPN_IF}|lo)( |\$)" | while read -r _line; do
    [ -n "${_line}" ] || continue
    case "${_line}" in fe80:*) continue ;; esac
    # shellcheck disable=SC2086
    ip -6 route replace ${_line} table "${RT_TABLE_ID}" 2>/dev/null || true
  done
}

flush_routes_v4(){ ip    route flush table "${RT_TABLE_ID}" 2>/dev/null || true; }
flush_routes_v6(){ ip -6 route flush table "${RT_TABLE_ID}" 2>/dev/null || true; }

# --------------------------------------------------------------------------
# ip rules (policy routing by UID)
# --------------------------------------------------------------------------
check_ip_rule_v4(){ ip    rule show 2>/dev/null | grep -Eq "uidrange ${1}-${1} .*lookup (${RT_TABLE_NAME}|${RT_TABLE_ID})"; }
check_ip_rule_v6(){ ip -6 rule show 2>/dev/null | grep -Eq "uidrange ${1}-${1} .*lookup (${RT_TABLE_NAME}|${RT_TABLE_ID})"; }

ensure_ip_rule_v4() {
  check_ip_rule_v4 "$1" && return 0
  ip rule add uidrange "${1}-${1}" lookup "${RT_TABLE_ID}" 2>/dev/null && echo "v4rule=+${1}"
}
ensure_ip_rule_v6() {
  check_ip_rule_v6 "$1" && return 0
  ip -6 rule add uidrange "${1}-${1}" lookup "${RT_TABLE_ID}" 2>/dev/null && echo "v6rule=+${1}"
}
del_ip_rule_v4() { while check_ip_rule_v4 "$1"; do ip    rule del uidrange "${1}-${1}" lookup "${RT_TABLE_ID}" 2>/dev/null || break; done; }
del_ip_rule_v6() { while check_ip_rule_v6 "$1"; do ip -6 rule del uidrange "${1}-${1}" lookup "${RT_TABLE_ID}" 2>/dev/null || break; done; }

# --------------------------------------------------------------------------
# kill switch (iptables owner match) — best effort
# --------------------------------------------------------------------------
owner_supported() {
  [ "${KILL_SUPPORT}" = "yes" ] && return 0
  [ "${KILL_SUPPORT}" = "no" ] && return 1
  command -v iptables >/dev/null 2>&1 || { KILL_SUPPORT="no"; return 1; }
  if iptables -m owner -h >/dev/null 2>&1; then KILL_SUPPORT="yes"; return 0; fi
  KILL_SUPPORT="no"
  return 1
}
check_killswitch_present() {
  owner_supported || return 2
  iptables -S OUTPUT 2>/dev/null | grep -Fq -- "-m owner --uid-owner ${1} ! -o ${VPN_IF} -j DROP"
}
_killswitch_lo_present() {
  iptables -S OUTPUT 2>/dev/null | grep -Fq -- "-m owner --uid-owner ${1} -o lo -j RETURN"
}
ensure_killswitch() {
  owner_supported || return 0
  check_killswitch_present "$1" && _killswitch_lo_present "$1" && return 0
  # Exempt loopback first, otherwise the DROP also kills Transmission's replies
  # to the shield's own RPC calls on 127.0.0.1 (peer-port push, port-test).
  _killswitch_lo_present "$1" || \
    iptables -I OUTPUT -m owner --uid-owner "$1" -o lo -j RETURN 2>/dev/null
  check_killswitch_present "$1" || \
    iptables -A OUTPUT -m owner --uid-owner "$1" ! -o "${VPN_IF}" -j DROP 2>/dev/null
  echo "ks=+${1}"
}
del_killswitch() {
  owner_supported || return 0
  while check_killswitch_present "$1"; do
    iptables -D OUTPUT -m owner --uid-owner "$1" ! -o "${VPN_IF}" -j DROP 2>/dev/null || break
  done
  while _killswitch_lo_present "$1"; do
    iptables -D OUTPUT -m owner --uid-owner "$1" -o lo -j RETURN 2>/dev/null || break
  done
}

# --------------------------------------------------------------------------
# Transmission RPC
# --------------------------------------------------------------------------
# rpc_call METHOD [ARGS_JSON] -> prints the RPC response body, or returns 1.
rpc_call() {
  _m="$1"; _a="${2:-}"
  command -v curl >/dev/null 2>&1 || return 1
  _base="http://127.0.0.1:${RPC_PORT:-9091}/transmission/rpc"
  set -- -s --max-time 10
  [ -n "${RPC_USER}" ] && set -- "$@" -u "${RPC_USER}:${RPC_PASS}"
  _sid=$(curl "$@" "${_base}" 2>/dev/null | grep -o 'X-Transmission-Session-Id: [^<"]*' | awk '{print $2}' | tr -d '\r')
  [ -n "${_sid}" ] || return 1
  _body="{\"method\":\"${_m}\""
  [ -n "${_a}" ] && _body="${_body},\"arguments\":${_a}"
  _body="${_body}}"
  curl "$@" -H "X-Transmission-Session-Id: ${_sid}" -d "${_body}" "${_base}" 2>/dev/null
}

# Push FORWARDED_PORT to Transmission, but only when it differs from the
# current peer-port. Echoes a change token on a real change.
apply_forwarded_port() {
  [ -n "${FORWARDED_PORT}" ] || return 0
  command -v curl >/dev/null 2>&1 || { log "WARN: curl missing; cannot set peer-port"; return 0; }
  _cur=$(rpc_call session-get '' | grep -o '"peer-port":[0-9]*' | head -n1 | cut -d: -f2)
  case "${_cur}" in ''|*[!0-9]*) _cur="" ;; esac
  [ -n "${_cur}" ] && [ "${_cur}" = "${FORWARDED_PORT}" ] && return 0
  if rpc_call session-set "{\"peer-port\":${FORWARDED_PORT}}" >/dev/null 2>&1; then
    echo "port=${_cur:-?}->${FORWARDED_PORT}"
  else
    log "WARN: failed to set Transmission peer-port via RPC (auth? set RPC_USER/RPC_PASS in guard.conf)"
  fi
}

# --------------------------------------------------------------------------
# generic daemon supervision
# --------------------------------------------------------------------------
daemon_running() {
  _pf="$1"
  [ -f "${_pf}" ] || return 1
  _pid=$(cat "${_pf}" 2>/dev/null)
  case "${_pid}" in ''|*[!0-9]*) return 1 ;; esac
  # /proc, not `kill -0`: works for a non-root caller (read-only) and lets us
  # verify identity so a recycled PID is not mistaken for a live daemon.
  [ -d "/proc/${_pid}" ] || return 1
  tr '\0' ' ' < "/proc/${_pid}/cmdline" 2>/dev/null \
    | grep -q 'guard-reconcile\|guard-push\|transmission-vpn-shield' || return 1
  return 0
}
stop_daemon() {
  _pf="$1"
  # Only signal the PID if it is still one of our daemons — a stale pid file
  # whose PID has been recycled must not get a root SIGTERM.
  if daemon_running "${_pf}"; then
    _pid=$(cat "${_pf}" 2>/dev/null)
    kill "${_pid}" 2>/dev/null || true
  fi
  rm -f "${_pf}" 2>/dev/null || true
}

# run_locked <cmd...> — serialize against a concurrent reconcile pass.
run_locked() {
  mkdir -p "${VAR_DIR}" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1 && ( : 9>"${RECONCILE_LOCK}" ) 2>/dev/null; then
    ( flock -w 60 9 2>/dev/null || true; "$@" ) 9>"${RECONCILE_LOCK}"
  else
    "$@"
  fi
}
