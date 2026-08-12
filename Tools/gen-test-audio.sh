#!/bin/bash
# Generates the audio-injection test clips from Tests/audio/manifest.tsv using
# the macOS `say` speech synthesizer.
#
# Why this exists: nobody can hold a hotkey and speak on demand, so the pipeline
# past the microphone was unverifiable. `say` gives us deterministic, regenerable
# speech, and the harness feeds it into the exact same 16 kHz mono Float32 seam
# the microphone produces.
#
# The WAVs are NOT committed (see .gitignore) because they are derived data and
# ~85 KB each. Run this once on a fresh clone.
#
#   Tools/gen-test-audio.sh            # generate anything missing
#   Tools/gen-test-audio.sh --force    # regenerate everything
set -euo pipefail

cd "$(dirname "$0")/.."

MANIFEST="Tests/audio/manifest.tsv"
OUT_DIR="Tests/audio"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: manifest not found at $MANIFEST" >&2
    exit 1
fi

generated=0
skipped=0
failed=0

# 16 kHz mono signed-little-endian Int16 in a WAVE container: exactly the
# analysis format, so no resampling happens on the test path either.
while IFS=$'\t' read -r name voice spoken _rest || [ -n "$name" ]; do
    case "$name" in
        ''|'#'*) continue ;;
    esac
    [ -z "${voice:-}" ] && continue
    [ -z "${spoken:-}" ] && continue

    out="$OUT_DIR/$name.wav"
    if [ -f "$out" ] && [ "$FORCE" -eq 0 ]; then
        skipped=$((skipped + 1))
        continue
    fi

    if say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 -o "$out" "$spoken" 2>/dev/null; then
        bytes=$(stat -f%z "$out")
        printf '  %-22s %-9s %7s bytes  "%s"\n' "$name" "$voice" "$bytes" "$spoken"
        generated=$((generated + 1))
    else
        echo "  FAILED $name (voice '$voice' may not be installed; install it in" \
             "System Settings > Accessibility > Spoken Content > System Voice)" >&2
        failed=$((failed + 1))
    fi
done < "$MANIFEST"

echo
echo "generated $generated, skipped $skipped (already present), failed $failed"
if [ "$failed" -gt 0 ]; then
    echo "Install the missing voices, or edit $MANIFEST to use a voice you have."
    exit 1
fi
