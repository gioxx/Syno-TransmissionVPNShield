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
# Last RPC port-push outcome, so the web UI can surface a stuck failure
# (e.g. RPC_USER/RPC_PASS wrong or missing) instead of silently reporting OK.
RPC_STATUS_FILE="${VAR_DIR}/rpc_port_status"

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
# Cached Transmission port-test result (open/closed/unknown), refreshed by
# reconcile every PORT_TEST_INTERVAL_SEC regardless of whether Kuma push
# monitoring is configured, so the web UI can show real port reachability
# even without Kuma — not just whether the RPC push itself succeeded.
PORT_TEST_CACHE="${VAR_DIR}/port-test.cache"
# Consecutive fresh port-tests that came back "closed" (reset on "open").
PORT_CLOSED_COUNT="${VAR_DIR}/port-closed.count"
# While the port tests closed, re-test every PORT_TEST_RETRY_SEC instead of
# PORT_TEST_INTERVAL_SEC until AUTO_RECOVER_AFTER closed results are in, so a
# real outage is confirmed in minutes rather than half an hour.
PORT_TEST_RETRY_SEC=120
AUTO_RECOVER_AFTER=3
AUTO_RECOVER_WINDOW_SEC=21600
# Retry delay when a recovery left the profile disconnected: much shorter
# than the cooldown, since torrents are down for as long as this lasts.
AUTO_RECOVER_DOWN_RETRY_SEC=300
# One epoch timestamp per automatic recover-vpn launch (pruned to the window).
AUTO_RECOVER_ATTEMPTS="${VAR_DIR}/auto-recover.attempts"
AUTO_RECOVER_GAVEUP="${VAR_DIR}/auto-recover.gaveup"
AUTO_RECOVER_DOWN_LAST="${VAR_DIR}/auto-recover.down-last"
RECOVER_VPN_SCRIPT="${PKG_DIR}/scripts/recover-vpn"
RECOVER_VPN_LOCK="${VAR_DIR}/recover-vpn.lock"
# Written by recover-vpn when it stops Transmission; while present, reconcile
# restarts Transmission as soon as the tunnel and routing are back, so a
# recovery that bails out halfway never leaves torrents down indefinitely.
TX_HELD_MARKER="${VAR_DIR}/tx-held-by-recover"
# PID of the transmission-daemon instance last seen by reconcile.
TX_PID_SEEN="${VAR_DIR}/transmission.pid-seen"
RPC_FAIL_COUNT="${VAR_DIR}/rpc-fail.count"
RPC_FAIL_LOG_AFTER=3

# DSM keeps synopkg & co. in /usr/syno/bin, which non-login contexts (ssh
# one-liners, some Task Scheduler runs) leave out of PATH. Appended, so a
# PATH-prefixed shim (tests) still wins.
case ":${PATH}:" in
  *:/usr/syno/bin:*) ;;
  *) PATH="${PATH}:/usr/syno/bin:/usr/syno/sbin"; export PATH ;;
esac

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
  # optional secret overlay (RPC_USER / RPC_PASS) — 0600, so only source it
  # when the current user can actually read it (root / the package user);
  # non-root callers (the web UI) simply run without RPC credentials.
  # shellcheck disable=SC1090
  [ -n "${GUARD_SECRET:-}" ] && [ -r "${GUARD_SECRET}" ] && . "${GUARD_SECRET}"
  # shellcheck disable=SC1090
  [ -z "${GUARD_SECRET:-}" ] && [ -r "${SECRET_CONF}" ] && . "${SECRET_CONF}"

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
  : "${AUTOSTART_TRANSMISSION:=0}"
  : "${RPC_PORT:=9091}"
  : "${RPC_USER:=}"
  : "${RPC_PASS:=}"
  : "${KUMA_PUSH_URL:=}"
  : "${KUMA_PUSH_INTERVAL_SEC:=60}"
  : "${PORT_TEST_INTERVAL_SEC:=600}"
  : "${DSM_VPN_NAME:=}"
  : "${DSM_VPN_PROTOCOL:=openvpn}"
  : "${AUTO_RECOVER_VPN:=1}"
  : "${AUTO_RECOVER_COOLDOWN_SEC:=1800}"
  : "${AUTO_RECOVER_MAX_PER_6H:=3}"
  [ "${AUTO_RECOVER_COOLDOWN_SEC}" -ge 0 ] 2>/dev/null || AUTO_RECOVER_COOLDOWN_SEC=1800
  [ "${AUTO_RECOVER_MAX_PER_6H}" -ge 0 ] 2>/dev/null || AUTO_RECOVER_MAX_PER_6H=3

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
  # Transmission's own 409 error body echoes "X-Transmission-Session-Id: <sid>"
  # inside a <code> tag as a usage hint, so the pattern below matches it a
  # second time after the real header - head -n1 keeps only the header match.
  _sid=$(curl "$@" -i "${_base}" 2>/dev/null | grep -o 'X-Transmission-Session-Id: [^<"]*' | head -n1 | awk '{print $2}' | tr -d '\r')
  [ -n "${_sid}" ] || return 1
  _body="{\"method\":\"${_m}\""
  [ -n "${_a}" ] && _body="${_body},\"arguments\":${_a}"
  _body="${_body}}"
  curl "$@" -f -H "X-Transmission-Session-Id: ${_sid}" -d "${_body}" "${_base}" 2>/dev/null
}

