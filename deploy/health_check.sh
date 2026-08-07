#!/bin/bash
# Minimal describe-only Wyoming health probe. No Python dependency (uses
# bash's /dev/tcp), so it works standalone on a fresh mini install without
# needing the conversion venv to be present.
#
# Usage: health_check.sh [host] [port]
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-10300}"

exec 3<>"/dev/tcp/$HOST/$PORT" || {
    echo "FAIL: could not connect to $HOST:$PORT"
    exit 1
}

printf '{"type":"describe"}\n' >&3

# Read the response header line (up to the first newline) with a timeout.
# `read -t` is a bash builtin (portable across stock macOS/Linux) — avoids
# depending on GNU coreutils' `timeout`, which stock macOS doesn't ship.
if ! read -t 5 -u 3 response; then
    echo "FAIL: no response from $HOST:$PORT within 5s"
    exec 3<&- 3>&-
    exit 1
fi

exec 3<&- 3>&-

if [[ "$response" == *'"type":"info"'* ]] || [[ "$response" == *'"type": "info"'* ]]; then
    echo "OK: $HOST:$PORT responded to describe with info"
    exit 0
else
    echo "FAIL: unexpected response: $response"
    exit 1
fi
