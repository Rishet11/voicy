# Voicy — build state

**Last updated:** 2026-08-13 01:20 IST, end of the first build session.
**Read this and `CLAUDE.md` before touching anything.**

---

## What Voicy is

macOS menubar app. Hold `Ctrl+Space`, say *"message Pulkit that I'll be late"*, and the message is sent on WhatsApp. Everything on-device. Zero WhatsApp ban risk, because it never talks to WhatsApp's servers — it uses their own published `whatsapp://send` deep link.

Repo: `https://github.com/Rishet11/voicy` (private), 37 commits, working tree clean.

---

## VERIFIED ON REAL HARDWARE — do not re-litigate these

1. **The deep link pre-fills.** `whatsapp://send?phone=<e164-no-plus>&text=<urlencoded>` opens WhatsApp Mac with the message typed and unsent. Tested live with WhatsApp already running. **UNVERIFIED: cold start** (WhatsApp not running).
2. **Voice notes are readable on disk.** Real `.opus` files at
   `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<chatid>/<x>/<y>/<uuid>.opus`
   266 chats, 1,492 files on the dev machine. Readable **without** Full Disk Access.
   A full recursive scan takes **13 seconds** — never do one. Top-level listing is 0.1s.
3. **`SpeechAnalyzer` (macOS 26) works** and is the primary engine. `SFSpeechRecognizer` is the fallback.
4. **Contact-name biasing works.** Passing contact names as recognition hints made it correctly hear "Stone". This is the single most important accuracy feature.
5. **The full loop runs end to end.** Voice → transcript → intent → contact → confirm card → WhatsApp pre-filled. Confirmed by the user with a screenshot.
6. **Fn key**: capturable via `flagsChanged`, but has a 300-500ms system delay and pops the emoji picker. **Use Right-Option.** Default remains `Ctrl+Space` (Carbon, zero permissions).

---

## Bugs found and fixed (each was non-obvious)

| Bug | Symptom | Fix |
|---|---|---|
| Mic audio never resampled | 48kHz audio labelled 16kHz → **empty transcripts** | Correct ratio-scaled output buffer + supply-once converter callback |
| `print()` block-buffered | Empty log file when run as `.app` → debugging blind | `setvbuf(stdout, nil, _IONBF, 0)` in `main.swift` |
| Parser ate the whole sentence | `"Message Stone, hello"` → "no message body" | Punctuation terminates the recipient name |
| Alias learning half-wired | Only learned from the ambiguous path | Learn on **every** confirmed send |
| Ad-hoc signing | macOS forgot all permissions on every rebuild | `build.sh` signs with the stable Apple Development identity |
| Self-test race | Successful media sample reported as timeout | Outer wait gets a grace margin over the inner deadline |

---

## Current status

### Works, tested
- Push-to-talk `Ctrl+Space` (Carbon, no permission)
- Mic capture, correct 16kHz mono conversion
- On-device transcription with contact-name hints
- Intent parsing with byte-exact body slicing
- Contact index (105 contacts), fuzzy + phonetic matching, E.164 normalization
- Confirm card, non-activating (never steals focus)
- WhatsApp deep link pre-fill
- Alias store persisting across restarts
- `--selftest` reporting real permission/environment state
- App bundle build with stable signing

### Built but NEVER EXECUTED
- **Auto-send.** `WhatsAppSender` posts a synthetic Return via `CGEventPost` after polling the AX tree for a focused composer, then verifies the composer emptied. Both required permissions are now granted on the dev machine. **This is the #1 thing to verify.**
- Ambiguous "Which Rahul?" flow
- Blocklist kill-switch
- Settings window and its two upgrade toggles
- `Cmd+E` edit-before-send
- Right-Option hold-to-talk

### Over budget
| Stage | Actual | Budget |
|---|---|---|
| Key-down → recording starts | **386ms** | 100ms |
| End of speech → transcript | **1069ms** | 800ms |

### Incomplete
- **Feature B** (incoming voice notes → text): module compiles, file format verified, **not wired to the UI**. Opus decoding never proven on a real file.
- **LLM cleanup** (`FoundationModels`) for filler words: started, worker killed mid-flight, code may be partial.
- **Name-last parsing** (`"send hello to Pulkit"`): started, worker killed mid-flight, may be partial. Currently the parser assumes the name follows the verb, so `"send hello to Pulkit"` resolves the recipient as "hello".

---

## Architecture

```
Sources/Voicy/
  main.swift              entry, unbuffers stdout, handles --selftest
  AppDelegate.swift       menubar status item
  Core/Pipeline.swift     THE WIRING — hotkey → audio → speech → intent → contacts → UI → send
  Hotkey/                 Carbon Ctrl+Space + optional CGEventTap Right-Option
  Audio/                  AVAudioEngine capture + 16kHz conversion
  Speech/                 Transcriber protocol, SpeechAnalyzer primary, SFSpeechRecognizer fallback
  Intent/                 transcript → {recipient, body span}. Body sliced, never regenerated.
  Contacts/               CNContactStore index, fuzzy/phonetic match, alias store, E.164
  Send/                   deep link, AX readiness polling, CGEventPost Return, blocklist, dry-run
  UI/                     recording pill, confirm card, non-activating panel, settings, theme
  VoiceNotes/             FSEvents watcher, opus decode, pipeline (NOT WIRED)
  Diagnostics/SelfTest    permission + environment report
```

**Key seam:** `protocol Transcriber { func transcribe(pcm: [Float], hints: [String]) async throws -> String }`
Any engine (whisper.cpp, Sarvam, cloud) drops in here without touching the pipeline.

---

## Hard rules (also in CLAUDE.md)

- **Never shell out to `osascript`** — macOS attributes Accessibility permission to the responsible process; the prompt lands on Terminal and everything silently breaks. Use `CGEventPost`.
- **Never rewrite the user's words.** Body is sliced from the transcript by character offset. Removing filler is allowed; rewording is not.
- **Never guess a recipient.** Ambiguous → ask. A wrong send is unrecoverable.
- **Never store message content** anywhere, including logs.
- **Read-only** on the WhatsApp container.
- **Never message anyone except `917982913080`** (the owner) or use dry-run.
- **Max 3 concurrent workers.** Six drove the load average to 64 on this MacBook Air until `ls` timed out.
- **Never run two git scripts at once.** Duplicate scripts deadlocked `.git/index.lock` and corrupted the index. If git hangs, check for `.git/index.lock` FIRST.

---

## The testing problem (critical for autonomous work)

**Voice input cannot be tested autonomously.** Nobody is available to hold a key and speak.

The fix is an **audio injection test harness**: pre-recorded WAV files fed directly into the pipeline, bypassing the microphone. Without it, an autonomous agent cannot verify anything past the hotkey. Build this first.

Everything downstream of audio (intent parsing, contact matching, deep link building, alias learning) is testable today with plain unit tests and needs no human.
