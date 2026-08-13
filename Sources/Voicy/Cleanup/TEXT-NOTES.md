# Text quality notes (post-ASR path)

Scope: `Sources/Voicy/Cleanup/**`, `Sources/Voicy/Intent/**`, `Sources/Voicy/Contacts/**`.
Everything after the recognizer hands back a string, up to the message that gets sent
and the person it goes to.

## 1. Audit: what exists today (2026-08-13)

### TranscriptCleaner.swift (111 lines)

Deletion-only disfluency remover. It is deliberately tiny.

- `fillers` (line 15) is exactly six words: `um uh erm hmm ah er`. Nothing else.
  `like`, `you know`, `actually`, `basically` are excluded on purpose and there
  are tests asserting they survive (CleanupTests.swift lines 30-33).
- `rulesOnly` (line 40) does two passes: drop standalone fillers (line 54),
  drop an immediately repeated word (line 65). That is the entire cleanup.
- `isDeletionOnly` (line 87) is the safety check used to gate the LLM pass.
  It verifies `cleaned` is a subsequence of `original` word-wise, case and
  punctuation insensitive.

Not handled at all:

- Multi-word fillers (`you know`, `I mean`, `sort of`) as disfluency. Excluded
  by design, but there is no context-sensitive version either.
- False starts across more than one token: `I was I was going to` only loses
  nothing, because the repeat is `was` -> `I`, not adjacent-identical. Line 65
  compares single adjacent tokens only.
- Self-correction of any kind. `actually no`, `sorry`, `scratch that`,
  `no wait` are all passed through verbatim into the message body.
- Spoken punctuation (`period`, `comma`, `new line`, `question mark`). The word
  `period` is emitted literally.
- Numbers, times, money, phone numbers, emails, URLs spoken aloud. Nothing.
  `rishet at gmail dot com` stays as five words.
- Capitalization of any kind, including bare `i` -> `I` and sentence starts.
- Trailing send cues (`send it`, `that's it`, `over`). Nothing.
- Hinglish: no handling, though nothing actively breaks either.

### LLMCleaner.swift (74 lines)

Optional FoundationModels pass. The prompt (line 47) asks only for filler and
repeated-word deletion, and every response is gated through
`TranscriptCleaner.isDeletionOnly` (line 66) before it can be returned.
Correct and conservative. It cannot help with any of the rewriting problems
above, because rewriting is exactly what it is forbidden to do.

### IntentParser.swift (397 lines)

Splits transcript into recipient + body. It is the mature part of this half.

- Wake phrase strip (line 108), verb table (line 71), verb-less name-address
  shape (line 148, `startsWithNameLikeAddress` line 231).
- `to <Name>` phrase handling (line 292 `findToPhrase`, line 314
  `parseWithToPhrase`).
- Body is always a contiguous slice of the original transcript (line 219,
  line 337). Byte-for-byte fidelity is a hard rule of this file.

Gaps relevant to text quality:

- The body slice is never cleaned. `TranscriptCleaner` is not called from the
  parser, so fillers inside the body reach the send path unless something
  upstream cleaned them.
- Trailing send cues are inside the body slice by construction.
- Self-correction that changes the RECIPIENT (`send it to Rahul, sorry, Rohit`)
  is not modelled anywhere: the name tokens stop at the first boundary word, so
  `Rahul,` becomes the recipient and `sorry, Rohit` becomes the body.

### Contacts stack

- `NameNormalizer.normalize` (FuzzyMatcher.swift line 5), Levenshtein (13),
  JaroWinkler (36), Soundex (82, measured unhelpful for Indian names),
  `FuzzyMatcher.rank` (194) / `score` (202) with a phonetic recall pass capped
  below the auto-resolve floor.
- `PhoneticFolder.fold` (PhoneticFolder.swift line 33): aspiration digraph
  folds, doubled-letter collapse, v/w, o/u + e/i vowel classes, t/d. Built from
  measured mishears. Explicitly recall-only.
- `ContactResolver.resolve` (line 30): alias hit wins outright (line 34);
  `notFoundFloor` 0.55, `resolveFloor` 0.80, `gapMargin` 0.12 (lines 7-14);
  anything below the floor or inside the gap returns `.ambiguous` so the UI
  asks (lines 49-55).
- `AliasStore` (102 lines): normalized spoken phrase -> contact id + E.164,
  atomic JSON write. Names only, no message content.

Gaps:

- `runPhoneticTests()` is defined but never called from
  `Testing/TestHarness.swift:runUnitTests()`, so that suite was not running.
- No test asserts that a two-way tie forces confirmation rather than a pick.
- No test asserts the alias learned from a correction actually changes the next
  resolution.

## 2. What is deterministic and what is not

Deterministic, and now implemented (see `TextFormatter.swift`):

