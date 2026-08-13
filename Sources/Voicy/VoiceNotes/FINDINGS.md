# Opus decode findings

## Log

- STEP 0: Started W-VOICENOTES. Found a pre-existing FINDINGS.md from an earlier probe; rewrote this file to the required format. Previous content preserved below under "## Reference (previous worker, headings demoted)".
- STEP 1: Drilled Media/120363028932810709@g.us/0/1/ (one dir at a time, no recursive scan): found 2 .opus files so far (10451 and 11267 bytes).
- STEP 2: Third file found in Media/120363028932810709@g.us/0/7/ (78769 bytes). All 3 copied OUT to /tmp/wvn_probe/ (a.opus, b.opus, c.opus). Container untouched.

## Reference (previous worker, headings demoted)

Previous probe's claims, preserved verbatim except headings (demoted so they do
not clash with this file's required sections). UNVERIFIED by me until I
reproduce each claim.

```
(prev) Feature B: can we decode WhatsApp voice notes? YES.

Answered 2026-08-13 by decoding a real file from the WhatsApp container.
Read-only throughout; the temporary copies used for probing were deleted.

(prev) Verdict: AVFoundation decodes Ogg-Opus natively on macOS 26

No third-party decoder, no ffmpeg, no bundled library. Tested against a real
voice note at
~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<chat>/<x>/<y>/<uuid>.opus

file:   Ogg data, Opus audio, version 0.1, mono, 48000 Hz
afinfo: File type ID: Oggf | Data format: 1 ch, 48000 Hz, opus | duration 6.42 s

A. AVAudioFile(forReading:) - WORKS.
processingFormat: 1 ch, 48000 Hz, Float32
fileFormat:       1 ch, 48000 Hz, opus
length:           307848 frames
read 307848 frames, peak amplitude 1.0

B. AVURLAsset + AVAssetReader - ALSO WORKS. 1 audio track, decoded to
16 kHz mono Float32, 102610 samples.

What this means for the code:
No new decoder is needed. Sources/Voicy/Testing/AudioFileLoader.swift
already does exactly the right thing: AVAudioFile then AVAudioConverter down
to the canonical 16 kHz mono Float32 that Transcriber consumes. Pointing it at
a .opus file works today, verified end to end:

audio    6.41 s, 102610 samples @16kHz, peak 0.999, rms 0.110
decode   45.5 ms

A synthetic Opus file with known English content transcribes correctly through
the same path, which proves the decode-to-transcript chain is sound:
afconvert -f caff -d opus of a test clip returned
"Message Pulkit, that I will reach Bangalore tomorrow."

The REAL blocker is language, not format:
Six real voice notes were sampled (redacted, content never printed or stored).
They are predominantly Hindi and Punjabi. Transcribed with the en_US model,
the output is phonetic nonsense. One 30-second note produced a long string of
unrelated tokens.

What Feature B needs before it is worth shipping:
1. Locale selection (SpeechTranscriber(locale:) supports more than en_US;
   enumerate supportedLocales and check hi-IN and pa-IN).
2. Language detection, or a per-chat locale preference.
3. Honest UI when confidence is low or locale unsupported.

How to re-run this probe:
./.build/debug/Voicy --test-audio <file.opus> --redact
```

## Step 1 — files found

3 real WhatsApp voice notes found by listing one directory at a time (never a
recursive scan). Paths relative to
`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/`:

1. `120363028932810709@g.us/0/1/0103057a-b1e5-4a77-bff3-f2150ea16c3a.opus` — 10,451 bytes
2. `120363028932810709@g.us/0/1/0162de27-c2f4-495c-b1ea-81e8727db961.opus` — 11,267 bytes
3. `120363028932810709@g.us/0/7/071dbcfb-4f14-4cf4-82fd-4caca56fb78c.opus` — 78,769 bytes

Copies for probing were made OUT of the container (read-only) to
`/tmp/wvn_probe/a.opus`, `/tmp/wvn_probe/b.opus`, `/tmp/wvn_probe/c.opus`.
Container untouched.

## Step 2 — container format (raw output)

(TO BE FILLED)

## Step 3 — AVFoundation decode attempts

(TO BE FILLED)

## Step 4 — fallbacks (afconvert, ffmpeg, AudioToolbox)

(TO BE FILLED)

## Verdict

(TO BE FILLED)
