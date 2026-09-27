#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "==> Configuring wLua (Release)..."
cmake -B "${BUILD_DIR}" -S "${SCRIPT_DIR}" -DCMAKE_BUILD_TYPE=Release

echo "==> Building wLua..."
cmake --build "${BUILD_DIR}" --config Release -j"$(nproc 2>/dev/null || echo 2)"

if [ -f "${BUILD_DIR}/libwlua.so" ]; then
    cp -f "${BUILD_DIR}/libwlua.so" "${SCRIPT_DIR}/libwlua.so"
fi

echo "==> Build successful: ${SCRIPT_DIR}/libwlua.so"
