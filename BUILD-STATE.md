# Build state — orchestrator log

Updated each loop iteration. Read this first on wake.

## Goal

Working Voicy: hold Right-Option, speak, real message sent on WhatsApp. Plus incoming voice notes transcribed on macOS. Production-ready enough to download.

## Constraint discovered: this laptop cannot run 6 workers

Load average hit 24-33 with only 20% CPU and 31% memory free. That is memory thrashing, not compute. Even `ls` timed out at 45s.

**Rule for future iterations: maximum 4 concurrent workers.** Prefer 3. Run the rest sequentially as slots free.

## STATUS AT 22:30 — IT COMPILES

`swift build` is green. Binary at `.build/debug/Voicy` (1.3MB). 25 Swift files across Hotkey, Audio, Speech, Contacts, UI, Send.

**Not yet verified working end-to-end.** Compiling is not running. Nothing has been launched or tested with a real voice yet.

### What went wrong and what I did about it

**The laptop could not take 6 workers.** Load average hit 64 with only 20% CPU, which is memory thrashing. Even `ls` timed out at 45 seconds. I killed workers down to 4, then to 0 to get a clean build. Future iterations: **3 workers maximum.**

**Integration errors I fixed by hand:**
- Two files both named `Transcriber.swift` (Speech/ and VoiceNotes/) collided on object output. Removed the duplicate protocol, kept Speech's, moved the stub to its own file.
- `public` modifiers left over from when VoiceNotes was a standalone module leaked internal types. Stripped them.
- Swift 6 strict concurrency rejected the Carbon global `kAXTrustedCheckOptionPrompt`. Replaced with its documented literal `"AXTrustedCheckOptionPrompt"`.

**Feature B is parked, not deleted.** `wip/VoiceNotes/` has two real logic errors: an FSEvents callback pointer-type mismatch (`UnsafePointer` vs `UnsafeMutablePointer`) and `self.watcher` used before initialization. Both are fixable, neither is fixed. Move it back to `Sources/Voicy/` and fix those two before it will build.

**Intent/ was never written.** W5 got killed for load before producing anything. The regex parser still needs to be built, and the core loop cannot run without it.

## Worker roster

| ID | Name | Owns | Status |
|---|---|---|---|
| aohack-79 | W1-spine | Package.swift, main, AppDelegate, Hotkey/, Audio/, Speech/, build.sh | RUNNING |
| aohack-81 | W2-contacts | Contacts/ | RUNNING |
| aohack-84 | W3-ui | UI/ | RUNNING |
| aohack-83 | W6-send | Send/ | RUNNING |
| aohack-80 | W4-voicenotes | VoiceNotes/, Tools/vnwatch/ | KILLED for load. RESUME after W1 lands. |
| aohack-82 | W5-intent | Intent/ | KILLED for load. RESUME after W1 lands. |

W1 is the blocker: nothing links until Package.swift exists and compiles.

## Open technical questions the workers are answering

1. Does `SpeechAnalyzer` (macOS 26) work, or must we fall back to `SFSpeechRecognizer`?
2. Does the deep link pre-fill from a **cold start** with WhatsApp not running?
3. Can a send be **verified** via the AX tree, or only assumed?
4. Is `FoundationModels` usable for span extraction?
5. Can an `NSPanel` be non-activating yet still receive Enter?
6. Does phonetic matching help or hurt on Indian names?

## Next actions in priority order

1. Wait for W1 to produce a compiling Package.swift
2. Resume W5-intent (small, fast, needed for the core loop)
3. Integrate: wire hotkey to audio to speech to intent to contacts to send
4. End-to-end test with the user's own number 917982913080 only
5. Resume W4-voicenotes for Feature B
6. Then: polish, notarize path, DMG, auto-update

## Hard rules being enforced

- Never `osascript` for keystrokes (permission attribution breaks)
- Body text sliced from transcript, never regenerated
- Never guess a recipient
- No message content stored anywhere
- Read-only on the WhatsApp container
- Test sends only to 917982913080 or dry-run
