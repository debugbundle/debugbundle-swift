#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SMOKE_DIR="$REPO_DIR/.smoke/spm"
EVENTS_FILE="$SMOKE_DIR/events.ndjson"
PORT=${DEBUGBUNDLE_SMOKE_PORT:-18082}

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"

DEBUGBUNDLE_SMOKE_EVENTS_FILE="$EVENTS_FILE" \
DEBUGBUNDLE_SMOKE_PORT="$PORT" \
  node "$REPO_DIR/scripts/mock-ingestion.mjs" &
SERVER_PID=$!

attempt=0
until curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Swift smoke mock ingestion did not become ready" >&2
    exit 1
  fi
  sleep 1
done

# Path dependencies can keep a stale source-file list when new SDK files are added.
# This is a clean-consumer gate, so discard only this consumer's generated build cache.
swift package --package-path "$REPO_DIR/smoke/spm-consumer" clean

DEBUGBUNDLE_SMOKE_ENDPOINT="http://127.0.0.1:$PORT/v1/events" \
  swift run --package-path "$REPO_DIR/smoke/spm-consumer" DebugBundleSpmSmoke

if [ ! -s "$EVENTS_FILE" ]; then
  echo "Swift clean SPM consumer did not reach mock ingestion" >&2
  exit 1
fi

echo "Swift SPM artifact smoke passed."
