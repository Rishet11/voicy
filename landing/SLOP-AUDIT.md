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
