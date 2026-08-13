# Repo hygiene report

Scope: root-level files only (README.md, LICENSE, .gitignore, Package.swift).
Sources/, Tools/, Tests/, landing/ were read but never edited.

## 1. LICENSE

Added. Standard MIT text, `Copyright (c) 2026 Rishet Mehra`.

Holder determined from `git config user.name` (Rishet Mehra), which matches the
only human author in `git log` (Rishet Mehra <rishetmehra11@gmail.com>, plus the
GitHub noreply identity Rishet11). No organization invented. README line 256
already claimed MIT, so the claim is now backed by a file.

## 2. .gitignore

Nothing bad is tracked. `git ls-files | grep -E '\.build|\.bin$|\.wav$'`
returns zero rows. No build products, no model binaries, no `.DS_Store`, and
no staged artifacts in `git status`.

Changes made:
- Replaced the two hardcoded `.build-asr/` and `.build-asr-tree/` entries with
  `.build-*/`, so every worker's isolated build dir is covered. This already
  matters: `.build-text/` was sitting untracked and unignored.
- Added `Tests/audio/results/` (the ASR harness output dir), which was
  untracked and unignored.

Already present and correct: `.build/`, `.DS_Store`, `dist/`, `build/`,
`*.dSYM/`, `main`.

Note, contradicts the brief: `Tests/audio/*.wav` is **ignored**, not tracked,
and zero WAVs are in the index. The comment above that line says the clips are
regenerated with `Tools/gen-test-audio.sh`. That looks deliberate, so I left it
alone. Only `Tests/audio/manifest.tsv` is tracked from that directory. If the
WAVs are meant to be committed, that line has to come out, and that is a call
for whoever owns Tests/.

Model binaries: `languageModel.bin` (6.5 MB) and `data-*.bin` are written to
`tmp/voicy-language-models` per the ASR notes, outside the repo. Nothing to
ignore.

## 3. README accuracy

### Corrected (proven false)

**Contact-name biasing of the recognizer.** Removed from three places (the
"Hearing a name correctly" section, the pipeline diagram, and the "Working,
tested" list). Evidence in `Sources/Voicy/Speech/ASR-NOTES.md`: Apple's
`customizedLanguageModel` was pointed at a nonexistent model file on both the
legacy `SFSpeechRecognizer` path and the macOS 26 `DictationTranscriber` path,
and it produced no error and byte-identical transcripts to the runs with a real
model. The property is silently ignored on this machine. Weight=1.0,
CustomPronunciation, template classes and the en_IN locale were all measured
too, all byte-identical.

The section now says what is actually true and still impressive: the recognizer
mangles the name, and `FuzzyMatcher` plus `PhoneticFolder` recover it after the
fact.

**Voice-note transcription quality.** The old text said Voicy "turns them into
text you can scan in three seconds". Corrected. Per
`Sources/Voicy/VoiceNotes/FINDINGS.md`, decoding real Ogg-Opus notes works, but
transcription runs `en_US` and the six real notes sampled were mostly Hindi and
Punjabi, producing phonetic nonsense. The status callout and the "In progress"
bullet now state the English-only limitation.

### Unverifiable, left in place, flagged for you

I did not touch these. None are provably false, but none are backed by anything
in this repo.

1. "the average person has **47 unread texts**" (line 25). No source cited.
2. The r/ADHD pull quote (line 27) and the Wispr Flow quote (line 97). Real
   quotes presumably, but uncited.
3. "Voicy is the first Mac voice tool that knows who you mean" (line 45).
   Market claim, unfalsifiable from here.
4. The whole comparison table (lines 123-131), including what SuperWhisper and
   Wispr Flow do with your audio and permissions.
5. "Zero ban risk" / "permanently bans accounts, sometimes after 10 messages"
   (lines 9, 109, 117). The architecture argument is sound (deep link only, no
   protocol reimplementation) but "zero" is absolute and the ban statistic is
   uncited.
6. "Correct it once and it never gets it wrong again" (line 91). Alias
   persistence exists; "never" is absolute.
7. "Rewriting a sentence is architecturally impossible" (line 101). The
   character-offset design supports this, but "impossible" is a strong word
   given the "LLM-assisted cleanup" item in the roadmap and the new
   `Sources/Voicy/Cleanup/TextFormatter.swift`.
8. "On **21 November 2024**, WhatsApp launched voice-message transcription"
   (line 171). External fact, not checked.
9. "currently ~1.1s to transcribe, targeting under 800ms" (line 242). The ASR
   harness measures a median of 123-157 ms for the transcribe call itself. The
   1.1 s figure is presumably end to end including capture, but nothing in the
   repo measures that, so the two numbers cannot be reconciled from here.
10. "~100 names that actually matter to you" is gone with the biasing text, but
    the underlying contact-count assumption never had a source either.

### Package.swift inconsistency (reported, not changed)

README says **Requirements: macOS 26+**. `Package.swift` declares
`.macOS(.v14)`. This is not a bug: the ASR worker's notes show the macOS 26 APIs
are `@available`-gated precisely because the package targets 14, and raising the
platform would break their in-flight code. Flagging it as a doc/manifest
mismatch for someone who owns the build. I made no change to Package.swift.

## 4. Secrets

None found.

`git grep -inE 'api[_-]?key|secret|token|sk-'` returns 40+ hits, all of them the
word "token" in `TranscriptCleaner.swift` and `FuzzyMatcher.swift` meaning
lexical tokens (`tokenize`, `queryTokens`, `multiTokenAnchorFloor`). Zero are
credentials.

A tighter sweep for actual credential shapes found nothing:

```
git grep -inE '(api[_-]?key|secret|password|bearer)[[:space:]]*[:=]|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}'
```

No output. Nothing to rotate. Consistent with the README's "There is no API
key" claim: the app is fully on-device.

## Files changed

- `LICENSE` (new)
- `.gitignore` (`.build-*/`, `Tests/audio/results/`)
- `README.md` (two false claims corrected)
- `REPO-HYGIENE.md` (this file)

No Swift touched. Tree builds exactly as it did before.

DONE
