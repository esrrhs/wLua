#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <PID>"
    exit 1
fi

PID="$1"

if ! kill -0 "$PID" 2>/dev/null; then
    echo "Error: Process $PID does not exist or is not accessible."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SO_PATH="${SCRIPT_DIR}/libwlua.so"

if [ ! -f "$SO_PATH" ]; then
    if [ -f "${SCRIPT_DIR}/build/libwlua.so" ]; then
        SO_PATH="${SCRIPT_DIR}/build/libwlua.so"
    else
        echo "Error: libwlua.so not found. Please run ./build.sh first."
        exit 1
    fi
fi

HOOKSO="${SCRIPT_DIR}/hookso"
if ! command -v "$HOOKSO" >/dev/null 2>&1; then
    if command -v hookso >/dev/null 2>&1; then
        HOOKSO="hookso"
    else
        echo "Error: hookso binary not found in current directory or PATH."
        echo "Please download and build hookso from https://github.com/esrrhs/hookso"
        exit 1
    fi
fi

if ! command -v gdb >/dev/null 2>&1; then
    echo "Error: gdb is required but not installed."
    exit 1
fi

rm -f wlua_result.log wlua_check.log

echo "==> Injecting ${SO_PATH} into PID ${PID}..."
"$HOOKSO" dlopen "$PID" "$SO_PATH"
echo "==> Injected libwlua.so successfully."

get_symbol_addr() {
    local sym="$1"
    local raw
    raw=$(gdb -p "$PID" -ex "p (long)${sym}" --batch 2>/dev/null || true)
    local addr
    addr=$(echo "$raw" | grep -E '\$[0-9]+ = ' | sed -E 's/.*\$[0-9]+ = (-?[0-9]+|0x[0-9a-fA-F]+).*/\1/' || true)
    echo "$addr"
}

NIL_ADDR=$(get_symbol_addr "&luaO_nilobject_")
if [ -z "$NIL_ADDR" ]; then
    echo "Error: Failed to obtain luaO_nilobject_ address from PID $PID."
    exit 1
fi

echo "set_lua_nilobject ADDR=${NIL_ADDR}"
"$HOOKSO" call "$PID" libwlua.so set_lua_nilobject "i=${NIL_ADDR}"

FUNC="luaH_resize luaH_get luaH_set luaC_fullgc luaC_step luaC_newobj luaS_new luaS_newlstr"

for f in $FUNC; do
    ADDR=$(get_symbol_addr "$f")
    if [ -z "$ADDR" ]; then
        echo "Error: Failed to obtain $f address from PID $PID."
        exit 1
    fi
    echo "Hooking $f ADDR=${ADDR} -> new_$f"
    "$HOOKSO" replacep "$PID" "$ADDR" "$SO_PATH" "new_$f"
done

echo "==> All hooks installed successfully for PID ${PID}."
echo "==> Results will be written to wlua_result.log"
