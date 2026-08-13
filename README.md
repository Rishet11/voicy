<div align="center">

# Voicy

### Hold a key. Say it. It's sent.

**The fastest way to send a WhatsApp message on a Mac — without touching WhatsApp.**

*Fully on-device · Zero ban risk · Never rewrites your words*

</div>

---

## The problem nobody talks about

You're deep in a file. Focused. In flow.

Then you remember: *I need to tell Pulkit I'll be late.*

So you leave. You `Cmd+Tab` to WhatsApp. You scroll a list of 200 chats looking for one name. You type a sentence you could have said out loud in two seconds. You get pulled into three unread messages you didn't come for. Nine minutes later you come back to your editor and stare at the screen trying to remember what you were doing.

**You didn't lose nine minutes. You lost your flow, and that costs far more.**

And here's the part that stings: the average person has **47 unread texts** sitting in their phone right now. Not because they don't care. Because starting a reply is heavier than it should be. r/ADHD threads about this pull thousands of upvotes:

> *"It's not that I don't want to respond. My brain just freezes. The task of responding feels insurmountable even though I know logically it takes 30 seconds."*

Thirty seconds of typing. Blocked by the friction of getting there.

### So why hasn't a voice tool fixed this?

Because every dictation app on the Mac solves the wrong half of the problem.

SuperWhisper, Wispr Flow, macOS dictation — brilliant at turning speech into text. But they all stop at the same place: **they dump words into whatever box you're already looking at.**

None of them know *who* you're talking to.

You still have to switch apps. Still have to find the chat. Still have to lose your place. The typing got faster. **The interruption didn't go away.**

---

## The solution

**Voicy is the first Mac voice tool that knows who you mean.**

You never open WhatsApp. You never find the chat. You never leave what you're doing.

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
                   Delivered. You never left.
```

One key. One sentence. One glance to confirm. Done.

---

## Why this is genuinely hard (and why nobody did it)

Turning *"message Pulkit that I'll be late"* into a delivered WhatsApp message means solving four problems that each look easy and aren't.

### 1. Hearing a name correctly

Every speech engine on earth mangles Indian names. "Pulkit" becomes "Paul Kit". "Aarav" becomes "our". A dictation app can shrug this off, you'll fix the typo. **A messaging app cannot.** Get the name wrong and the message goes to the wrong person, or nowhere.

**What Voicy does:** it accepts that the recognizer will mangle the name and recovers afterwards. The mangled span is matched against your contacts orthographically and phonetically, so "Paul Kit" still resolves to Pulkit.

We tried biasing the recognizer instead, with Apple's `customizedLanguageModel` on both the legacy `SFSpeechRecognizer` path and the macOS 26 `DictationTranscriber` path. It does nothing. Pointing the API at a model file that does not exist produced no error and byte-identical transcripts on both engines, so the property is being ignored. Recognizer-side biasing is not what makes this work; the matcher is.

### 2. Knowing who you mean

You say "Pulkit". Your phone says "Stone". Nobody stores contacts the way they speak about them.

**What Voicy does:** fuzzy matching, phonetic matching, and a memory that learns. Correct it once and it never gets it wrong again. Two people named Rahul? It asks, instead of guessing — because a confidently wrong send destroys trust permanently, and there's no undo on WhatsApp.

### 3. Not butchering what you said

The loudest complaint about every AI dictation tool:

> *"I didn't like that in Wispr Flow they were changing my inputs."*

They pipe your words through a language model, and it silently "improves" your grammar. Your voice stops sounding like you.

**What Voicy does:** the parser returns *character positions*, not text. Your message body is sliced byte-for-byte out of what you actually said. Removing "um" is allowed. Rewriting a sentence is architecturally impossible.

It also means Hinglish just works. *"message Pulkit ki main kal aaunga"* — byte offsets don't care what language you're speaking.

### 4. Sending it without getting banned

This is where most people building this quietly fail.

Every WhatsApp automation library — `whatsapp-web.js`, `Baileys` — reimplements WhatsApp's protocol. WhatsApp detects that and **permanently bans accounts**, sometimes after 10 messages, with no human appeal. Their own READMEs warn you.

**What Voicy does:** it never speaks to WhatsApp's servers. Not once.

It hands macOS a `whatsapp://send` link — **WhatsApp's own documented feature**, the one they published for websites to use — which opens the real app with your message already typed. Then one keystroke sends it.

