# SLOP-AUDIT — landing/index.html + landing/styles.css

Audited 2026-08-13 against the page at commit `c72dfdc` ("rebuild landing page,
editorial not templated"). Line numbers refer to that version.

## Context, stated up front

This page had already had one de-slop pass. The obvious tells are gone: there
are no purple-to-pink gradients, no glassmorphism, no gradient text, no fake
testimonials, no logo wall, no invented user counts, no emoji-topped card
triplets, no em-dashes. Saying otherwise would be theatre.

What is left is subtler and, for a reader with taste, worse: the page has the
*cadence* of a machine even though the individual sentences are good. Below is
every offender I could name.

---

## A. Copy: the cadence problem (the biggest single tell)

**A1. Every section heading is the same joke told seven times.** Each one is a
full declarative sentence, roughly the same length, ending in a period, with a
built-in twist:

| Line | Heading | Shape |
|---|---|---|
| 74 | "Every dictation tool solves the wrong half of this." | contrarian reveal |
| 87 | "One key, one sentence, one glance to confirm." | rule of three |
| 116 | "Two rules, both structural, not marketing." | not-X-but-Y |
| 164 | "Incoming voice notes become readable text." | declarative |
| 190 | "Plain statements, not a policy page." | not-X-but-Y |
| 215 | "Two permissions up front, nothing else." | not-X-but-Y |
| 243 | "Questions worth answering plainly." | self-congratulating |

Three of seven are literally "not X, but Y", which is the single most-cited AI
copy tell. Four of seven open with a number word ("One", "Two", "Two", "Every").
A human writing team writes headings of *unequal* length because each one is
solving a different local problem. Uniform wit across a whole page is generation,
not writing.

**A2. Self-praising adverbs.** "answering plainly" (243), "Plain statements"
(190), "both structural, not marketing" (116), "Honestly:" (170). The page keeps
telling you it is honest. Honest pages just state the fact and let you notice.
"Honestly:" as a sentence opener is a tell in its own right.

**A3. Quote padding.** Six pull quotes on one page (79, 126, 148, 167, 202, 205).
Ryan Shrott is quoted **three separate times** (148, 202, 205) and two of those
sit stacked in the same column making the same point. Anderson KL is quoted
**twice** (79, 126) with near-identical text. That is not evidence, that is a
research doc that got CSS applied to it. Real product pages use one quote, or
none.

**A4. Filler transitions.** "And the tools that do get you typing faster
introduce a new failure:" (76) and "Some competitors take the opposite
approach:" (146) exist only to hand off to a quote.

**A5. The hero has two ledes.** Lines 33 and 34 are both ~40-word paragraphs.
The first is a mini-story ("You're mid-file..."), the second restates the pitch.
A person cuts one.

---

## B. Fabrication and overclaim (the serious findings)

**B1. FALSE CLAIM, must be deleted. Lines 100 and 267 say contact-name
biasing works.**
- L100: "Your contacts load before you speak, so matching is biased toward names
  that matter to you."
- L267: "Voicy loads your contacts before you speak and biases matching toward
  the roughly 100 names that actually matter to you"

`BUILD-STATE.md` §CORRECTIONS #1 says the opposite, and says it was measured:
> "Contact-name biasing does NOT work. ... Proven by A/B: the same clips
> transcribed with and without contact-name hints produce byte-identical
> transcripts."

Three separate mechanisms (`contextualStrings`, `en_IN` locale, a custom
`SFSpeechLanguageModel`) were implemented and all three did nothing. The thing
that actually works is post-recognition fuzzy/phonetic matching plus alias
learning. The page is currently claiming a feature the codebase proved does not
exist. This is the worst thing on the page and it is not a style problem.

**B2. Overclaim on voice notes. Line 170** says the module "reads voice note
files already on your disk and turns them into text you can scan in seconds"
and that "the file format is verified on real data". The decode half is true
(`VoiceNotes/FINDINGS.md`: `AVAudioFile` decoded 307,848 frames off a real
`.opus`, peak 1.0). The transcription half is not: BUILD-STATE says six sampled
real voice notes were Hindi and Punjabi and "the `en_US` model turns them into
confident nonsense", and that shipping it English-only "would produce
plausible-looking wrong text". The page tells you the wiring is missing but not
that the *language* is the blocker, which is the honest and more interesting
half.

**B3. Vanity metric in the hero stat band. Line 66:** "128 + 22 unit checks +
audio regression clips". The number is real, but test count is a number a
product team never puts on a landing page, because it measures effort, not the
reader's outcome. Its presence next to two genuine latency numbers is what
makes the whole band read as generated.

**B4. Unstated caveat.** Auto-send is on the page implicitly (the confirm card,
the Settings toggle at 232) but BUILD-STATE lists auto-send under "Still NEVER
EXECUTED (needs a human)". The page should not hide that.

**B5. "MIT licensed" (279, 290) with no `LICENSE` file in the repo.** README
line 256 asserts MIT. Flagged for the orchestrator: add the file or drop the
claim. Kept on the page for now because it is the author's stated licence.

---

## C. Structure: still the template, restyled

**C1. Section order is the stock landing-page skeleton.** hero → stat band →
problem → how-it-works-1-2-3 → why-different → feature → privacy → permissions
→ FAQ → footer. Restyling a template is not replacing it. The "how it works"
numbered 1-2-3 (88-110) is the most template-shaped block on the page.

**C2. Uniform vertical rhythm.** Every section is `.section` with
`padding-block: var(--space-9)` (styles.css 315) and a `border-top`. Nine
sections, nine identical horizontal rules, nine identical gaps. Real pages have
one or two sections that are visibly *bigger* than the rest because they matter
more. Here nothing is emphasised, so nothing is.

**C3. Two-column split, six times.** `.hero-grid` (1.15/0.85), `.problem-grid`
(1.4/1), `.rule-grid` (0.8/1.2), `.detail-list` (1/1), `.voicenotes-grid`
(1.15/0.85), `.privacy-grid` (1.2/1). Six near-identical asymmetric splits is
just symmetry with extra steps. Two of them use the *same* ratio.

**C4. Missing: a pitch/judging section entirely.** Required by the task and
absent.

---

## D. Visuals

**D1. No typographic idea at all.** styles.css:16 is
`-apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif`, i.e. the
default. Every heading is `font-weight: 800` (105) with tightened tracking. That
is the house style of every generated page in existence. Mono is used only as
decoration (kickers, labels) rather than to mean anything.

**D2. All-caps tracked mono labels used four times** for four unrelated things:
`.confirm-label` (253), `.vn-label` (426), `.toggle-table caption` (466),
`.status-tag` (406). A label style used everywhere labels nothing.

**D3. Radii are a random walk**: `3px` buttons, `5px` kbd, `6px` message,
`8px` mock, `10px` card, `50%` dot, `4px` skip-link, `1px` waveform bars. Not
uniform (good) but not systematic either (bad). It reads as accumulated, not
decided.

**D4. Decorative motion.** The `LIVE` pulse (286) animates forever in a static
mockup of a moment that lasts under a second. `translateY(-1px)` on button
hover (173) is the default generated micro-interaction.

**D5. The green is undercommitted.** `--accent: #1f5c3f` appears as a 3px quote
border, a timeline number, a link hover, and a button fill. Five small doses of
one colour spread thin reads as timid rather than restrained.

**D6. `overflow-wrap: anywhere` on `p`, `h1`, `h2`, `code`, `kbd`** (116, 121,
127, 131, 142). This was a mobile-overflow bandage. It will break words
mid-syllable on narrow columns. The real fix is layout, not word-shredding.

**D7. `body { overflow-x: hidden }`** (93) hides horizontal overflow rather than
preventing it. BUILD-STATE flags this exact line as having masked a real 390px
bug.

---

## E. Accessibility (what is already right, so it survives the rewrite)

Genuinely good and must be preserved: skip link (11), `:focus-visible` rings
(156), `aria-labelledby` on every section, `<caption>` on the table, real
`<th scope>`, `prefers-reduced-motion` block (527), `aria-hidden` on decorative
mockups, `<details>` for FAQ (no JS).

Gaps: `.stat-band` uses `role="group"` on a `div` that contains no interactive
content (62, pointless). Dark-mode tokens live only inside
`@media (prefers-color-scheme: dark)` with no `[data-theme]` escape, which is
fine for a static page but means light/dark cannot be checked without changing
OS settings.

---

## F. Research: what real product sites actually do

Fetched 2026-08-13. Verbatim headings, in page order.

**Screen Studio** (screen.studio) — "Beautiful Screen Recordings in Minutes";
sections: "Automatic zoom for engaging screen recordings", "Professional
animations by default", "Add your style and branding", "Record webcam,
microphone, and system audio", "Export & Share. Smooth and easy."

**Linear** (linear.app) — "The product development system for teams and agents";
sections: "Make product operations self-driving", "Define the product
direction", "Move work forward across teams and agents", "Review PRs and agent
output", "Understand progress at scale".

**Raycast** (raycast.com) — "Your shortcut to everything."; sections: "There's
an extension for that.", "Your Mac just got smarter.", "Don't repeat yourself.",
"Stay in the loop.", "Take the short way."

**Superwhisper** (superwhisper.com) — "Just speak. Write faster. Turn your voice
into polished text."; sections: "Works in Slack, Gmail and any other site or
app.", "Adaptability", "What's inside", "Integrations", "What people say".

### What they do

1. **Headings are short and name a capability.** Linear's are 27-42 characters
   and are *verb phrases about the product*, not observations about the world.
   Ours average ~45 characters and are observations. Linear's "Define the
   product direction" is boring on purpose so the screenshot next to it can be
   interesting.
2. **The hero is a product visual, usually moving.** Screen Studio and Linear
   both put the artefact first and the argument second.
3. **Heading punctuation is a deliberate house style, applied consistently.**
   Raycast periods everything; Linear periods almost nothing. Ours mixes. Pick
   one.
4. **Feature sections alternate text/visual and vary in height.** Not nine equal
   bands.
5. **The one thing the tool does better than anything else gets a whole screen.**

### What they do NOT do

1. **They do not quote strangers.** Zero of the four uses a scraped forum
   complaint as a pull quote. Superwhisper has testimonials, but they are its
   own users, named, with permission. Quoting a stranger's Apple Support post to
   attack a competitor reads as a research artefact, not a product page.
2. **They do not lead with benchmarks.** No latency numbers above the fold on
   any of the four. Screen Studio never shows one.
3. **They do not print test counts.** Obviously.
4. **They do not write a paragraph before showing the product.** Ours writes
   two.
5. **Superwhisper is the cautionary example, not the model**: "seamlessly
   integrated", "Loved by thousands", "hundreds of thousands rely on" is exactly
   the register to avoid.

---

## G. Fix list, ordered by how much it changes the reader's impression

1. Delete the false contact-biasing claim; replace with alias learning, which is
   the thing that actually works. **(correctness, not style)**
2. Rewrite the voice-note section to say decode-proven / language-blocked.
3. Rewrite all section headings as short capability phrases, unequal in length,
   one punctuation style, zero "not X but Y".
4. Cut six pull quotes to one. Delete both duplicate Shrott quotes and the
   duplicate andersonkl quote.
5. Introduce one typographic idea: system serif (`ui-serif` = New York on macOS)
   for prose and headings, mono reserved strictly for machine output and
   measurements. Serif = what a person wrote. Mono = what the machine heard.
   Zero external assets, so the no-build-step rule holds.
6. Break the uniform rhythm: one oversized section (the transcript demo), the
   rest tighter.
7. Move latency numbers out of the hero and into the pitch, where a number
   belongs next to its method.
8. Delete the test-count stat.
9. Add the pitch section (problem, who, what, demo, trust posture, what we did
   not build, what is unproven).
10. Fix `overflow-x: hidden` and `overflow-wrap: anywhere` by fixing layout.
11. Keep every accessibility feature listed in §E.

---

# H. WORD BUDGET

Added after the human's verdict on the rebuilt page: **"the website is tooo
wordayyy!!!"** and "completely change the design". The visual direction is being
decided elsewhere. This section is the part that survives any direction, because
no layout saves 1,491 words of body copy.

## H1. Current count

Counted from the committed `index.html` (tags stripped, entities decoded).

| Section | Words | Budget at ~1/3 |
|---|---:|---:|
| head + nav | 25 | 8 |
| Hero | 122 | 41 |
| The slice (mechanism) | 137 | 46 |
| Problem | 117 | 39 |
| Names | 235 | 78 |
| Two rules | 188 | 63 |
| Privacy + permissions | 223 | 74 |
| Voice notes | 136 | 45 |
| FAQ + closer + footer | 308 | 103 |
| **index.html total** | **1,491** | **497** |
| pitch.html total | 1,689 | leave long, see H4 |

For calibration: Screen Studio's entire homepage above the fold is under 30
words. Linear's is 20. A landing page at 1,491 words is an essay with buttons.

## H2. The rule to apply

Every section gets **one sentence of claim and at most one sentence of proof.**
If a third sentence exists it is either moving to the pitch page, moving into a
diagram label, or being deleted. Reasoning belongs on `pitch.html`. The landing
page states, it does not argue.

## H3. Section by section, at roughly a third

Written as actual replacement copy, not instructions, so the implementing worker
can paste it.

**Hero — 122 → 38**
> # Say who, say what. It's already typed.
> Hold Ctrl+Space, say "message Pulkit that I'll be late". WhatsApp opens on
> Pulkit's chat with those exact words in the box.
>
> [Build from source] [See how]
>
> macOS. No release yet, you build it. Nobody outside the authors has used it.

Cut: the whole "you never left your editor" clause (the reader infers it), "and
nothing rewrote your sentence" (that is the next section's job), and three of
the four fineprint sentences.

**The slice — 137 → 42**
> ## What happens to your sentence
> Most dictation tools regenerate your text. Voicy cuts two spans out of it.
>
> [the diagram, with its four legend labels]
>
> The body is characters, copied by offset. There is no rewriting step to fail,
> so Hinglish survives too.

Cut: the entire filler-word paragraph (52 words). It becomes one FAQ line, or a
tooltip. The diagram is the argument; prose repeating the diagram is the single
biggest waste on the page.

**Problem — 117 → 34**
> ## The other half
> Dictation is solved. None of them know who you are talking to, so you still
> Cmd+Tab and scroll past two hundred chats. The typing was never the slow part.
>
> [quote, unchanged, 14 words]

Cut: the whole "second half is trust" paragraph. It duplicates the slice section.

**Names — 235 → 72**
> ## Indian names break every speech engine
> What Apple's recognizer returns for "Pulkit": Polkit, Polka, Paul Kit, Palka.
> Differently on consecutive runs.
>
> We tried the three documented fixes. Contextual strings: byte-identical
> output. The en_IN locale: byte-identical, 1.5x slower. A custom language
> model: byte-identical, 1576 ms.
>
> So we fix it after recognition. Correct a name once and it resolves forever.

Cut: the table becomes one line, the three `<li>` blocks become one sentence
each, and the 60-word verdict paragraph becomes one sentence. This section keeps
the most words of any on the page because it is the only genuinely surprising
thing here, but it still loses 70%.

**Two rules — 188 → 60**
> ## Three things it will not do
> **Rewrite you.** The body is a slice, not a generation.
> **Guess a recipient.** Two Rahuls and it asks. It never picks the likelier one.
> **Touch a WhatsApp API.** A `whatsapp://send` link, the same one behind every
> "chat on WhatsApp" button on the web. Nothing to ban.

Three headings and one line each. The current version explains why each rule
exists; the pitch page is where "why" lives.

**Privacy and permissions — 223 → 66**
> ## What leaves your Mac
> ### Nothing.
> Voice: transcribed on-device. Messages: never stored or logged. Contacts: read
> into memory, never uploaded. Microphone: open only while you hold the key.
> Kill switch: a blocklist that refuses everything if it cannot be read.
>
> Asks for Microphone and Contacts. Input Monitoring and Accessibility are
> optional and off.

Five one-line facts instead of five sentences, and the permissions table
collapses to one line. **Do not cut this section below this, see H5.**

**Voice notes — 136 → 40**
> ## Voice notes: half done
> Decoding real WhatsApp voice notes works, proven on real files. Transcribing
> them does not: the real ones we sampled are Hindi and Punjabi, and the English
> model turns those into confident nonsense. So it is not wired in.

Cut: the WhatsApp-shipped-in-November-2024 history (28 words of context the
reader does not need to evaluate the claim) and the callout box.

**FAQ — 308 → 95**
Keep three questions, not six. Ban, audio, and what-is-not-finished. Offline,
requirements and speed move to a one-line spec strip: `macOS 26 · Apple Silicon
· WhatsApp Desktop · works offline except delivery`. Answers get two sentences
each, hard limit.

**Closer and footer — keep, they are already 30 words.**

**New total: about 450 words**, roughly a third, with the pitch page absorbing
everything cut that was worth keeping.

## H4. pitch.html stays long, on purpose

1,689 words, and that is correct. It is a separate page a judge opts into. The
landing page is the claim, the pitch page is the evidence. The failure mode is
not "the pitch page is long", it is "the landing page tries to be the pitch
page", which is exactly what happened. Do not apply the word budget to
`pitch.html`.

## H5. Load-bearing vs decoration

The redesign can delete anything in the second list. It must not delete anything
in the first, in any wording, because these are the claims the whole trust
posture rests on and they are each verifiable in the source.

**Load-bearing. Must survive in some form.**

| Claim | Where it is true in the repo |
|---|---|
| On-device transcription, nothing uploaded, no API key | Apple Speech framework, no network code in `Speech/` |
| Pull to mic, never always-on | mic opens on key-down, closes on key-up, `Hotkey/` + `Audio/MicrophoneRecorder` |
| Visible kill switch, fails closed | `Send/Blocklist.swift`: corrupt file refuses every auto-send |
| Export and erase | alias store is plain JSON in Application Support, deletable |
| Message content is never stored or logged | fixed this session; logs lengths, phone numbers masked to last 4 |
| Never rewrites your words | body sliced by character offset, `Intent/`; LLM cleaner deliberately unwired |
| Never guesses a recipient | ambiguity returns `.ambiguous`, asserted by tests |
| No WhatsApp API, deep link only | `Send/WhatsAppDeepLink.swift` |
| Contacts never uploaded | `Contacts/ContactIndex` reads into memory only |
| Early software, no release, unused by strangers | true, and it is the line that makes every other line credible |

**Decoration. Cut freely.**

- Latency numbers (31.5 ms, 149 ms). Real, but they belong on the pitch page next
  to their method. Nobody chooses this tool on 31.5 ms.
- Test counts (128 checks, 22 clips). Already flagged in §B3.
- The andersonkl and Shrott quotes. One at most, zero is fine.
- The November 2024 WhatsApp transcription history.
- The filler-word deletion-check explanation.
- The permissions table. One line of prose replaces it.
- "Built with zero third-party dependencies."
- The phone number, avatar and keyboard hints inside the confirm card mock.

**Never allowed back, at any word count:** contact-name biasing, in any wording.
Measured to do nothing (§B1).

## H6. State of the tree

`index.html`, `styles.css` and `pitch.html` are committed and pushed at
`0c60fbf`, complete and rendering. Nothing is half-finished on disk. The
browser verification at 1440 / 1024 / 768 / 390 was **not completed**: the AO
browser panel is about 320 CSS pixels wide, so a 1440px viewport can only be
inspected at roughly 22% scale, and `ao browser screenshot` started returning
`INTERNAL_ERROR` partway through. One dark-mode screenshot at 1440 was taken and
read; the hero and the slice section render correctly. **Treat responsive and
light-mode rendering as unverified** and hand that to whoever implements the new
design.

---

# Pass 2: adversarial re-read (after 2b9d245)

Fresh-eyes pass over `index.html` and `styles.css` as committed.

## What was still slop

| Before | After | Why |
|---|---|---|
| `A hotkey, a slice, and a confirm card.` (closer) | `One key held down, and the message is sitting in the right chat.` | Three-noun triad, the most recognizable AI cadence on the page, and it described the implementation instead of the result. |
| eyebrow `the whole idea` | `how the sentence is cut` | Announces importance instead of saying anything. Labels like this are filler. |
| `Questions` (FAQ heading) | `Before you build it` | A category name, not a sentence. The new one tells the reader when to read it. |
| `The other half` | `Dictation solved the wrong half` | Cryptic two-word heading that only makes sense after the paragraph below it. |
| `Voice notes you can read` | `Voice notes: decoded, not yet readable` | The section's own body says transcription does not work. The heading promised the opposite. |
| `Dictation is solved. None of it knows...` | longer, varied rewrite | Three clipped sentences in a row is the uniform-rhythm tell. Lengths now vary. |

Automated sweep for em-dashes, `not just X but Y`, seamless, robust, delve,
leverage, "worth noting", "in today's", and the usual superlatives: zero hits in
either file.

## Claim deleted as unsupported

`Palka` was listed as an output of Apple's recognizer for "Pulkit". It appears in
`Contacts/PhoneticTests.swift` as a fixture, but **no run log in
`Speech/ASR-NOTES.md` ever produced it** — the measured mangles are Polkit,
Polka, Paul Kit, Paul Kitt and Paul. Removed. The table caption was also changed
from "across repeated runs of Voicy's own clips" to "over 22 recorded clips in
our own test harness", which is the number ASR-NOTES actually records.

Both remaining quotes (andersonkl, jpxoi) are verbatim from
`research/SOCIAL-PROOF.md` with attribution and link. No quote or implied
testimonial exists for either NOTHING FOUND category (Indian-name mangling,
slow WhatsApp Desktop typing); the name section argues from our own measurements
only.

## Overflow: measured, not assumed

Method: copied `index.html` + `styles.css` to a scratch dir, loaded the copy in a
fixed-width `<iframe>` inside headless Chrome (`--headless
--allow-file-access-from-files`, host window 1600x1000, so the iframe gives a
true CSS viewport at any width — Chrome clamps its own window to 500px minimum,
which is why a plain `--window-size=390` silently reports 500). An injected
script compares `documentElement.scrollWidth` / `body.scrollWidth` to
`clientWidth`, and walks every element for a `getBoundingClientRect()` that
crosses the viewport edge.

| Viewport | doc scrollWidth | body scrollWidth | elements crossing the edge |
|---|---|---|---|
| 320 | 320 | 320 | 0 |
| 390 | 390 | 390 | 0 |
| 768 | 768 | 768 | 0 |
| 1440 | 1440 | 1440 | 0 |

`overflow-x` computes to `visible` on both `body` and `html`, so nothing is being
clipped to hide a wide child. The only off-canvas element is `.skip-link` at
`left:-9999px`, which is the intended accessibility pattern and is excluded.
