#!/usr/bin/env bash
#
# localrelease.sh — build a Release version of the app and install it into
# ~/Applications, replacing any previous copy.
#
# This is a LOCAL release only: the .app is signed with whatever identity Xcode
# picks automatically (a dev cert is fine). It is NOT notarized, so it runs on
# this machine but would be Gatekeeper-blocked on others. For public
# distribution you need the archive → export → notarize → staple flow instead.
#
# Usage:
#   Tools/localrelease.sh            # build + install
#   Tools/localrelease.sh --open     # also launch it afterwards
#
set -euo pipefail

# Resolve repo root from this script's location, so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="Macsribe.xcodeproj"                  # TODO(app-name)
SCHEME="Macsribe"                             # TODO(app-name)
PRODUCT_NAME="$(grep -m1 'PRODUCT_NAME:' project.yml | sed 's/.*PRODUCT_NAME:[[:space:]]*//;s/[[:space:]]*#.*//')"
PRODUCT_NAME="${PRODUCT_NAME:-Macsribe}"
APP_NAME="${PRODUCT_NAME}.app"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME"

echo "==> Regenerating $PROJECT from project.yml"
xcodegen generate

echo "==> Building $SCHEME (Release)"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: expected build product not found at $BUILT_APP" >&2
  exit 1
fi

echo "==> Installing into $DEST_DIR (replacing previous copy)"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
# ditto preserves bundle structure, symlinks, and code-signing metadata; mv/cp can corrupt signed bundles.
ditto "$BUILT_APP" "$DEST_APP"

echo "==> Installed: $DEST_APP"

if [[ "${1:-}" == "--open" ]]; then
  echo "==> Launching"
  open "$DEST_APP"
fi
