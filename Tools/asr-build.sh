#!/bin/bash
# Builds the Voicy binary for ASR measurement without being blocked by another
# worker's half-finished edits elsewhere in the tree.
#
# Why this exists: several agents edit this repo at once. Twice now, an ASR
# measurement run silently used a STALE binary because the build had failed on
# a sibling's in-progress file (Diagnostics/SelfTest.swift referencing functions
# they had not written yet). A stale binary produces numbers that look real and
# are not. That is the single most dangerous failure mode in this work.
#
# What it does:
#   1. Builds the real tree first. If that succeeds, nothing else happens and
#      the binary is the honest one.
#   2. If it fails, it mirrors the tree into a scratch copy, reverts ONLY the
#      directories this worker does not own to their committed state, and
#      builds that. It prints loudly which files were reverted, so the
#      provenance of any number produced from this binary is on the record.
#
# It never edits the real working tree and never touches another worker's files.
#
#   Tools/asr-build.sh            # build, print the binary path on stdout
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SCRATCH="$ROOT/.build-asr"
MIRROR="$ROOT/.build-asr-tree"

if swift build --scratch-path "$SCRATCH" >/tmp/voicy-asr-build.log 2>&1; then
    echo "BUILT_FROM=working-tree" >&2
    echo "$SCRATCH/debug/Voicy"
    exit 0
fi

echo "==> working tree does not compile; see /tmp/voicy-asr-build.log" >&2
grep -E "error:" /tmp/voicy-asr-build.log | sed 's/^/    /' | sort -u | head -20 >&2

# Which files are dirty and NOT owned by the ASR worker?
FOREIGN=$(git diff --name-only HEAD -- Sources Tests Tools \
    | grep -v -E '^(Sources/Voicy/(Speech|Audio|Testing)/|Tools/|Tests/audio/)' || true)
if [ -z "$FOREIGN" ]; then
    echo "==> the failure is in ASR-owned code. Fix it, do not work around it." >&2
    exit 1
fi

echo "==> mirroring the tree and reverting sibling-owned files to HEAD:" >&2
echo "$FOREIGN" | sed 's/^/    /' >&2

rm -rf "$MIRROR"
mkdir -p "$MIRROR"
# Copy the working tree, excluding build products.
rsync -a --exclude '.build*' --exclude 'dist' --exclude '.git' "$ROOT/" "$MIRROR/"
cp -R "$ROOT/.git" "$MIRROR/.git"
(cd "$MIRROR" && echo "$FOREIGN" | tr '\n' '\0' | xargs -0 git checkout HEAD -- 2>/dev/null || true)

if ! swift build --package-path "$MIRROR" --scratch-path "$MIRROR/.build" >/tmp/voicy-asr-build-mirror.log 2>&1; then
    echo "==> mirror build ALSO failed; see /tmp/voicy-asr-build-mirror.log" >&2
    grep -E "error:" /tmp/voicy-asr-build-mirror.log | sed 's/^/    /' | sort -u | head -20 >&2
    exit 1
fi

echo "BUILT_FROM=mirror-with-siblings-reverted" >&2
echo "$MIRROR/.build/debug/Voicy"
