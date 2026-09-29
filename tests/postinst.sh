#!/bin/sh
# tests/postinst.sh — guard.conf seeding and upgrade migration in postinst
#
# Runs as a normal user (NOT root: as root postinst would apply the privilege
# elevation). Everything happens under a throwaway PKG_DIR.
#
# Usage:  sh tests/postinst.sh

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "${HERE}/.." && pwd)
POSTINST="${REPO}/synology/scripts/postinst"
TEMPLATE="${REPO}/synology/conf/guard.conf"
WORK=$(mktemp -d "${HERE}/tvpi-work.XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "${WORK}"' EXIT INT TERM

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
notok(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
check(){ desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else notok "${desc}"; fi; }

[ "$(id -u)" -ne 0 ] || { echo "run as a normal user, not root"; exit 2; }

# Keys postinst appends on upgrade, read from postinst itself so a new key
# can't be added there without this test checking it.
KEYS=$(sed -n 's/^[[:space:]]*_append_key \([A-Z_0-9]*\) .*/\1/p' "${POSTINST}")

mkpkg() {
  P="${WORK}/pkg"
  rm -rf "${P}"
  mkdir -p "${P}/conf" "${P}/target/ui" "${P}/scripts" "${P}/var"
  cp "${TEMPLATE}" "${P}/conf/guard.conf"
  : > "${P}/conf/guard.secret"
}
run_postinst() { PKG_DIR="${WORK}/pkg" sh "${POSTINST}" >/dev/null 2>&1; }

echo "# postinst tests"

check "postinst declares at least one migrated key" test -n "${KEYS}"
for k in ${KEYS}; do
  check "template defines migrated key ${k}" grep -q "^${k}=" "${TEMPLATE}"
done

# ============ fresh install ============
mkpkg
run_postinst
check "install: exits 0 as non-root"               run_postinst
check "install: guard.conf seeded into etc/"       cmp -s "${TEMPLATE}" "${P}/etc/guard.conf"
check "install: target/conf/guard.conf -> etc/"    test "$(readlink "${P}/target/conf/guard.conf")" = "${P}/etc/guard.conf"
check "install: guard.secret seeded"               test -f "${P}/etc/guard.secret"
check "install: guard.secret is 0600"              sh -c "ls -l '${P}/etc/guard.secret' | grep -q '^-rw-------'"
check "install: needs-activation flag set"         test -f "${P}/var/needs-activation"

# ============ upgrade from an old guard.conf ============
mkpkg
mkdir -p "${P}/etc"
cat > "${P}/etc/guard.conf" <<'EOF'
TRANSMISSION_USER="custom-user"
VPN_IF="tun7"
FORWARDED_PORT="12345"
AUTOSTART_TRANSMISSION="1"
EOF
run_postinst
for k in ${KEYS}; do
  check "upgrade: ${k} appended"                   grep -q "^${k}=" "${P}/etc/guard.conf"
done
check "upgrade: existing values kept"              sh -c "grep -q '^VPN_IF=\"tun7\"' '${P}/etc/guard.conf' && grep -q '^FORWARDED_PORT=\"12345\"' '${P}/etc/guard.conf'"
check "upgrade: existing key not duplicated"       test "$(grep -c '^AUTOSTART_TRANSMISSION=' "${P}/etc/guard.conf")" -eq 1
check "upgrade: user value of an existing key kept" grep -q '^AUTOSTART_TRANSMISSION="1"' "${P}/etc/guard.conf"
check "upgrade: new AUTO_RECOVER_VPN defaults to 1" grep -q '^AUTO_RECOVER_VPN="1"' "${P}/etc/guard.conf"
check "upgrade: migrated file still parses"        sh -n "${P}/etc/guard.conf"

cp "${P}/etc/guard.conf" "${WORK}/after-first"
run_postinst
check "upgrade: second run changes nothing"         cmp -s "${WORK}/after-first" "${P}/etc/guard.conf"

# ============ existing secret is never overwritten ============
echo 'RPC_USER="someone"' > "${P}/etc/guard.secret"
run_postinst
check "upgrade: existing guard.secret kept"        grep -q someone "${P}/etc/guard.secret"

echo "# ---------------------------------------------"
echo "# PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