# Push FORWARDED_PORT to Transmission, but only when it differs from the
# current peer-port. Echoes a change token on a real change.
apply_forwarded_port() {
  [ -n "${FORWARDED_PORT}" ] || return 0
  command -v curl >/dev/null 2>&1 || { log "WARN: curl missing; cannot set peer-port"; return 0; }
  _cur=$(rpc_call session-get '' | grep -o '"peer-port":[0-9]*' | head -n1 | cut -d: -f2)
  case "${_cur}" in ''|*[!0-9]*) _cur="" ;; esac
  if [ -n "${_cur}" ] && [ "${_cur}" = "${FORWARDED_PORT}" ]; then
    _rpc_push_ok
    return 0
  fi
  if _resp=$(rpc_call session-set "{\"peer-port\":${FORWARDED_PORT}}" 2>/dev/null) \
     && printf '%s' "${_resp}" | grep -q '"result":"success"'; then
    _rpc_push_ok
    echo "port=${_cur:-?}->${FORWARDED_PORT}"
  else
    echo "fail $(date +%s) ${FORWARDED_PORT}" > "${RPC_STATUS_FILE}" 2>/dev/null || true
    # A single failure is normal while Transmission is (re)starting; only a
    # streak is worth a log line, and only once per streak.
    _n=$(( $(_read_int "${RPC_FAIL_COUNT}") + 1 ))
    echo "${_n}" > "${RPC_FAIL_COUNT}" 2>/dev/null || true
    [ "${_n}" -eq "${RPC_FAIL_LOG_AFTER}" ] && \
      log "WARN: failed to set Transmission peer-port via RPC ${_n} times in a row (Transmission stopped, or RPC_USER/RPC_PASS in guard.secret wrong?)"
  fi
}

_rpc_push_ok() {
  echo "ok $(date +%s) ${FORWARDED_PORT}" > "${RPC_STATUS_FILE}" 2>/dev/null || true
  [ "$(_read_int "${RPC_FAIL_COUNT}")" -ge "${RPC_FAIL_LOG_AFTER}" ] && \
    log "peer-port push via RPC working again"
  rm -f "${RPC_FAIL_COUNT}" 2>/dev/null || true
}

# _read_int FILE -> the non-negative integer stored in FILE, or 0.
_read_int() {
  _ri=$(cat "$1" 2>/dev/null)
  case "${_ri}" in ''|*[!0-9]*) echo 0 ;; *) echo "${_ri}" ;; esac
}

# Cached Transmission port-test (open/closed/unknown/skip), refreshed at
# most once per PORT_TEST_INTERVAL_SEC. Called from reconcile (so it runs
# regardless of Kuma) and from guard-push (which reuses the same cache
# instead of testing again), so a real curl only actually happens on
# whichever of the two hits a stale cache first.
port_test() {
  [ -n "${FORWARDED_PORT}" ] || { echo skip; return; }
  [ "${PORT_TEST_INTERVAL_SEC}" -gt 0 ] 2>/dev/null || { echo skip; return; }
  command -v curl >/dev/null 2>&1 || { echo skip; return; }

  _now=$(date +%s)
  if [ -f "${PORT_TEST_CACHE}" ]; then
    _cached_ts=$(awk 'NR==1{print $1}' "${PORT_TEST_CACHE}" 2>/dev/null)
    _cached_val=$(awk 'NR==1{print $2}' "${PORT_TEST_CACHE}" 2>/dev/null)
    _cached_port=$(awk 'NR==1{print $3}' "${PORT_TEST_CACHE}" 2>/dev/null)
    # A cache entry for a different port (set-port ran since it was written)
    # says nothing about the current FORWARDED_PORT - force a fresh test.
    _iv="${PORT_TEST_INTERVAL_SEC}"
    if [ "${_cached_val}" = "closed" ] && [ "${PORT_TEST_RETRY_SEC}" -lt "${_iv}" ] \
       && [ "$(_read_int "${PORT_CLOSED_COUNT}")" -lt "${AUTO_RECOVER_AFTER}" ]; then
      _iv="${PORT_TEST_RETRY_SEC}"
    fi
    if [ -n "${_cached_ts}" ] && [ "${_cached_port}" = "${FORWARDED_PORT}" ] \
       && [ $((_now - _cached_ts)) -lt "${_iv}" ]; then
      echo "${_cached_val:-unknown}"; return
    fi
  fi

  _resp=$(rpc_call port-test '')
  case "${_resp}" in
    *'"port-is-open":true'*)  _val=open ;;
    *'"port-is-open":false'*) _val=closed ;;
    *)                        _val=unknown ;;
  esac
  echo "${_now} ${_val} ${FORWARDED_PORT}" > "${PORT_TEST_CACHE}" 2>/dev/null || true
  # Counted here, where a fresh result is produced, because guard-push shares
  # this cache and may be the one that actually ran the test.
  case "${_val}" in
    open)
      rm -f "${PORT_CLOSED_COUNT}" "${AUTO_RECOVER_GAVEUP}" 2>/dev/null || true ;;
    closed)
      echo $(( $(_read_int "${PORT_CLOSED_COUNT}") + 1 )) > "${PORT_CLOSED_COUNT}" 2>/dev/null || true ;;
  esac
  echo "${_val}"
}

