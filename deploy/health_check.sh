#!/bin/bash
# Minimal describe-only Wyoming health probe.
#
# Prefers `nc` (present on virtually every macOS/Linux box) over bash's
# built-in /dev/tcp — some sandboxed/restricted environments (CI runners,
# locked-down shells) block raw /dev/tcp socket syscalls from the shell
# itself while still allowing actual network binaries like nc, so nc is the
# more portable choice. /dev/tcp remains as a fallback for the rare case nc
# isn't installed.
#
# Usage: health_check.sh [host] [port]
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-10300}"

check_with_nc() {
    # -w 5: give up if the connection goes idle for 5s. Since this server
    # keeps the connection open after responding (Wyoming clients reuse
    # connections for multiple utterances), nc waits out the full idle
    # window even on success — a few seconds of latency here is a fine
    # trade for working reliably in more environments.
    printf '{"type":"describe"}\n' | nc -w 5 "$HOST" "$PORT" 2>/dev/null
}

check_with_devtcp() {
    exec 3<>"/dev/tcp/$HOST/$PORT" || return 1
    printf '{"type":"describe"}\n' >&3
    local response
    if ! read -t 5 -u 3 response; then
        exec 3<&- 3>&-
        return 1
    fi
    exec 3<&- 3>&-
    printf '%s' "$response"
}

if command -v nc >/dev/null 2>&1; then
    response="$(check_with_nc)" || true
else
    response="$(check_with_devtcp)" || true
fi

if [[ -z "$response" ]]; then
    echo "FAIL: could not connect to $HOST:$PORT"
    exit 1
fi

if [[ "$response" == *'"type":"info"'* ]] || [[ "$response" == *'"type": "info"'* ]]; then
    echo "OK: $HOST:$PORT responded to describe with info"
    exit 0
else
    echo "FAIL: unexpected response: $response"
    exit 1
fi
