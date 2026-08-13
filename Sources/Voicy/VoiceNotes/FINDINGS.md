# Opus decode findings

## Log

- STEP 0: Started W-VOICENOTES. Found a pre-existing FINDINGS.md from an earlier probe; rewrote this file to the required format. Previous content preserved below under "## Reference (previous worker, headings demoted)".
- STEP 1: Drilled Media/120363028932810709@g.us/0/1/ (one dir at a time, no recursive scan): found 2 .opus files so far (10451 and 11267 bytes).
- STEP 2: Third file found in Media/120363028932810709@g.us/0/7/ (78769 bytes). All 3 copied OUT to /tmp/wvn_probe/ (a.opus, b.opus, c.opus). Container untouched.
- STEP 3: `file` and `afinfo` run on all 3 (raw output pasted into Step 2): Ogg container ("Oggf" per afinfo), codec opus, mono, 48 kHz decode rate, durations 4.72/5.08/34.62 s.
- STEP 4: Wrote standalone probe Tools/vnwatch/scratch-opus/wvn_probe.swift (attempts A/B/C). First swiftc compile exited 0 with 2 deprecation warnings (isPlayable, tracks(withMediaType:)); rewrote attempt B with the modern async load(.isPlayable) / loadTracks(withMediaType:) APIs.
- STEP 5: Probe ran on all 3 real files (raw output in Step 3). A (AVAudioFile) and B (AVAssetReader) DECODE all 3 to PCM with real frames and peaks ~1.0. C failed at AudioToolbox packet fetch with status -50 before reaching AVAudioConverter.

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

`file` says all three are Ogg containers wrapping Opus. `afinfo` parses them
("Oggf") and reports the codec as "opus". RAW OUTPUT, verbatim:

```
$ file /tmp/wvn_probe/a.opus /tmp/wvn_probe/b.opus /tmp/wvn_probe/c.opus
/tmp/wvn_probe/a.opus: Ogg data, Opus audio, version 0.1, mono, 16000 Hz (Input Sample Rate)
/tmp/wvn_probe/b.opus: Ogg data, Opus audio, version 0.1, mono, 16000 Hz (Input Sample Rate)
/tmp/wvn_probe/c.opus: Ogg data, Opus audio, version 0.1, mono, 16000 Hz (Input Sample Rate)

$ afinfo /tmp/wvn_probe/a.opus
File:           /tmp/wvn_probe/a.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 4.720000 sec
audio bytes: 8613
audio packets: 39
audio packets split by non-audio data: 0, 0.0000%
bit rate: 14598 bits per second
packet size upper bound: 320
maximum packet size: 320
audio data file offset: 151
optimized
audio 226248 valid frames + 312 priming + 3840 remainder = 230400
----

$ afinfo /tmp/wvn_probe/b.opus
File:           /tmp/wvn_probe/b.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 5.080000 sec
audio bytes: 8548
audio packets: 42
audio packets split by non-audio data: 0, 0.0000%
bit rate: 13461 bits per second
packet size upper bound: 326
maximum packet size: 326
audio data file offset: 156
optimized
audio 243528 valid frames + 312 priming + 3840 remainder = 247680
----

$ afinfo /tmp/wvn_probe/c.opus
File:           /tmp/wvn_probe/c.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 34.620000 sec
audio bytes: 77660
audio packets: 289
audio packets split by non-audio data: 0, 0.0000%
bit rate: 17945 bits per second
packet size upper bound: 363
maximum packet size: 363
audio data file offset: 154
optimized
audio 1661448 valid frames + 312 priming + 0 remainder = 1661760
----
```

