#!/bin/bash
# Builds Voicy and assembles a proper .app bundle (needed so macOS permission
# prompts attach to the bundled process), then ad-hoc codesigns it.
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
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
BIN_DIR="$APP_BUNDLE/Contents/MacOS"
RES_DIR="$APP_BUNDLE/Contents/Resources"

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
rm -rf "$APP_BUNDLE"
mkdir -p "$BIN_DIR" "$RES_DIR"

cp "$BIN" "$BIN_DIR/$APP_NAME"
cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# The dist dir may carry environment provenance/Finder xattrs that make
# `codesign --strict --deep` fail; strip them before signing.
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Sign with a STABLE identity. Ad-hoc signing (--sign -) mints a new code
# identity on every build, so macOS treats each rebuild as a different app and
# silently drops every TCC permission the user already granted (Contacts,
# Accessibility, Input Monitoring). Using the developer certificate keeps one
# identity across builds, so grants persist. Falls back to ad-hoc if the
# certificate is unavailable, so the script still works on another machine.
SIGN_ID="${VOICY_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$SIGN_ID" ]; then
  echo "==> Codesigning with stable identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"
else
  echo "==> WARNING: no signing identity found; falling back to ad-hoc."
  echo "    Permissions will reset on every rebuild."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

codesign --verify --strict "$APP_BUNDLE" || fail \
  "the assembled bundle failed signature verification." \
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
