#!/bin/bash
#
# Runs the test suites of the hardened fork, each in a new Debian 13 container.
# Usage: tests/fork/run.sh [suite ...]
# Without arguments, all suites run. The suites are in tests/fork/suites.
# Needs Docker. The firewall suite needs NET_ADMIN for real iptables rules.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
image="raspap-fork-test"

docker build -q -t "$image" "$here" > /dev/null || { echo "Unable to build the test image" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
    suites=("$@")
else
    suites=()
    for f in "$here"/suites/*.sh; do suites+=("$(basename "$f" .sh)"); done
fi

rc=0
for s in "${suites[@]}"; do
    echo "=== $s"
    if ! docker run --rm --cap-add NET_ADMIN -v "$repo:/s:ro" "$image" bash "/s/tests/fork/suites/$s.sh"; then
        rc=1
    fi
done
exit "$rc"
