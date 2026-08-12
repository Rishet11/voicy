# Voicy — project constitution

Read this before touching anything. It is the contract every worker follows.

## What Voicy is

A macOS menubar app. Hold Right-Option, say "message Pulkit that I'll reach Bangalore tomorrow", and the message is sent on WhatsApp. Plus: incoming WhatsApp voice notes become readable text on the Mac, which WhatsApp itself refuses to ship on desktop.

Everything runs on-device. Nothing is uploaded. Nothing can get a WhatsApp account banned.

## Toolchain (verified on this machine, 2026-08-12)

- macOS 26 (Tahoe), target macOS 26+
- Swift 6.3.2, Xcode 26.5
- Swift Package Manager, no CocoaPods, no Xcode project file

Because this is macOS 26, prefer the CURRENT frameworks over the legacy ones:

| Use this | Not this | Why |
|---|---|---|
| `SpeechAnalyzer` / `SpeechTranscriber` | `SFSpeechRecognizer` | New in macOS 26, faster, better. Keep SFSpeechRecognizer only as a fallback. |
| `FoundationModels` (on-device LLM) | cloud LLM calls | Free, private, no model to ship |
| Swift 6 strict concurrency | `DispatchQueue` soup | Compiler-checked data races |

Verify every API against developer.apple.com before using it. Do not guess signatures. If an API turns out not to exist on this OS, say so in your report instead of inventing one.

## Verified facts. Do not re-litigate these.

1. `whatsapp://send?phone=<e164-no-plus>&text=<urlencoded>` opens WhatsApp Mac and **pre-fills the message**. Tested live.
2. Received voice notes are real, readable `.opus` files at
   `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/<chatid>/<x>/<y>/<uuid>.opus`
   Readable **without** Full Disk Access. Tested live.
3. Auto-send works by posting a synthetic Return with `CGEventPost` once the WhatsApp text field has focus.
4. Fn is capturable but has a 300-500ms system delay and pops the emoji picker. **Use Right-Option.**

## Hard rules

**Never shell out to `osascript`.** macOS attributes Accessibility permission to the responsible process in the launch tree, so the prompt lands on Terminal instead of Voicy and everything silently breaks. Use `CGEventPost` natively.

**Never rewrite the user's words.** The parser returns character offsets into the transcript; the message body is sliced byte-for-byte from what the user actually said. Generation never touches the body. This is a verified competitor complaint we are deliberately fixing.

**Never guess a recipient.** One clear match auto-resolves. Two close matches ask "Which Rahul?". A wrong send destroys trust permanently.

**Never store message content.** The alias store holds name mappings only. No message bodies, ever, in any file or log.

**Read-only on the WhatsApp container.** Never write, move, or delete anything inside it. Open any sqlite immutable.

**Do not fake anything.** No stub returning a canned transcript, no placeholder that pretends to send. If a piece cannot work, report it as broken. A demo that lies is worse than a feature that is missing.

**It must compile.** Run `swift build` and fix every error before reporting done.

**Do not git commit.** The orchestrator handles version control.

## File ownership. Do not cross these lines.

| Worker | Owns |
|---|---|
| W1 | `Package.swift`, `main.swift`, `AppDelegate.swift`, `Hotkey/`, `Audio/`, `Speech/`, `Info.plist`, `build.sh` |
| W2 | `Contacts/` |
| W3 | `UI/` |
| W5 | `Send/`, `Intent/` |
| W4 | `VoiceNotes/`, `Tools/vnwatch/` |

If you need a type you do not own, declare a `protocol` in your own directory and a stub conforming type so you compile standalone. The orchestrator wires the real implementations together.

## The latency budget

The whole loop must feel instant or the product is pointless, because typing is the competition.

| Stage | Budget |
|---|---|
| Key-down to recording indicator visible | 100ms |
| End of speech to transcript | 800ms |
| Transcript to confirm card | 200ms |
| Confirm to message sent | 1000ms |

Log real milliseconds at every stage. Guessing is not measuring.

## Definition of done

Not "the code exists". Done means: a person holds a key, speaks a sentence, and a real message arrives on someone's phone, with no manual step and nothing faked.

## PERMISSION MODEL (decided 2026-08-12, binding)

Voicy uses **progressive permissions**. Four dialogs on first launch is how you lose a user before they hear their first message send.

### Tier 1 — required, asked on first launch
- **Microphone** — we record your voice. Unavoidable.
- **Contacts** — turn "Pulkit" into a phone number.

With only these two, Voicy is FULLY FUNCTIONAL:
- Hotkey is **Ctrl+Space**, registered via Carbon (`RegisterEventHotKey` / the KeyboardShortcuts package). Carbon hotkeys need **no permission at all**.
- Send opens WhatsApp **pre-filled**; the user presses Enter themselves.

### Tier 2 — optional upgrades, each one toggle in Settings
Never asked at launch. Each toggle states plainly what it unlocks and what it grants.

- **"Hold a key to talk"** → grants **Input Monitoring**.
  Enables push-to-talk on a bare modifier (Right-Option) via `CGEventTap`. Required because Carbon cannot bind a lone modifier key.
- **"Send without pressing Enter"** → grants **Accessibility**.
  Enables the synthetic Return via `CGEventPost` that completes the send.

### Rules
- The app must WORK, end to end, with Tier 1 alone. Tier 2 is never a hard dependency.
- Every Tier-2 code path checks its permission at call time and degrades gracefully to the Tier-1 behaviour. Never crash, never silently do nothing.
- Each toggle shows: what it does, which macOS permission it needs, and a button that opens the exact System Settings pane.
- Revoking a permission later must degrade cleanly, not break the app.
- Speech Recognition authorization is Tier 1 only if we use Apple's engine. If we ship whisper.cpp it disappears entirely; keep that option open.
