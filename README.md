<div align="center">

# Voicy

### Hold a key. Say it. Review and send.

**Send a WhatsApp message on a Mac without touching WhatsApp.**

*Fully on-device · No WhatsApp API · Review before sending*

</div>

---

## The problem

You remember: *I need to tell Pulkit I'll be late.* Dictation can turn that into text, but it does not choose the WhatsApp chat. You still switch apps and find the recipient.

---

## The solution

**Voicy is a Mac voice tool that resolves who you mean.**

It opens the matching WhatsApp chat with the message ready to review.

```
                     Hold Ctrl+Space
                            │
              "message Pulkit that I'll be late"
                            │
                            ▼
    ┌───────────────────────────────────────────┐
    │  🧑  Pulkit                                │
    │      +91 98*** 4*2*0                       │
    │                                            │
    │  MESSAGE                                   │
    │  ┌──────────────────────────────────────┐  │
    │  │ When are you coming to Delhi?        │  │
    │  └──────────────────────────────────────┘  │
    │                                            │
    │  ⏎ Send    esc Cancel    ⌘E Edit          │
    └───────────────────────────────────────────┘
                            │
                            ▼
                   Ready to send. You confirm.
```

Hold one key, speak one sentence, then confirm.

---

## Why it is hard

Turning *"message Pulkit that I'll be late"* into a delivered WhatsApp message means solving four problems that each look easy and aren't.

### 1. Hearing a name correctly

Apple's recognizer can mangle Indian names. In our clips, "Pulkit" became "Polkit", "Polka", or "Paul Kit". "Aarav" became "our ab". A messaging app cannot silently accept a wrong recipient.

**What Voicy does:** it accepts that the recognizer will mangle the name and recovers afterwards. The mangled span is matched against your contacts orthographically and phonetically, so "Paul Kit" still resolves to Pulkit.

Recognizer hints and custom language models did not change the measured transcripts. Voicy matches the name after recognition instead.

### 2. Knowing who you mean

You say "Pulkit". The recognizer may return something else. Voicy uses fuzzy and phonetic matching, learns corrected aliases, and asks when contacts are ambiguous.

### 3. Keep the message under your control

The parser returns *character positions*, and the message starts from the transcript slice. The live path uses deterministic formatting for spoken punctuation, entities, and corrections. Its disfluency pass is deletion-only and has no hardcoded filler-word list.

The on-device FoundationModels cleanup pass is not in the live path.

### 4. Sending it without a WhatsApp API

Voicy does not use a WhatsApp API or speak to WhatsApp's servers. It opens the real app with a `whatsapp://send` link that never brings WhatsApp to the foreground. After you confirm on Voicy's card, Voicy submits in the background: it presses WhatsApp's send button through the Accessibility API (with a Return delivered straight to WhatsApp's PID as fallback), only after the composer contains exactly the expected text, and it verifies the composer cleared before claiming a send. Otherwise it aborts with a named error and leaves the message prefilled unsent. A send goes to any contact you confirm; there is no fixed recipient list.

---

## What makes it different

| | Voicy | Every other Mac voice tool |
|---|---|---|
| Knows who you're messaging | ✅ | ❌ dumps text in a box |
| Learns corrected names | ✅ aliases persist | ❌ |
| Your voice leaves your Mac | ❌ never | ⚠️ often cloud |
| Uses a text-generation model in the live cleanup path | ❌ | ⚠️ varies |
| Works on 2 ordinary permissions | ✅ | ❌ Accessibility demanded up front |

---

## Privacy, stated plainly

- **Your voice never leaves your Mac.** Transcription runs on-device with Apple's Speech framework. There is no server. There is no API key. Airplane mode changes nothing.
- **Your messages are never stored.** Not in a log, not in a file, not anywhere. The only thing saved is a name mapping: *"Pulkit" → this contact.* Never message content.
- **Your contacts are never uploaded.** They're read into memory to match a name, and that's it.
- **It reads nothing it doesn't need.** No screen recording, no keylogging, no background listening. The microphone opens when you hold the key and closes when you let go.

---

## Permissions: two, not five

Most tools in this category demand Accessibility access before you've seen them do anything. Voicy doesn't.

**On first launch it asks for two things:**

| Permission | Why |
|---|---|
| 🎤 Microphone | To hear you |
| 👤 Contacts | To turn "Pulkit" into a phone number |

Voicy can record, transcribe, match a contact, and pre-fill a message.

**Two optional upgrades, one toggle each, in Settings:**

| Toggle | Unlocks |
|---|---|
| Hold a key to talk | Push-to-talk on a bare modifier key |
| Send without pressing Enter | Voicy presses Return for you |

Each toggle is optional and tells you which macOS permission it needs.

---

## Incoming voice notes

Voicy can decode real WhatsApp voice-note files locally. Transcription is not ready: the sampled notes were mostly Hindi and Punjabi, while the current recognizer runs `en_US`. This feature is not wired into the UI.

