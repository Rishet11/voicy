#!/bin/bash
# Builds a DEGRADED copy of the audio corpus, so accuracy is measured on
# something closer to a real room than to a synthesizer in a vacuum.
#
# Why this exists: every clip in Tests/audio is macOS `say` output. That audio
# is noiseless, perfectly paced, perfectly levelled and starts exactly on the
# first phoneme. A recognizer scores far better on it than on a person holding a
# hotkey in a kitchen, so a number measured only there overstates quality. This
# script takes each clean clip and produces the degradations that actually
# happen in use:
#
#   noise10   pink noise mixed in at roughly 10 dB SNR   (a room with a fan)
#   noise5    pink noise at roughly 5 dB SNR             (a bad room)
#   babble    two other voices talking underneath        (a cafe)
#   fast      1.25x speaking rate                        (a hurried user)
#   slow      0.85x speaking rate                        (a careful user)
#   quiet     -18 dB gain                                (mic far away)
#   clip50    first 50 ms removed                         (measured real loss)
#   clip100   first 100 ms removed                        (a slower device)
#   clipstart first 250 ms removed                       (capture began late)
#   trailsil  1.5 s of silence appended                  (user let go slowly)
#
# `clipstart` is the important one: it is the pre-roll bug reproduced on
# purpose. If the app starts the microphone after the keypress, the first
# syllable is gone, and this variant is what that costs.
#
# Everything stays 16 kHz mono LEI16, the analysis format, so nothing resamples
# on the way in.
#
#   Tools/gen-augmented-audio.sh          # generate anything missing
#   Tools/gen-augmented-audio.sh --force  # regenerate everything
set -euo pipefail

cd "$(dirname "$0")/.."

command -v ffmpeg >/dev/null || { echo "ERROR: ffmpeg required (brew install ffmpeg)" >&2; exit 1; }

