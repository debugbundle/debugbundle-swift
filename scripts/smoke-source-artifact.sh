#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSION=$(sed -n 's/.*s.version *= *"\([0-9.]*\)".*/\1/p' "$REPO_DIR/DebugBundle.podspec")
test -n "$VERSION"
ARTIFACT="$REPO_DIR/.tmp/evidence-artifacts/debugbundle-swift-$VERSION-candidate.tar.gz"
CONSUMER_DIR="$REPO_DIR/.tmp/evidence-source-consumer"
test -f "$ARTIFACT"
# Only this disposable clean-consumer tree is replaced. All SDK sources consumed
# below come from the exact retained distribution, not the working checkout.
rm -rf "$CONSUMER_DIR"
mkdir -p "$CONSUMER_DIR"
tar -xzf "$ARTIFACT" -C "$CONSUMER_DIR"
SOURCE_DIR="$CONSUMER_DIR/debugbundle-swift-$VERSION"
make -C "$SOURCE_DIR" build-ios-15
make -C "$SOURCE_DIR" smoke-spm
make -C "$SOURCE_DIR" smoke-cocoapods
echo "Exact Swift source-distribution consumers passed."
