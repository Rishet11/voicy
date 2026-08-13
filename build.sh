#!/bin/bash
# Builds Voicy and assembles a proper .app bundle (needed so macOS permission
# prompts attach to the bundled process), then signs it with a stable identity.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
case "$CONFIG" in
  release|debug) ;;
  -h|--help)
    echo "usage: ./build.sh [release|debug]"
    echo "Builds Voicy and writes a runnable bundle to dist/Voicy.app."
    exit 0 ;;
  *)
    echo "ERROR: unknown configuration '$CONFIG'." >&2
    echo "       usage: ./build.sh [release|debug]" >&2
    exit 2 ;;
esac

APP_NAME="Voicy"
ROOT="$(pwd)"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_ROOT="${TMPDIR:-/private/tmp}/voicy-app-staging.$$"
STAGED_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
STAGED_BIN_DIR="$STAGED_BUNDLE/Contents/MacOS"
STAGED_RES_DIR="$STAGED_BUNDLE/Contents/Resources"
BIN_DIR="$APP_BUNDLE/Contents/MacOS"
RES_DIR="$APP_BUNDLE/Contents/Resources"
cleanup_staging() { rm -rf "$STAGING_ROOT"; }
trap cleanup_staging EXIT

# --- Preflight. Fail here, with a fix, rather than mid-build with a stack trace.
fail() { echo "ERROR: $1" >&2; shift; for line in "$@"; do echo "       $line" >&2; done; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail \
  "Voicy is a macOS app; this is $(uname -s)." \
  "Build it on a Mac running macOS 14 or newer."

for f in Package.swift Info.plist Sources/Voicy; do
  [ -e "$ROOT/$f" ] || fail \
    "missing $f — this does not look like a Voicy checkout." \
    "Run build.sh from the repository root: ./build.sh"
done

command -v xcode-select >/dev/null 2>&1 || fail \
  "Xcode command line tools are not installed." \
  "Install them with: xcode-select --install"

if ! xcrun --find swift >/dev/null 2>&1; then
  fail "no Swift toolchain is selected." \
    "Install Xcode (or the command line tools) and point at it:" \
    "  xcode-select --install" \
    "  sudo xcode-select --switch /Applications/Xcode.app"
fi

command -v swift >/dev/null 2>&1 || fail \
  "'swift' is not on PATH even though a toolchain exists." \
  "Try: sudo xcode-select --switch /Applications/Xcode.app"

SWIFT_MAJOR="$(swift -version 2>&1 | sed -n 's/.*Swift version \([0-9]*\).*/\1/p' | head -1)"
if [ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -lt 6 ]; then
  fail "Swift $SWIFT_MAJOR found, but Package.swift needs Swift 6 or newer." \
    "Update Xcode, then re-run ./build.sh"
fi

command -v codesign >/dev/null 2>&1 || fail \
  "'codesign' is missing, so the bundle cannot be signed." \
  "It ships with the Xcode command line tools: xcode-select --install"

echo "==> Building Swift package ($CONFIG)"
swift build -c "$CONFIG"

# Locate the built binary.
if [ "$CONFIG" = "release" ]; then
    BIN="$ROOT/.build/release/$APP_NAME"
else
    BIN="$ROOT/.build/debug/$APP_NAME"
fi

if [ ! -f "$BIN" ]; then
    fail "the build reported success but no binary exists at $BIN." \
      "Try a clean rebuild: rm -rf .build && ./build.sh"
fi

plutil -lint "$ROOT/Info.plist" >/dev/null || fail \
  "Info.plist is not a valid property list, so the bundle would not launch." \
  "Inspect it with: plutil -lint Info.plist"

echo "==> Assembling $APP_BUNDLE"
rm -rf "$DIST_DIR" "$STAGING_ROOT"
mkdir -p "$STAGED_BIN_DIR" "$STAGED_RES_DIR"

cp "$BIN" "$STAGED_BIN_DIR/$APP_NAME"
cp "$ROOT/Info.plist" "$STAGED_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$STAGED_BUNDLE/Contents/PkgInfo"

# The dist dir and copied files may carry environment provenance/Finder xattrs
# that make codesign reject the bundle. The whole dist tree was recreated
# above, and the recursive clear is deliberately fatal if it cannot complete.
xattr -cr "$STAGED_BUNDLE"

# Ad-hoc signing (--sign -) changes the app's code identity on every build.
# Prefer an explicitly configured identity. Otherwise create the local
# self-signed identity once in the login keychain and reuse it every build.
SIGNING_NAME="${VOICY_SIGNING_NAME:-Voicy Local Signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ -n "${VOICY_SIGN_ID:-}" ]; then
  SIGN_ID="$VOICY_SIGN_ID"
elif [ -f "$LOGIN_KEYCHAIN" ] && security find-certificate -a -c "$SIGNING_NAME" \
  -k "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  SIGN_ID="$SIGNING_NAME"
else
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi

if [ -z "$SIGN_ID" ]; then
  echo "==> Creating stable self-signed identity: $SIGNING_NAME"
  SIGNING_TMP="$STAGING_ROOT/signing"
  mkdir -p "$SIGNING_TMP"
  cat > "$SIGNING_TMP/openssl.cnf" <<EOF
[req]
distinguished_name = subject
prompt = no
x509_extensions = codesigning
[subject]
CN = $SIGNING_NAME
[codesigning]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$SIGNING_TMP/openssl.cnf" \
    -keyout "$SIGNING_TMP/voicy-signing.key" \
    -out "$SIGNING_TMP/voicy-signing.crt" >/dev/null 2>&1 || fail \
    "could not create the local signing certificate." \
    "Install OpenSSL, then re-run ./build.sh"
  cat "$SIGNING_TMP/voicy-signing.crt" "$SIGNING_TMP/voicy-signing.key" \
    > "$SIGNING_TMP/voicy-signing.pem"
  [ -f "$LOGIN_KEYCHAIN" ] || fail \
    "the login keychain was not found at $LOGIN_KEYCHAIN." \
    "Sign in to macOS, then re-run ./build.sh"
  security import "$SIGNING_TMP/voicy-signing.pem" -k "$LOGIN_KEYCHAIN" \
    -t agg -f pemseq -T /usr/bin/codesign -T /usr/bin/security >/dev/null || fail \
    "could not import the local signing identity into the login keychain." \
    "Import the generated certificate manually, then re-run ./build.sh"
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v name="$SIGNING_NAME" '$2 == name {print $2; exit}')"
  [ -n "$SIGN_ID" ] || fail \
    "the self-signed certificate is not trusted for code signing yet." \
    "In Keychain Access, set its Code Signing trust to Always Trust, then re-run ./build.sh"