SRC_DIR="Tests/audio"
OUT_DIR="Tests/audio/aug"
OUT_MANIFEST="$OUT_DIR/manifest.tsv"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$OUT_DIR"
[ "$FORCE" -eq 1 ] && rm -f "$OUT_DIR"/*.wav

FMT=(-ar 16000 -ac 1 -c:a pcm_s16le)

# A babble bed: two voices at once, longer than any clip, built once.
BABBLE="$OUT_DIR/.babble.wav"
if [ ! -f "$BABBLE" ] || [ "$FORCE" -eq 1 ]; then
    say -v Daniel --file-format=WAVE --data-format=LEI16@16000 -o "$OUT_DIR/.b1.wav" \
        "so anyway I told them the numbers were wrong and nobody wanted to hear it, which is fine, we can go over it again on Monday morning before the review, and then the quarter closes and none of this matters"
    say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$OUT_DIR/.b2.wav" \
        "did you see the thing about the trains, they cancelled the whole line for maintenance, so everyone is going to be late again tomorrow and there is nothing anybody can do about it at this point"
    ffmpeg -y -loglevel error -i "$OUT_DIR/.b1.wav" -i "$OUT_DIR/.b2.wav" \
        -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest" "${FMT[@]}" "$BABBLE"
    rm -f "$OUT_DIR/.b1.wav" "$OUT_DIR/.b2.wav"
fi

# Mean volume in dBFS, used to place noise at a chosen SNR instead of guessing.
mean_db() {
    ffmpeg -hide_banner -i "$1" -af volumedetect -f null /dev/null 2>&1 \
        | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}'
}

# mix_at_snr <speech> <noise> <snr_db> <out>
mix_at_snr() {
    local speech="$1" noise="$2" snr="$3" out="$4"
    local s n gain
    s=$(mean_db "$speech")
    n=$(mean_db "$noise")
    # Scale the noise so (speech - noise) ends up at the requested SNR.
    gain=$(awk -v s="$s" -v n="$n" -v snr="$snr" 'BEGIN {printf "%.2f", s - n - snr}')
    ffmpeg -y -loglevel error -i "$speech" -i "$noise" \
        -filter_complex "[1:a]volume=${gain}dB[n];[0:a][n]amix=inputs=2:duration=first:dropout_transition=0,volume=2.0" \
        "${FMT[@]}" "$out"
}

variant_for() {
    local src="$1" variant="$2" out="$3"
    case "$variant" in
        noise10)
            ffmpeg -y -loglevel error -f lavfi -t 60 -i "anoisesrc=c=pink:r=16000:a=0.5" \
                "${FMT[@]}" "$OUT_DIR/.pink.wav"
            mix_at_snr "$src" "$OUT_DIR/.pink.wav" 10 "$out" ;;
        noise5)
            mix_at_snr "$src" "$OUT_DIR/.pink.wav" 5 "$out" ;;
        babble)
            mix_at_snr "$src" "$BABBLE" 12 "$out" ;;
        fast)
            ffmpeg -y -loglevel error -i "$src" -filter:a "atempo=1.25" "${FMT[@]}" "$out" ;;
        slow)
            ffmpeg -y -loglevel error -i "$src" -filter:a "atempo=0.85" "${FMT[@]}" "$out" ;;
        quiet)
            ffmpeg -y -loglevel error -i "$src" -filter:a "volume=-18dB" "${FMT[@]}" "$out" ;;
        clip50)
            ffmpeg -y -loglevel error -ss 0.05 -i "$src" "${FMT[@]}" "$out" ;;
        clip100)
            ffmpeg -y -loglevel error -ss 0.10 -i "$src" "${FMT[@]}" "$out" ;;
        clipstart)
            ffmpeg -y -loglevel error -ss 0.25 -i "$src" "${FMT[@]}" "$out" ;;
        trailsil)
            ffmpeg -y -loglevel error -i "$src" \
                -filter:a "apad=pad_dur=1.5" "${FMT[@]}" "$out" ;;
        *) echo "unknown variant $variant" >&2; return 1 ;;
    esac
}

VARIANTS=(noise10 noise5 babble fast slow quiet clip50 clip100 clipstart trailsil)

: > "$OUT_MANIFEST.tmp"
{
    echo "# GENERATED by Tools/gen-augmented-audio.sh — do not hand edit."
    echo "# Degraded copies of Tests/audio. Column 3 is the reference text used"
    echo "# for WER scoring; it is identical to the clean clip's, because the"
    echo "# words spoken did not change, only the recording conditions did."
} >> "$OUT_MANIFEST.tmp"

made=0
skipped=0
# Pink noise is regenerated on the first noise10 of the run and reused; make
# sure it exists even if every noise10 is skipped.
[ -f "$OUT_DIR/.pink.wav" ] || ffmpeg -y -loglevel error -f lavfi -t 60 \
    -i "anoisesrc=c=pink:r=16000:a=0.5" "${FMT[@]}" "$OUT_DIR/.pink.wav"

for manifest in "$SRC_DIR/manifest.tsv" "$SRC_DIR/hard-manifest.tsv"; do
    [ -f "$manifest" ] || continue
    while IFS=$'\t' read -r name voice spoken _rest || [ -n "${name:-}" ]; do
        case "${name:-}" in ''|'#'*) continue ;; esac
        [ -z "${spoken:-}" ] && continue
        src="$SRC_DIR/$name.wav"
        [ -f "$src" ] || { echo "  skip $name (no clean clip; run Tools/gen-test-audio.sh)" >&2; continue; }
        for variant in "${VARIANTS[@]}"; do
            out="$OUT_DIR/$name.$variant.wav"
            if [ -f "$out" ] && [ "$FORCE" -eq 0 ]; then
                skipped=$((skipped + 1))
            else
                variant_for "$src" "$variant" "$out"
                made=$((made + 1))
            fi
            printf '%s\t%s\t%s\n' "$name.$variant" "$voice" "$spoken" >> "$OUT_MANIFEST.tmp"
        done
    done < "$manifest"
done

mv "$OUT_MANIFEST.tmp" "$OUT_MANIFEST"
rm -f "$OUT_DIR/.pink.wav"
echo "generated $made, skipped $skipped (already present)"
echo "manifest: $OUT_MANIFEST"
