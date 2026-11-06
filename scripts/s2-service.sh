#!/usr/bin/env bash
# Start / stop / status the s2.cpp HTTP server on macOS (Metal build).
#
# Usage:
#   scripts/s2-service.sh start      # build if needed, then start in background
#   scripts/s2-service.sh stop
#   scripts/s2-service.sh restart
#   scripts/s2-service.sh status
#   scripts/s2-service.sh build      # force configure + build only
#
# Overrides (environment variables):
#   S2_MODEL      path to GGUF model   (default: ~/personal/Hibiki/s2cpp/models/s2-pro-q4_k_m.gguf)
#   S2_TOKENIZER  path to tokenizer    (default: <repo>/tokenizer.json)
#   S2_PORT       HTTP port            (default: 13030)
#   S2_LOG_DIR    log directory        (default: ~/Library/Logs/s2cpp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$REPO_DIR/build"
BIN="$BUILD_DIR/s2"
MODEL="${S2_MODEL:-$HOME/personal/Hibiki/s2cpp/models/s2-pro-q4_k_m.gguf}"
TOKENIZER="${S2_TOKENIZER:-$REPO_DIR/tokenizer.json}"
PORT="${S2_PORT:-13030}"
LOG_DIR="${S2_LOG_DIR:-$HOME/Library/Logs/s2cpp}"
PID_FILE="$LOG_DIR/s2.pid"
LOG_FILE="$LOG_DIR/s2.log"

log() { printf '[s2] %s\n' "$*"; }
die() { printf '[s2] error: %s\n' "$*" >&2; exit 1; }

build() {
    cd "$REPO_DIR"
    if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
        log "configuring (Metal, Release)..."
        cmake -B build -DCMAKE_BUILD_TYPE=Release -DS2_METAL=ON
    fi
    log "building..."
    cmake --build build --parallel "$(sysctl -n hw.ncpu)"
}

is_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start() {
    [[ -f "$MODEL" ]] || die "model not found: $MODEL (set S2_MODEL)"
    [[ -f "$TOKENIZER" ]] || die "tokenizer not found: $TOKENIZER (set S2_TOKENIZER)"

    if is_running; then
        log "already running (pid $(cat "$PID_FILE"), port $PORT)"
        return 0
    fi

    build
    [[ -x "$BIN" ]] || die "binary not found after build: $BIN"

    mkdir -p "$LOG_DIR"
    cd "$REPO_DIR"
    # nohup + redirect so the server survives the terminal closing.
    nohup "$BIN" --model "$MODEL" --tokenizer "$TOKENIZER" --server --port "$PORT" \
        >>"$LOG_FILE" 2>&1 </dev/null &
    echo $! >"$PID_FILE"
    disown "$!" 2>/dev/null || true

    sleep 1
    if is_running; then
        log "started (pid $(cat "$PID_FILE"), port $PORT)"
        log "log: $LOG_FILE"
    else
        rm -f "$PID_FILE"
        die "server exited immediately; see $LOG_FILE"
    fi
}

stop() {
    if ! is_running; then
        log "not running"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    log "stopping pid $pid..."
    kill "$pid"
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        log "still alive, sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    log "stopped"
}

status() {
    if is_running; then
        log "running (pid $(cat "$PID_FILE"), port $PORT)"
        log "log: $LOG_FILE"
    else
        log "not running"
        return 1
    fi
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)  status ;;
    build)   build ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