fi

echo "==> Codesigning with stable identity: $SIGN_ID"
codesign --force --deep --sign "$SIGN_ID" "$STAGED_BUNDLE"

# codesign can itself leave Finder/provenance attributes on the bundle on
# managed macOS volumes. Clear those signing-irrelevant attributes before the
# strict verification step as well.
xattr -cr "$STAGED_BUNDLE"

codesign --verify --strict "$STAGED_BUNDLE" || fail \
  "the assembled bundle failed signature verification." \
  "Remove dist/ and rebuild: rm -rf dist && ./build.sh"

# Move only after signing. Desktop-managed dist directories can carry Finder
# metadata that makes codesign reject an otherwise valid bundle.
mkdir -p "$DIST_DIR"
mv "$STAGED_BUNDLE" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE" || fail \
  "the final bundle failed signature verification after moving into dist." \
  "Remove dist/ and rebuild: rm -rf dist && ./build.sh"

echo "==> Done: $APP_BUNDLE"
echo "Run it with: open \"$APP_BUNDLE\""
# Guard against the stale-bundle trap. An older ad-hoc signed Voicy.app with the
# same bundle id is a DIFFERENT code identity to macOS, so Accessibility and
# Input Monitoring grants do not apply to it and auto-send silently degrades to
# "press Enter yourself". Launching the wrong copy cost a real debugging session.
if [ -e "$ROOT/build/Voicy.app" ]; then
  echo "==> WARNING: a second app bundle exists at build/Voicy.app"
  echo "    It is almost certainly stale and differently signed. Launching it"
  echo "    breaks auto-send. Use dist/Voicy.app. Renaming it out of the way."
  mv "$ROOT/build/Voicy.app" "$ROOT/build/Voicy.app.STALE-$(date +%s)"
fi

echo "==> Signature identity (Accessibility is keyed to this, not the app name):"
codesign -dv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/    /'
