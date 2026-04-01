#!/bin/bash

set -euo pipefail

RTK_ENABLED="${RTK_ENABLED:-0}"
RTK_LOG_DIR="${RTK_LOG_DIR:-/tmp}"

setup_rtk_for_codex() {
    if [ "$RTK_ENABLED" != "1" ]; then
        return 0
    fi

    if ! command -v rtk >/dev/null 2>&1; then
        echo "WARN: RTK_ENABLED=1 but rtk is not installed; running Codex without RTK" >&2
        return 0
    fi

    local runtime_home="/root/rtk-codex-home"
    local runtime_codex_dir="${runtime_home}/.codex"
    local log_file="${RTK_LOG_DIR}/rtk-codex-init-$(date +%s)-$$.log"

    mkdir -p "$runtime_codex_dir"
    if [ -d "/root/.codex" ]; then
        cp -R /root/.codex/. "$runtime_codex_dir/" 2>/dev/null || true
    fi

    export HOME="$runtime_home"
    export CODEX_HOME="$runtime_codex_dir"

    if ! rtk init -g --codex >"$log_file" 2>&1; then
        echo "WARN: RTK init for Codex failed; running Codex without RTK-managed instructions" >&2
        return 0
    fi

    echo "RTK Codex integration enabled via ${runtime_codex_dir}" >&2
}

setup_rtk_for_codex
exec codex exec "$@"
