#!/bin/bash
# The shared store tools (store/play-products.mjs, store/revenuecat-setup.mjs) against in-memory
# Google Play and RevenueCat fakes: writes, never-touch cases, and every outage shape.
# Rule 0: fewer than 15 tests run is a failure, never a pass of nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(node --test tests/store/*.test.mjs 2>&1)" || { echo "$out"; echo "FAIL store tools"; exit 1; }
pass="$(echo "$out" | sed -n 's/^ℹ pass \([0-9]*\)$/\1/p')"
if [ "${pass:-0}" -lt 15 ]; then echo "$out"; echo "FAIL store tools: only ${pass:-0} tests ran"; exit 1; fi
echo "PASS store tools: $pass tests"
