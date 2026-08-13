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

OUT_DIR="Tests/audio"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Two manifests: the pass/fail pipeline suite, and the hard cases that exist
# only to be scored for WER.
MANIFESTS=("Tests/audio/manifest.tsv" "Tests/audio/hard-manifest.tsv")

generated=0
skipped=0
failed=0

for MANIFEST in "${MANIFESTS[@]}"; do
if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: manifest not found at $MANIFEST" >&2
    exit 1
fi

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
        # `say` exits 0 even when the voice cannot actually synthesize. The
        # Siri-backed "Aman" voice on this machine returns success and writes a
        # 4.2 KB stub (0.13 s of nothing) for any input. A silent clip scores as
        # a total transcription failure and would look like an engine
        # regression, so refuse to accept one. 16 kHz 16-bit mono is 32000
        # bytes per second; require at least 30 ms of audio per character.
        min_bytes=$(( ${#spoken} * 960 ))
        [ "$min_bytes" -lt 16000 ] && min_bytes=16000
        if [ "$bytes" -lt "$min_bytes" ]; then
            echo "  FAILED $name: voice '$voice' wrote $bytes bytes for ${#spoken} characters" \
                 "(expected >= $min_bytes). The voice is installed but not working;" \
                 "pick another one for this row." >&2
            rm -f "$out"
            failed=$((failed + 1))
            continue
        fi
        printf '  %-22s %-9s %7s bytes  "%s"\n' "$name" "$voice" "$bytes" "$spoken"
        generated=$((generated + 1))
    else
        echo "  FAILED $name (voice '$voice' may not be installed; install it in" \
             "System Settings > Accessibility > Spoken Content > System Voice)" >&2
        failed=$((failed + 1))
    fi
done < "$MANIFEST"
done

echo
echo "generated $generated, skipped $skipped (already present), failed $failed"
if [ "$failed" -gt 0 ]; then
    echo "Install the missing voices, or edit $MANIFEST to use a voice you have."
    exit 1
fi