Notes:
- Container = Ogg ("Ogg data, Opus audio, version 0.1" per `file`; "File type ID:
  Oggf" per `afinfo`). AVFoundation's historic stance is no Ogg support; whether
  macOS 26 changed that is exactly what Step 3 tests.
- Codec inside = Opus, mono. Opus always decodes to 48 kHz; `file`'s "16000 Hz
  (Input Sample Rate)" is the OpusHead original-input-rate field, while afinfo
  reports the 48000 Hz decode rate.
- Durations: 4.72 s, 5.08 s, 34.62 s.

## Step 3 — AVFoundation decode attempts

Probe: `Tools/vnwatch/scratch-opus/wvn_probe.swift`, compiled standalone with
`swiftc -o /tmp/wvn_probe/probe wvn_probe.swift` (exit 0, no warnings after
switching to the async asset APIs). Every API used below compiled against the
macOS 26 SDK on this machine, which verifies the signatures exist:

- `AVAudioFile` / `init(forReading:)` / `read(into:)` —
  https://developer.apple.com/documentation/avfaudio/avaudiofile ,
  https://developer.apple.com/documentation/avfaudio/avaudiofile/init(forreading:) ,
  https://developer.apple.com/documentation/avfaudio/avaudiofile/read(into:)
- `AVAssetReader`, `AVAssetReaderTrackOutput` —
  https://developer.apple.com/documentation/avfoundation/avassetreader ,
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
- `load(.isPlayable)`, `loadTracks(withMediaType:)` —
  https://developer.apple.com/documentation/avfoundation/avurlasset/load(_:) ,
  https://developer.apple.com/documentation/avfoundation/avasset/loadtracks(withmediatype:)
- `AVAudioConverter` / `init(from:to:)` —
  https://developer.apple.com/documentation/avfaudio/avaudioconverter
- `AudioFileOpenURL` (AudioToolbox) —
  https://developer.apple.com/documentation/audiotoolbox/audiofileopenurl(_:_:_:_:)
- `ExtAudioFileOpenURL` (AudioToolbox) —
  https://developer.apple.com/documentation/audiotoolbox/extaudiofileopenurl(_:_:)

RAW OUTPUT (probe run on the copies in /tmp/wvn_probe/):

```
$ /tmp/wvn_probe/probe /tmp/wvn_probe/a.opus
FILE: /tmp/wvn_probe/a.opus
=== A: AVAudioFile(forReading:) ===
A OK: fileFormat=<AVAudioFormat 0x1034dea90:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
A OK: processingFormat=<AVAudioFormat 0x1034dedd0:  1 ch,  48000 Hz, Float32>
A OK: length=226248 frames (4.7135 s)
A PCM: frames=224328 peak=0.9999695 nonSilent=203902/224328
=== B: AVURLAsset + AVAssetReader ===
B: isPlayable=true
B: audio track count=1
B RESULT: buffers=28 frames=226248 status=2 error=nil
=== C: AVAudioConverter from compressed input format ===
C: kAudioFilePropertyDataFormat status=0
C: compressed format=<AVAudioFormat 0xa4ed38140:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
C: packet count status=0 nPackets=39
C: packet table info status=0 size=16
C: total compressed bytes=3840
C: AudioFileReadPacketData status=-50 bytes=0 packets=39
C FAIL: AudioFileReadPacketData status=-50

$ /tmp/wvn_probe/probe /tmp/wvn_probe/b.opus
FILE: /tmp/wvn_probe/b.opus
=== A: AVAudioFile(forReading:) ===
A OK: fileFormat=<AVAudioFormat 0x1011dfdf0:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
A OK: processingFormat=<AVAudioFormat 0x1011e2840:  1 ch,  48000 Hz, Float32>
A OK: length=243528 frames (5.0735 s)
A PCM: frames=241608 peak=0.96640015 nonSilent=224022/241608
=== B: AVURLAsset + AVAssetReader ===
B: isPlayable=true
B: audio track count=1
B RESULT: buffers=30 frames=243528 status=2 error=nil
=== C: AVAudioConverter from compressed input format ===
C: kAudioFilePropertyDataFormat status=0
C: compressed format=<AVAudioFormat 0xa1ed38f00:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
C: packet count status=0 nPackets=42
C: packet table info status=0 size=16
C: total compressed bytes=3840
C: AudioFileReadPacketData status=-50 bytes=0 packets=42
C FAIL: AudioFileReadPacketData status=-50

$ /tmp/wvn_probe/probe /tmp/wvn_probe/c.opus
FILE: /tmp/wvn_probe/c.opus
=== A: AVAudioFile(forReading:) ===
A OK: fileFormat=<AVAudioFormat 0x10559ea90:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
A OK: processingFormat=<AVAudioFormat 0x10559edd0:  1 ch,  48000 Hz, Float32>
A OK: length=1661448 frames (34.6135 s)
A PCM: frames=1661448 peak=0.9579468 nonSilent=1386261/1661448
=== B: AVURLAsset + AVAssetReader ===
B: isPlayable=true
B: audio track count=1
B RESULT: buffers=203 frames=1661448 status=2 error=nil
=== C: AVAudioConverter from compressed input format ===
C: kAudioFilePropertyDataFormat status=0
C: compressed format=<AVAudioFormat 0xba4d38140:  1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame>
C: packet count status=0 nPackets=289
C: packet table info status=0 size=16
C: total compressed bytes=0
C: AudioFileReadPacketData status=-50 bytes=0 packets=289
C FAIL: AudioFileReadPacketData status=-50
```

Interpretation:
- **A works on all 3 files.** `AVAudioFile` reports `fileFormat` = 1 ch / 48000 Hz /
  opus, `processingFormat` = Float32 PCM, and `read(into:)` returns real decoded
  frames (224328, 241608, 1661448) with peaks ≈ 1.0 and mostly non-silent
  samples. This is genuine PCM decoded from real WhatsApp voice notes.
- **B works on all 3 files.** Asset is playable, 1 audio track, reader returns
  exactly the file's frame count (226248/243528/1661448) with
  `status=2` (AVAssetReaderStatus.completed) and `error=nil`.
- **C failed before reaching the converter**, at the packet-fetch plumbing:
  `kAudioFilePropertyPacketTableInfo` reports a size of 16 bytes (= one
  `AudioStreamPacketDescription`) for 39/42/289 packets, and
  `AudioFileReadPacketData` then returns **-50** (kAudio_ParamError) with 0 bytes
  read. The AudioToolbox AudioFile API's Ogg packet table is unusable here, so
  the raw-packet route into `AVAudioConverter` could not be fed. Error code -50
  is the exact error, recorded as-is. See C2 below for the converter tested via
  a different packet source.

## Step 4 — fallbacks (afconvert, ffmpeg, AudioToolbox)

(TO BE FILLED)

## Verdict

(TO BE FILLED)
