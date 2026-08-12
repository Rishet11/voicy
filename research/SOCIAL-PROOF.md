# Social proof: what people actually complain about

Gathered 2026-08-13 via web search. Every quote below is verbatim with a source
URL. Where nothing real was found, that is stated plainly rather than filled in,
because a fabricated quote on a public page is unrecoverable.

**Rule for the landing page: only quotes in this file may be used, and only with
attribution. Categories marked NOTHING FOUND must NOT be presented as if users
had complained.**

---

## 1. Tools rewording what you said (the strongest category)

> "dictation gets my words correct but then it decides I must mean something else"

andersonkl, https://discussions.apple.com/thread/251793781

> "some kind of stupid algorithm that is changing my words after they record correctly"

andersonkl, https://discussions.apple.com/thread/251793781

> "Wispr Flow never fixed a bug that bothers me immensely: If you say 'I want number one, number three, number five' (or any series of numbers) their dictation simply"

Nick Gray (@nickgraynews), https://x.com/nickgraynews/status/1995627585959497910
(User switched to Superwhisper over this.)

> "In their quest for 'context awareness,' Wispr Flow captures screenshots of your active window to 'understand' what you are doing."

Ryan Shrott, https://medium.com/@ryanshrott/why-i-cancelled-my-wispr-flow-subscription-and-what-im-using-instead-d783433f4411

**Why this matters:** Voicy's central guarantee is that the message body is
sliced character-for-character out of the transcript, so this class of failure
is structurally impossible. This is the differentiator to lead with.

---

## 2. Cloud upload, and demand for on-device

> "having an app constantly photographing your screen and sending that context to the cloud is a non-starter."

Ryan Shrott, https://medium.com/@ryanshrott/why-i-cancelled-my-wispr-flow-subscription-and-what-im-using-instead-d783433f4411

> "I want a microphone, not a surveillance tool."

Ryan Shrott, same source

> "Can everyone please stop using wispr flow superwhisper and whatever subscription app for your Mac please! Offline local models are now better than the ones they're charging you for."

deepfates (@deepfates), https://x.com/deepfates/status/2009295329057702081

**Why this matters:** validates the on-device choice as a feature people already
ask for by name, not a compromise.

---

## 3. WhatsApp desktop cannot transcribe received voice notes

> "WhatsApp's voice note transcription on desktop is either missing entirely or very inaccurate for me. It skips words, struggles with accents, and sometimes just isn't available at all — so I built a local alternative."

jpxoi (@jpxoi), https://www.threads.com/@jpxoi/post/DUEcd-7DDGL/whats-app-voice-note-transcription-on-desktop-is-either-missing-entirely-or

**Why this matters:** direct evidence that Feature B (incoming voice notes to
text) is a real unmet need, and that people resort to building their own.

Supporting architectural fact: "WhatsApp Web and WhatsApp Desktop have no
dictation built into the message box, the microphone button there only records
voice notes." https://voicekeyboardpro.com/blog/dictate-whatsapp-web.html

---

## 4. Is anyone already doing voice-to-WhatsApp on desktop?

**No.** Searched: `"voice to whatsapp" OR "dictate whatsapp" desktop app mac`,
`"voice to whatsapp" quicksend prefilled`.

What exists, and why none of it is the same thing:

| Tool | What it does | What it does not do |
|---|---|---|
| Willow, FluidVox, SnailText, Voice Keyboard Pro | System-wide voice-to-text that types into whatever field has focus, including WhatsApp's | No recipient resolution, no deep link, no confirm step |
| wa-transcriber (jpxoi) | Transcribes *received* voice notes | Does not send anything |
| macOS Dictation | Types into the focused field | No recipient, no pre-fill, no contact matching |

Nothing found that hotkey-triggers voice input aimed at WhatsApp, resolves the
recipient by name from the address book, pre-fills via deep link, and confirms
when the name is ambiguous. **This is a genuine gap, and the claim "nothing else
does this" is defensible** as long as it is scoped to desktop WhatsApp.

---

## 5. NOTHING FOUND (do not fake these)

**Dictation mangling Indian names / Hinglish.** Searched: `reddit dictation
indian names wrong`, `voice recognition hinglish`, `siri indian accent`,
`"indian english" speech recognition accuracy complaint`, `reddit "voice to
text" "indian names" wrong mispronounced`.

The *problem* is documented in third-party write-ups (examples given: Prabhas
transcribed as "piranhas", Mahesh as "makes"), but **no verbatim user
testimonial was found on Reddit, X, or Product Hunt.** So the landing page may
describe the problem in our own words, and must not imply a quoted user said it.

Voicy's own harness is better evidence here anyway: see BUILD-STATE.md for
measured transcripts where "Pulkit" came back as "Polkit"/"Polka" and "Aarav" as
"our ab". That is our own reproducible measurement, which is stronger than an
anecdote.

**WhatsApp Desktop typing being slow.** Searched: `reddit whatsapp desktop
typing slow`, `whatsapp desktop typing inefficient frustration`. No user
grievance posts found. Do not claim users complain about this; argue it from the
mechanics instead (no dictation in the message box, per the source above).

---

## Landing page usage plan

| Section | Quote to use |
|---|---|
| Hero / problem | "dictation gets my words correct but then it decides I must mean something else" |
| Why it is different | "some kind of stupid algorithm that is changing my words after they record correctly" |
| Privacy | "I want a microphone, not a surveillance tool." |
| Privacy | "having an app constantly photographing your screen and sending that context to the cloud is a non-starter." |
| On-device / FAQ | "Offline local models are now better than the ones they're charging you for." |
| Voice notes feature | the jpxoi quote in full |
