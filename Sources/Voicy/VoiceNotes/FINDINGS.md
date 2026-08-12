# Opus decode findings

## Log
- Created FINDINGS.md
- Step 1: Found 3 .opus files (bounded per-chat-dir find, stopped at 3; copied to /tmp/opus_test/):
  - a.opus (14713 B) = group.net.whatsapp.WhatsApp.shared/Message/Media/111674149322971@lid/9/3/9305ae9a-f295-4afc-8d17-7bb1dcc1fb8e.opus
  - b.opus (70873 B) = group.net.whatsapp.WhatsApp.shared/Message/Media/111674149322971@lid/0/7/0712bf26-a59d-4722-92fc-5e51c1f14716.opus
  - c.opus (15143 B) = group.net.whatsapp.WhatsApp.shared/Message/Media/111674149322971@lid/8/5/85c97f48-6546-42fc-9e12-53677590f095.opus
- Step 2: `file` + `afinfo` raw output (all three are Ogg/Opus; afinfo parses them, exit 0):

```
=== file a.opus ===
a.opus: Ogg data, Opus audio, version 0.1, mono, 48000 Hz (Input Sample Rate)
=== file b.opus ===
b.opus: Ogg data, Opus audio, version 0.1, mono, 16000 Hz (Input Sample Rate)
=== file c.opus ===
c.opus: Ogg data, Opus audio, version 0.1, mono, 16000 Hz (Input Sample Rate)

=== afinfo a.opus ===
File:           a.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 6.420000 sec
audio bytes: 14408
audio packets: 54
audio packets split by non-audio data: 0, 0.0000%
bit rate: 17953 bits per second
packet size upper bound: 339
maximum packet size: 339
audio data file offset: 153
optimized
audio 307848 valid frames + 312 priming + 0 remainder = 308160
----
EXIT: 0

=== afinfo b.opus ===
File:           b.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 29.980000 sec
audio bytes: 69825
audio packets: 251
audio packets split by non-audio data: 0, 0.0000%
bit rate: 18632 bits per second
packet size upper bound: 332
maximum packet size: 332
audio data file offset: 153
optimized
audio 1438728 valid frames + 312 priming + 0 remainder = 1439040
----
EXIT: 0

=== afinfo c.opus ===
File:           c.opus
File type ID:   Oggf
Num Tracks:     1
----
Data format:     1 ch,  48000 Hz, opus (0x00000000) 0 bits/channel, 0 bytes/packet, 0 frames/packet, 0 bytes/frame
Channel layout: Mono
estimated duration: 6.500000 sec
audio bytes: 14841
audio packets: 55
audio packets split by non-audio data: 0, 0.0000%
bit rate: 18265 bits per second
packet size upper bound: 331
maximum packet size: 331
audio data file offset: 152
optimized
audio 311688 valid frames + 312 priming + 0 remainder = 312000
----
EXIT: 0
```

Key observation: afinfo (AudioToolbox AudioFile/ExtAudioFile API) recognizes "Oggf" file type and the opus codec, and reports valid frame counts and duration for all three files. This suggests AudioToolbox has Ogg-Opus read support on this OS (macOS 26). AVFoundation layer still needs direct verification.
- Step 3 prep: wrote Tools/vnwatch/scratch-opus/main.swift (attempts A/B/C, compiled standalone with swiftc, outside SwiftPM target paths).