There is nothing to detect, because nothing unusual happened. A real user, in the real app, pressing a real key.

**Zero ban risk isn't a promise. It's architecture.**

---

## What makes it different

| | Voicy | Every other Mac voice tool |
|---|---|---|
| Knows who you're messaging | ✅ | ❌ dumps text in a box |
| Learns your names for people | ✅ correct once, remembers forever | ❌ |
| Your voice leaves your Mac | ❌ never | ⚠️ often cloud |
| Rewrites your words | ❌ impossible by design | ⚠️ commonly |
| Risk to your WhatsApp account | ❌ none | — |
| Works on 2 ordinary permissions | ✅ | ❌ Accessibility demanded up front |

---

## Privacy, stated plainly

Most apps say "we care about your privacy". Here is what Voicy actually does:

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

That's it. Voicy is fully usable — hotkey, transcription, contact matching, message pre-filled and ready.

**Two optional upgrades, one toggle each, in Settings:**

| Toggle | Unlocks |
|---|---|
| Hold a key to talk | Push-to-talk on a bare modifier key |
| Send without pressing Enter | Voicy presses Return for you |

Each toggle tells you exactly which macOS permission it needs and what you get. You opt in *after* you trust it — not before you've tried it.

---

## The feature WhatsApp won't ship

On **21 November 2024**, WhatsApp launched voice-message transcription. Free, on-device, brilliant.

**On phones only.**

Not the Mac app. Not WhatsApp Web. Over a year later, if you're working on a laptop and someone sends you a four-minute voice note, you still have to stop and listen to all four minutes.

Voicy reads voice notes already sitting on your own disk, decoding them locally. Your files, your machine, WhatsApp's servers never touched.

> ⚠️ **Status: in development, and not usable yet.** Decoding is verified on real Ogg-Opus voice notes from the WhatsApp container. Transcription is the blocker: the recognizer runs `en_US`, and the real notes we sampled were mostly Hindi and Punjabi, which come out as phonetic nonsense. It needs locale selection or language detection before it is worth shipping, and it is not wired into the UI. Everything above this section works today.

---

## Getting started

**Requirements:** macOS 26+, Apple Silicon, WhatsApp Desktop installed.

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
  (official         card              (character offsets,
   deep link)    (never steals         never regenerated)
                    focus)
```

**Built with:** Swift 6 · SwiftUI · AppKit · macOS 26 `SpeechAnalyzer` · `CNContactStore` · Carbon hotkeys · zero third-party dependencies.

---

## Honest status

Software READMEs usually oversell. Here's the real state.

**Working, tested on real hardware:**
- Push-to-talk, on-device transcription
- Contact resolution with fuzzy and phonetic matching, which recovers names the recognizer mangles
- Confirm card that never steals focus from your current app
- Message pre-filled in WhatsApp via the official deep link
- Learned aliases persisting across restarts
- Self-test reporting real permission and environment state

**In progress:**
- Auto-send (built and permission-gated, not yet exercised end to end)
- Latency tuning — currently ~1.1s to transcribe, targeting under 800ms
- Incoming voice-note transcription (decode verified, transcription is English-only and unusable on non-English notes, not wired to the UI)
- LLM-assisted cleanup for filler words and unusual phrasings

**Not there yet:**
- Notarized signed release build
- Telegram and iMessage support

---

<div align="center">

**Stop switching apps to send one sentence.**

MIT Licensed

</div>
