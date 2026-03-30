#!/bin/bash

set -euo pipefail

HEADROOM_ENABLED="${HEADROOM_ENABLED:-0}"
HEADROOM_PORT="${HEADROOM_PORT:-8787}"
HEADROOM_HOST="${HEADROOM_HOST:-127.0.0.1}"
HEADROOM_STARTUP_DELAY="${HEADROOM_STARTUP_DELAY:-2}"
HEADROOM_LOG_DIR="${HEADROOM_LOG_DIR:-/tmp}"
RTK_ENABLED="${RTK_ENABLED:-0}"
RTK_LOG_DIR="${RTK_LOG_DIR:-/tmp}"
HEADROOM_PROXY_PID=""

cleanup() {
    if [ -n "${HEADROOM_PROXY_PID:-}" ] && kill -0 "$HEADROOM_PROXY_PID" 2>/dev/null; then
        kill "$HEADROOM_PROXY_PID" 2>/dev/null || true
        wait "$HEADROOM_PROXY_PID" 2>/dev/null || true
    fi
}

start_headroom_proxy() {
    if [ "$HEADROOM_ENABLED" != "1" ]; then
        return 0
    fi

    if ! command -v headroom >/dev/null 2>&1; then
        echo "WARN: HEADROOM_ENABLED=1 but headroom is not installed; running Codex directly" >&2
        return 0
    fi

    export OPENAI_BASE_URL="http://${HEADROOM_HOST}:${HEADROOM_PORT}/v1"
    local log_file="${HEADROOM_LOG_DIR}/headroom-proxy-$(date +%s)-$$.log"

    headroom proxy --port "$HEADROOM_PORT" >"$log_file" 2>&1 &
    HEADROOM_PROXY_PID=$!
    trap cleanup EXIT
    sleep "$HEADROOM_STARTUP_DELAY"

    if ! kill -0 "$HEADROOM_PROXY_PID" 2>/dev/null; then
        echo "WARN: Headroom proxy exited early; running Codex directly" >&2
        HEADROOM_PROXY_PID=""
        unset OPENAI_BASE_URL
        trap - EXIT
        return 0
    fi

    echo "Headroom proxy enabled at ${OPENAI_BASE_URL}" >&2
}

setup_rtk_for_codex() {
    if [ "$RTK_ENABLED" != "1" ]; then
        return 0
    fi

    if ! command -v rtk >/dev/null 2>&1; then
        echo "WARN: RTK_ENABLED=1 but rtk is not installed; running Codex without RTK" >&2
        return 0
    fi

    local runtime_home="/tmp/rtk-codex-home"
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
start_headroom_proxy
exec codex exec "$@"
