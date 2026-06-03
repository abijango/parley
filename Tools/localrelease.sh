#!/usr/bin/env bash
#
# localrelease.sh — build a Release version of the app and install it into
# ~/Applications, replacing any previous copy.
#
# Signing: every build is signed with a STABLE, self-signed code-signing
# certificate named after the app ("<PRODUCT_NAME> Local Codesign"). A stable
# signing identity gives the app a constant *designated requirement*, which is
# what macOS keys on for:
#   • TCC permissions   — mic, audio capture, Documents/Desktop folder access
#   • the keychain       — saved secrets / grants
#   • the ANE cache      — ~/Library/Caches/<bundleID>/com.apple.e5rt.e5bundlecache
# With ad-hoc signing (Xcode's default fallback) the code hash changes on every
# build, so all three are treated as "a brand new app" and reset — re-prompting
# for permissions and re-specializing the CoreML models on the Neural Engine.
# Signing with the same cert each time avoids that.
#
# The cert is tied to the app NAME on purpose: if you rename the app (resolving
# the TODO(app-name) sweep), PRODUCT_NAME changes, a new cert is minted, and the
# bundle id changes too — so the rename is one clean new identity, by design.
#
# This is a LOCAL release only — the cert is self-signed, NOT notarized, so the
# app runs on THIS machine but would be Gatekeeper-blocked elsewhere. For public
# distribution use the archive → export → notarize → staple flow instead.
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

PROJECT="Parley.xcodeproj"                  # TODO(app-name)
SCHEME="Parley"                             # TODO(app-name)
PRODUCT_NAME="$(grep -m1 'PRODUCT_NAME:' project.yml | sed 's/.*PRODUCT_NAME:[[:space:]]*//;s/[[:space:]]*#.*//')"
PRODUCT_NAME="${PRODUCT_NAME:-Parley}"
APP_NAME="${PRODUCT_NAME}.app"
DERIVED="$REPO_ROOT/.build-xcode"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/$APP_NAME"

# Stable self-signed signing identity, named after the app.
CERT_CN="${PRODUCT_NAME} Local Codesign"
LOGIN_KEYCHAIN="$(security default-keychain | tr -d ' "')"

# --- Ensure the signing certificate exists (create it once, reuse forever) ----
ensure_signing_cert() {
  if security find-certificate -c "$CERT_CN" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Signing cert present: \"$CERT_CN\""
    return 0
  fi

  echo "==> Creating self-signed code-signing cert: \"$CERT_CN\""
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/req.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions   = ext
prompt            = no
[ dn ]
CN = $CERT_CN
[ ext ]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

  # 10-year self-signed cert + private key, bundled into a PKCS#12.
  # -legacy: OpenSSL 3 defaults to a MAC/cipher macOS's importer rejects
  # ("MAC verification failed"); -legacy emits the SHA1/3DES form `security`
  # accepts. A transient password is used because empty-password p12 + legacy
  # MAC is also flaky on import.
  local p12pass="localrelease"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/req.conf" >/dev/null 2>&1
  openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$CERT_CN" -out "$tmp/id.p12" -passout pass:"$p12pass" >/dev/null 2>&1

  # Import key+cert into the login keychain. -T grants codesign access to the
  # key; -A allows it without a per-use prompt.
  security import "$tmp/id.p12" -k "$LOGIN_KEYCHAIN" -P "$p12pass" -A -T /usr/bin/codesign >/dev/null

  # Trust it for code signing (user domain — no sudo). Best-effort: codesign can
  # sign with an untrusted self-signed cert too; trust just lets `find-identity
  # -v` and strict verification recognise it. May raise one keychain prompt.
  security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$tmp/cert.pem" >/dev/null 2>&1 \
    || echo "    (note: could not set trust automatically — signing still works locally)"
}

ensure_signing_cert

echo "==> Regenerating $PROJECT from project.yml"
xcodegen generate

echo "==> Building $SCHEME (Release), signed as \"$CERT_CN\""
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CERT_CN" \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
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
echo "    signed by: $(codesign -dvv "$DEST_APP" 2>&1 | grep -E '^Authority=' | head -1 | sed 's/^Authority=//')"

if [[ "${1:-}" == "--open" ]]; then
  echo "==> Launching"
  open "$DEST_APP"
fi