# A new transmission-daemon instance invalidates the cached port-test: the
# verdict belongs to the previous process, whatever restarted it.
note_tx_instance() {
  _p=$(pidof transmission-daemon 2>/dev/null | awk '{print $1}')
  [ -n "${_p}" ] || return 0
  [ "${_p}" = "$(cat "${TX_PID_SEEN}" 2>/dev/null)" ] && return 0
  echo "${_p}" > "${TX_PID_SEEN}" 2>/dev/null || true
  rm -f "${PORT_TEST_CACHE}" "${PORT_CLOSED_COUNT}" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# automatic VPN recovery (DSM VPN Center only)
# --------------------------------------------------------------------------
recover_vpn_running() {
  _rp=$(cat "${RECOVER_VPN_LOCK}/pid" 2>/dev/null)
  case "${_rp}" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/${_rp}" ]
}

# Called on every reconcile pass. Launches recover-vpn in the background when
#  - the tunnel is up but the port tested closed AUTO_RECOVER_AFTER times in a
#    row: rate-limited by AUTO_RECOVER_COOLDOWN_SEC and AUTO_RECOVER_MAX_PER_6H,
#    so a provider-side problem can't turn into a redial loop; or
#  - an earlier recover-vpn run disconnected the profile and never got it back
#    (DSM doesn't redial a profile disconnected on purpose): retried every
#    AUTO_RECOVER_DOWN_RETRY_SEC with no cap, since the shield itself caused
#    the outage and a long ISP outage must not exhaust the budget above.
auto_recover_tick() {
  [ "${AUTO_RECOVER_VPN}" = "1" ] && [ -n "${DSM_VPN_NAME}" ] || return 0
  [ -x "${RECOVER_VPN_SCRIPT}" ] || return 0
  recover_vpn_running && return 0
  _now=$(date +%s)

  if ! vpn_is_up; then
    [ -f "${TX_HELD_MARKER}" ] || return 0
    _last=$(_read_int "${AUTO_RECOVER_DOWN_LAST}")
    [ $((_now - _last)) -lt "${AUTO_RECOVER_DOWN_RETRY_SEC}" ] && return 0
    echo "${_now}" > "${AUTO_RECOVER_DOWN_LAST}" 2>/dev/null || true
    log "auto-recover: ${VPN_IF} still down after a recover-vpn run - reconnecting VPN profile '${DSM_VPN_NAME}' again"
    _launch_recover_vpn
    return 0
  fi

  [ -n "${FORWARDED_PORT}" ] || return 0
  [ "$(_read_int "${PORT_CLOSED_COUNT}")" -ge "${AUTO_RECOVER_AFTER}" ] || return 0
  _recent=$(awk -v c=$((_now - AUTO_RECOVER_WINDOW_SEC)) '$1 >= c' "${AUTO_RECOVER_ATTEMPTS}" 2>/dev/null)
  _cnt=$(printf '%s\n' "${_recent}" | grep -c '[0-9]')
  _last=$(printf '%s\n' "${_recent}" | tail -n1)
  [ -n "${_last}" ] && [ $((_now - _last)) -lt "${AUTO_RECOVER_COOLDOWN_SEC}" ] && return 0
  if [ "${_cnt}" -ge "${AUTO_RECOVER_MAX_PER_6H}" ]; then
    if [ ! -f "${AUTO_RECOVER_GAVEUP}" ]; then
      log "ERROR: auto-recover: port ${FORWARDED_PORT} still closed after ${_cnt} VPN reconnects in 6h - pausing automatic reconnects until the window frees up; check port forwarding on the VPN provider's side."
      : > "${AUTO_RECOVER_GAVEUP}" 2>/dev/null || true
    fi
    return 0
  fi

  { [ -n "${_recent}" ] && printf '%s\n' "${_recent}"; echo "${_now}"; } > "${AUTO_RECOVER_ATTEMPTS}" 2>/dev/null || true
  rm -f "${PORT_CLOSED_COUNT}" "${AUTO_RECOVER_GAVEUP}" 2>/dev/null || true
  log "auto-recover: port ${FORWARDED_PORT} tested closed ${AUTO_RECOVER_AFTER} times in a row - reconnecting VPN profile '${DSM_VPN_NAME}' (attempt $((_cnt + 1))/${AUTO_RECOVER_MAX_PER_6H} in 6h)"
  _launch_recover_vpn
}

_launch_recover_vpn() {
  # fd 9 is the reconcile lock (run_locked): the detached child must not
  # inherit it, or recover-vpn's own reconcile pass would wait on itself.
  ( exec 9>&-; exec "${RECOVER_VPN_SCRIPT}" ) </dev/null >/dev/null 2>&1 &
}

# Restart Transmission after recover-vpn stopped it and could not bring it
# back itself (tunnel slow to return, script aborted, NAS rebooted mid-run).
resume_held_transmission() {
  [ -f "${TX_HELD_MARKER}" ] || return 0
  recover_vpn_running && return 0
  _start_transmission_if_safe "RESUME" && rm -f "${TX_HELD_MARKER}" 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# Transmission autostart (opt-in)
# --------------------------------------------------------------------------
# With AUTOSTART_TRANSMISSION=1 the shield restarts Transmission after its own
# start — but ONLY once the tunnel is up and the IPv4 default route is in the
# dedicated table, so Transmission is never launched into an unprotected state.
start_transmission() {
  [ "${AUTOSTART_TRANSMISSION}" = "1" ] || return 0
  _start_transmission_if_safe "AUTOSTART"
  return 0
}

# _start_transmission_if_safe TAG -> 0 when Transmission is (now) running,
# 1 when it was left stopped because the protected state isn't complete.
# TAG prefixes the log lines. The "left stopped" reasons are logged at most
# once per reason in a row, since reconcile may call this every pass.
_start_transmission_if_safe() {
  _tag="$1"
  command -v synopkg >/dev/null 2>&1 || return 1

  _uid=$(resolve_tx_uid)
  [ -n "${_uid}" ] || { _held_log "${_tag}" "Transmission UID unresolved"; return 1; }
  vpn_is_up || { _held_log "${_tag}" "VPN down"; return 1; }

  # Everything that makes traffic actually go through the tunnel must be in
  # place, or Transmission's packets fall back to the main table and leak.
  route_v4_is_default   || { _held_log "${_tag}" "IPv4 route not applied yet"; return 1; }
  check_ip_rule_v4 "${_uid}" || { _held_log "${_tag}" "IPv4 UID rule missing"; return 1; }
  if [ "${IPV6_MODE}" != "off" ]; then
    check_ip_rule_v6 "${_uid}" || { _held_log "${_tag}" "IPv6 UID rule missing (kernel too old?) - set IPV6_MODE=off in guard.conf or start Transmission by hand"; return 1; }
    case "${IPV6_MODE}" in
      block) route_v6_is_blackhole || { _held_log "${_tag}" "IPv6 not blackholed yet"; return 1; } ;;
      *)     { route_v6_is_default || route_v6_is_blackhole; } || { _held_log "${_tag}" "IPv6 route not applied yet"; return 1; } ;;
    esac
  fi
  rm -f "${VAR_DIR}/.held-reason" 2>/dev/null || true

  _pkg=$(resolve_tx_pkg) || return 1
  synopkg status "${_pkg}" 2>/dev/null | grep -q '"status":"running"' && return 0
  log "${_tag}: starting ${_pkg} (VPN up, routing + ip rules active)"
  # 9>&-: may run under the reconcile lock; nothing started from here may
  # inherit it.
  synopkg start "${_pkg}" >/dev/null 2>&1 9>&- && return 0
  log "${_tag}: synopkg start ${_pkg} failed"
  return 1
}

_held_log() {
  _hr="$1: $2"
  [ "${_hr}" = "$(cat "${VAR_DIR}/.held-reason" 2>/dev/null)" ] && return 0
  printf '%s\n' "${_hr}" > "${VAR_DIR}/.held-reason" 2>/dev/null || true
  log "${_hr} - leaving Transmission stopped"
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
