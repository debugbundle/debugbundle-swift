#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SMOKE_DIR="$REPO_DIR/.smoke/cocoapods"
EVENTS_FILE="$SMOKE_DIR/events.ndjson"
PORT=${DEBUGBUNDLE_SMOKE_PORT:-18083}
PUBLISHED_VERSION=""

if [ "${1:-}" = "--published" ]; then
  PUBLISHED_VERSION=${2:?published CocoaPods version is required}
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--published VERSION]" >&2
  exit 1
fi

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR"
SMOKE_ENDPOINT="http://127.0.0.1:$PORT/v1/events"
if ruby -e 'require "xcodeproj"' >/dev/null 2>&1; then
  ruby "$REPO_DIR/scripts/create-cocoapods-smoke-project.rb" "$SMOKE_DIR" "$SMOKE_ENDPOINT"
else
  POD_WRAPPER=$(command -v pod)
  POD_GEM_HOME=$(sed -n 's/^GEM_HOME="\([^"]*\)".*/\1/p' "$POD_WRAPPER")
  POD_EXECUTABLE=$(sed -n 's/.*exec "\([^"]*\/pod\)".*/\1/p' "$POD_WRAPPER")
  POD_RUBY=$(sed -n '1s/^#!//p' "$POD_EXECUTABLE")
  if [ -z "$POD_GEM_HOME" ] || [ -z "$POD_RUBY" ]; then
    echo "Unable to locate the Ruby environment used by CocoaPods." >&2
    exit 1
  fi
  GEM_HOME="$POD_GEM_HOME" "$POD_RUBY" "$REPO_DIR/scripts/create-cocoapods-smoke-project.rb" "$SMOKE_DIR" "$SMOKE_ENDPOINT"
fi

if [ -n "$PUBLISHED_VERSION" ]; then
  POD_DECLARATION="pod 'DebugBundle', '$PUBLISHED_VERSION'"
else
  POD_DECLARATION="pod 'DebugBundle', :path => '$REPO_DIR'"
fi

cat > "$SMOKE_DIR/Podfile" <<EOF
platform :ios, '15.0'
use_frameworks!

target 'DebugBundlePodSmokeTests' do
  $POD_DECLARATION
end
EOF

if [ -n "$PUBLISHED_VERSION" ]; then
  pod install --repo-update --project-directory="$SMOKE_DIR"
else
  pod install --project-directory="$SMOKE_DIR"
fi

DEBUGBUNDLE_SMOKE_EVENTS_FILE="$EVENTS_FILE" \
DEBUGBUNDLE_SMOKE_PORT="$PORT" \
DEBUGBUNDLE_SMOKE_SERVICE="swift-cocoapods-smoke" \
  node "$REPO_DIR/scripts/mock-ingestion.mjs" &
SERVER_PID=$!

attempt=0
until curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Swift CocoaPods smoke mock ingestion did not become ready" >&2
    exit 1
  fi
  sleep 1
done

DESTINATION=${IOS_SIMULATOR_DESTINATION:-$(sh "$REPO_DIR/scripts/resolve-ios-simulator-destination.sh")}
xcodebuild test \
    -workspace "$SMOKE_DIR/DebugBundlePodSmoke.xcworkspace" \
    -scheme DebugBundlePodSmoke \
    -destination "$DESTINATION" \
    CODE_SIGNING_ALLOWED=NO

if [ ! -s "$EVENTS_FILE" ]; then
  echo "Swift clean CocoaPods consumer did not reach mock ingestion" >&2
  exit 1
fi

echo "Swift CocoaPods artifact smoke passed."