- Spoken punctuation and line breaks, with a content guard so
  `put a period at the end` keeps its `period`.
- Self-correction markers with an explicit scope rule.
- Emails, URLs, phone numbers, money, times, plain numbers spoken aloud.
- Capitalization: sentence starts, standalone `i`, known acronyms.
- Trailing send cues.

Not deterministic, and deliberately left alone:

- General proper-noun capitalization. Deciding that `apple` is a company and
  not a fruit needs the contact set or a model. Only names already present in
  the user's contacts could be capitalized safely, and the formatter does not
  have that dependency. Doing it wrong corrupts real words, so it is skipped.
- Semantic self-correction with no marker word (`meet at four, meet at five`).
  There is no reliable signal separating that from a genuine repetition.
- Hinglish spelling normalization (`nahi`/`nahin`/`nhi`). Requires a lexicon
  and a user-preference notion of correct spelling. The formatter's job here is
  narrower: do not damage Hindi words, and do not treat them as fillers.

## 3. Running log

- 2026-08-13: audit written. Baseline build blocked by another worker's
  in-flight edit to `Diagnostics/SelfTest.swift` (calls
  `checkBundleIdentity` / `checkAliasStore` / `checkBlocklist`, none defined
  yet). Worked around by building a copy of `Sources/` in the scratchpad with
  that one file reverted to HEAD, so their file was never touched.
- 2026-08-13: `TextFormatter.swift` written (6 passes: disfluency,
  self-correction, spoken entities, spoken punctuation, send cues,
  capitalization). Corpus `TextQualityTests.swift`: 51 rows, each also asserted
  idempotent. `RecipientTests.swift` written. All three suites plus the
  previously-orphaned `runPhoneticTests()` wired into `runCleanupTests()`.
- 2026-08-13: measured `--unit-tests`: intent 46/0, contacts 32/0, send 20/0,
  cleanup 270/0, send path 6/0. Total 374 passed, 0 failed.

## 4. Fixes made, with the root cause

1. `parseNumber` added "four thirty" to 34. A cardinal reads tens-then-units,
   never units-then-tens, so a tens word after a units word now ends the run and
   the time branch sees `4` + `30` (TextFormatter.swift, `sawUnits`).
2. Self-correction first retracted a fixed token count, which ate "Mom" out of
   "tell Mom I'll be late, actually no, I'll be on time". The retraction is now
   anchored on the correction's first word when that word appears in the clause,
   falling back to token count, and always clamped to the clause.
3. `tokenize` split on all whitespace, so a second `format` pass swallowed the
   newlines the first pass produced. Line breaks are now their own tokens and
   formatting is idempotent (asserted on every corpus row).
4. An all-filler utterance produced an empty message. Disfluency removal now
   restores the original tokens rather than emptying out.
5. Bare small numbers were left as words everywhere, so "in five minutes" and
   "at eight" stayed spelled out. They now convert when a unit follows or a
   quantity preposition precedes, while "one of my friends" still stays a word.

## 5. Measured finding: the phonetic recall pass is inert

Across every mangled name in the phonetic suite, against every fixture contact,
`FuzzyMatcher(usePhoneticBonus: true)` returns scores identical to
`FuzzyMatcher(usePhoneticBonus: false)`, to the last digit. The pass only runs
when the orthographic score is below `notFoundFloor` (0.55), and every mishear
the audio harness actually produced clears that on orthography alone:

| spoken      | contact | score |
|-------------|---------|-------|
| Paul Kit    | Pulkit  | 0.957 |
| Sid Harth   | Siddharth | 0.974 |
| Adidi       | Aditi   | 0.907 |
| Mira Krishna| Meera Krishnan | 0.890 |
| Palka       | Pulkit  | 0.730 |
| Polka       | Pulkit  | 0.730 |

So the recall the pass was written for is already coming from the orthographic
path, chiefly the space-collapsed split-name branch. The pass is not harmful
(it can only raise a score, and is capped at 0.70, below the 0.80 resolve
floor), but it is doing nothing. `PhoneticTests.swift` now asserts that
inertness, so widening the gate forces a fresh look at the safety story rather
than silently changing resolution behavior. Widening it is not free: lifting a
wrong contact into the 0.12 gap band would turn confident correct resolutions
into confirmation prompts.

`Palka` and `Polka` at 0.730 land in `.ambiguous` (below the 0.80 resolve
floor), which is the wanted behavior: Voicy asks instead of guessing.

## 6. Not wired in yet (needs an owner outside this directory)

`Core/Pipeline.swift:316` still calls only `TranscriptCleaner.rulesOnly` on the
message body. `TextFormatter.format` is not called anywhere in the shipping
path, so none of section 4 reaches a real message until that line runs it.
`Core/` is not mine to edit; flagged to the orchestrator.
