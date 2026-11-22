#!/bin/bash
# Runs one store tool (store/<tool>.mjs) under the app's own tsx, so the app's catalog module, which
# imports the app's TypeScript product code, loads as it does in the app's tests.
#   store/app-tsx.sh <tool> <catalog module> [flags]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$1"; shift
catalog="${1:-}"
if [ -z "$catalog" ] || [ ! -f "$catalog" ]; then
  echo "OUTPUT $tool: NAMED STOP [CATALOG_MISSING] usage: $tool <the app's catalog module> [flags] (got '${catalog}')"; exit 2
fi
dir="$(cd "$(dirname "$catalog")" && pwd)"
while [ "$dir" != / ] && [ ! -x "$dir/node_modules/.bin/tsx" ]; do dir="$(dirname "$dir")"; done
if [ ! -x "$dir/node_modules/.bin/tsx" ]; then
  echo "OUTPUT $tool: NAMED STOP [TSX_MISSING] no node_modules/.bin/tsx above $catalog (run npm ci in the app first)"; exit 2
fi
exec "$dir/node_modules/.bin/tsx" "$here/$tool.mjs" "$@"
