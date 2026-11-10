#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="${SCRIPT_DIR}/scripts/wlua_preflight.sh"

if [[ ! -f "$PREFLIGHT" ]]; then
    echo "Error: missing $PREFLIGHT" >&2
    echo "  The startup diagnostics library is required. Restore it from the wLua source tree." >&2
    exit 1
fi

# shellcheck source=scripts/wlua_preflight.sh
source "$PREFLIGHT"

WLUA_APP_NAME="$(basename -- "$0")"
wlua_main "$SCRIPT_DIR" "$@"
exit $?
