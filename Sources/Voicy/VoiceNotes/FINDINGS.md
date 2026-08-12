# Feature B: can we decode WhatsApp voice notes? YES.

Answered 2026-08-13 by decoding a real file from the WhatsApp container.
Read-only throughout; the temporary copies used for probing were deleted.

## Verdict: AVFoundation decodes Ogg-Opus natively on macOS 26

No third-party decoder, no ffmpeg, no bundled library. Tested against a real
voice note at
`~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<chat>/<x>/<y>/<uuid>.opus`

```
file:   Ogg data, Opus audio, version 0.1, mono, 48000 Hz
afinfo: File type ID: Oggf | Data format: 1 ch, 48000 Hz, opus | duration 6.42 s
```

**A. `AVAudioFile(forReading:)` — WORKS.**
```
processingFormat: 1 ch, 48000 Hz, Float32
fileFormat:       1 ch, 48000 Hz, opus
length:           307848 frames
read 307848 frames, peak amplitude 1.0
```

**B. `AVURLAsset` + `AVAssetReader` — ALSO WORKS.** 1 audio track, decoded to
16 kHz mono Float32, 102610 samples.

## What this means for the code

**No new decoder is needed.** `Sources/Voicy/Testing/AudioFileLoader.swift`
already does exactly the right thing: `AVAudioFile` then `AVAudioConverter` down
to the canonical 16 kHz mono Float32 that `Transcriber` consumes. Pointing it at
a `.opus` file works today, verified end to end:

```
audio    6.41 s, 102610 samples @16kHz, peak 0.999, rms 0.110
decode   45.5 ms
```

A synthetic Opus file with known English content transcribes correctly through
the same path, which proves the decode-to-transcript chain is sound:
`afconvert -f caff -d opus` of a test clip returned
"Message Pulkit, that I will reach Bangalore tomorrow."

## The REAL blocker is language, not format

Six real voice notes were sampled (redacted, content never printed or stored).
**They are predominantly Hindi and Punjabi.** Transcribed with the `en_US`
model, the output is phonetic nonsense: English-looking words that are not what
was said. One 30-second note produced a long string of unrelated tokens.

So Feature B is not blocked on decoding, which works. It is blocked on **locale
selection**, and shipping it English-only would produce confidently wrong text
for the notes this user actually receives. That is worse than not shipping it.

## What Feature B needs before it is worth shipping

1. Locale selection. `SpeechTranscriber(locale:)` supports more than `en_US`;
   enumerate `SpeechTranscriber.supportedLocales` and check hi-IN and pa-IN.
2. Language detection, or a per-chat locale preference, since a single user
   receives notes in several languages.
3. Honest UI. When confidence is low or the locale is unsupported, say so rather
   than showing a plausible-looking wrong transcript.

## How to re-run this probe

Use the harness with `--redact` so real message content is never printed:
```
./.build/debug/Voicy --test-audio <file.opus> --redact
```