> **Status:** decoding works on real Ogg-Opus files. Language support is the blocker.

---

## Built with AO

Voicy was built inside [Agent Orchestrator](https://aoagents.dev/) during The Orchestra hackathon.

One orchestrator session held the Kanban board and the plan. Worker sessions ran in isolated git worktrees, so unrelated parts of the app moved in parallel without conflicts:

- **Speech pipeline** — `SpeechAnalyzer` streaming, live partials, latency measurement
- **Recipient resolution** — fuzzy and phonetic contact matching, learned aliases, the 72-case eval harness
- **Send path** — background Accessibility send, cold-start composer fallback, verification before claiming a send
- **Landing page and docs** — separate worktree, never blocked the app

What that setup actually changed:

- The on-device `FoundationModels` cleanup pass was benchmarked in its own session and cut, after warm calls measured 859-909 ms against a 250 ms budget. The deterministic rules-only cleaner stayed in the live path. Details in `Sources/Voicy/Cleanup/LLM-FINDINGS.md`.
- The send path was rewritten to read WhatsApp's Accessibility tree by PID and confirm the composer holds exactly the confirmed body before submitting, then verify the composer cleared. A mismatch aborts and reports `sentUnverified` instead of claiming success.
- Every accuracy and latency number in this README came from an eval session, not an estimate.

---

## Getting started

**Requirements:** macOS 26+, Apple Silicon, WhatsApp Desktop installed.

macOS 26 is a hard floor, and `Package.swift` now declares it. It previously
declared macOS 14, which was a support claim nobody had ever tested. Transcription
does have a real `SFSpeechRecognizer` fallback for older systems, and reading the
code suggests macOS 14 would transcribe, without the live partial transcript,
which has no fallback at all. That path has never been run on a macOS 14 or 15
machine, so it is not advertised. If you need older systems, that fallback is the
place to start, and it needs testing before anyone relies on it.

```bash
git clone https://github.com/Rishet11/voicy.git
cd voicy
./build.sh
open dist/Voicy.app
```

Grant Microphone and Contacts when asked. Look for the 🎤 in your menu bar.

**Then hold `Ctrl+Space` and say:**

> *"message [a friend's name] that this actually works"*

**Check everything is healthy:**

```bash
./dist/Voicy.app/Contents/MacOS/Voicy --selftest
```

Prints the real state of every permission, whether WhatsApp was found, and which speech engine you're running on.

---

## How it works

```
  Ctrl+Space  ──▶  Microphone  ──▶  On-device speech
   (Carbon,          (16 kHz          (SpeechAnalyzer,
  no permission)      mono)              en_US)
                                            │
                                            ▼
   WhatsApp   ◀──   Confirm    ◀──   Who + what
  (background       card              (character offsets,
   deep link)     (never steals         formatted locally)
                    focus)
```

**Built with:** Swift 6 · SwiftUI · AppKit · macOS 26 `SpeechAnalyzer` · `CNContactStore` · Carbon hotkeys · zero third-party dependencies.

---

## Honest status

Software READMEs usually oversell. Here's the real state.

**Working and measured:**
- Live streaming partials: text appears while you speak. Measured at 35 partials on a long utterance
- On-device transcription via Apple's Speech framework
- Latency targets met in the measured path: 317.7 ms end-of-speech tail against an 800 ms budget, and 38.7 ms prewarmed mic start against a 100 ms budget
- Recipient matching at 90.9% top-1 accuracy across a 72-case evaluation, with 100% correct refusal and 0.0% wrong-person sends
- Contact resolution with fuzzy and phonetic matching, plus learned aliases
- Confirm card that never steals focus from your current app
- Message pre-filled in WhatsApp via a deep link that never activates WhatsApp
- Auto-send after confirmation, fully in the background: Voicy presses WhatsApp's send button through the Accessibility API (PID-targeted Return fallback) once the composer holds exactly the expected text, then verifies the composer cleared. Any mismatch aborts with a named error and the message stays unsent; WhatsApp never takes focus
- Cold-start support: a 12-second readiness window covers WhatsApp launching from quit, with a direct composer-write fallback when the deep link's prefill has not landed
- Deterministic deletion-only disfluency cleanup in the live path, with no hardcoded filler list
- Self-test reporting real permission and environment state

**In progress:**
- Incoming voice-note transcription (decode verified, transcription is English-only and unusable on non-English notes, not wired to the UI)
- On-device FoundationModels cleanup, wired but disabled: warm calls measure 859-909 ms against a 250 ms budget, so the deterministic rules-only cleaner stays in the live path. Details in `Sources/Voicy/Cleanup/LLM-FINDINGS.md`

**Needs a human:**
- A real end-to-end send: whether the message actually arrives can only be confirmed by a person holding the key and speaking. Everything up to the posted Return is measured; delivery is not.

**Not there yet:**
- Notarized signed release build
- Telegram and iMessage support

---

<div align="center">

**Stop switching apps to send one sentence.**

MIT Licensed

</div>
