#!/bin/sh
# tests/run-all.sh — every test suite, as the GitHub workflow runs them.
#
# Run as a normal user with sudo available (Linux): postinst/ui must NOT run
# as root, reconcile/recover-vpn must.
#
# Usage:  sh tests/run-all.sh

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
rc=0
for t in postinst ui; do
  echo "== ${t}"; sh "${HERE}/${t}.sh" || rc=1
done
for t in reconcile recover-vpn; do
  echo "== ${t}"; sudo sh "${HERE}/${t}.sh" || rc=1
done
[ "${rc}" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "${rc}"
