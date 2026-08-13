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

---

# Build and first-run audit

Scope of this pass: `build.sh`, `Package.swift`, `Info.plist`, `Tools/`,
and this file. No Swift and no landing page touched.

## 1. One-command build from a clean checkout

It already worked, and it still does. `./build.sh` from a fresh clone runs
`swift build -c release`, assembles `dist/Voicy.app`, signs it, and prints the
path. No manual step, no generated file to fetch first.

What was missing was the failure path: a machine without a Swift toolchain got
`swift: command not found` and nothing else. `build.sh` now preflights before
building and each failure names the fix:

- not macOS
- not a Voicy checkout (missing `Package.swift`, `Info.plist`, `Sources/Voicy`)
- no Xcode command line tools -> `xcode-select --install`
- no selected toolchain -> `sudo xcode-select --switch /Applications/Xcode.app`
- Swift older than 6, which `swift-tools-version: 6.0` requires
- no `codesign`
- `Info.plist` not a valid plist (`plutil -lint`), which would produce a bundle
  that silently refuses to launch
- unknown argument; `./build.sh [release|debug]`, plus `--help`

After signing, `codesign --verify --strict` now runs, so a bundle that would be
rejected at launch fails the build instead of shipping.

## 2. Info.plist

Correct as found: `CFBundleIdentifier` `com.voicy.app`, `CFBundleExecutable`,
`CFBundlePackageType`, version `1.0` build `1`, category productivity, and
`LSUIElement` `true` — right for a menu-bar-only app, no Dock icon, no main
window.

Permission strings, one per thing the app actually asks for:

| Permission | Key | Status |
|---|---|---|
| Microphone | `NSMicrophoneUsageDescription` | present, honest |
| Speech recognition | `NSSpeechRecognitionUsageDescription` | present, honest |
| Contacts | `NSContactsUsageDescription` | present, honest |
| Input Monitoring | `NSInputMonitoringUsageDescription` | **added** |
| Accessibility | none exists | see below |

Added `NSInputMonitoringUsageDescription`. The app calls
`CGRequestListenEventAccess` for push-to-talk on a bare modifier, so it triggers
the Input Monitoring prompt; there was no purpose string for it.

Also filled the empty `NSHumanReadableCopyright`.

**Accessibility has no Info.plist purpose string.** macOS supplies the
Accessibility prompt text itself (`AXIsProcessTrustedWithOptions`); there is no
`NSAccessibilityUsageDescription` key, and inventing one would be dead weight.
The app explains it in Settings and in `--selftest`, which label it Tier-2 and
optional. Nothing to fix, recorded so the gap is not re-reported as a bug.

Nothing is requested without a purpose string. No key describes a permission the
app does not use — in particular there is no `NSAppleEventsUsageDescription`,
because the app never drives anything via AppleScript.

### Two things deliberately left alone

- **`LSMinimumSystemVersion` is `26.0` but `Package.swift` targets
  `.macOS(.v14)`.** So the app builds against a 14 floor but Launch Services
  refuses to open it below 26. The macOS 26 APIs are `@available`-gated, so
  lowering the plist floor is plausibly correct and would widen the audience,
  but nothing here can boot macOS 14–15 to prove the app survives it. Lowering
  an untested floor trades a clean refusal for a possible crash on launch, so
  it stays at 26 until someone tests on an older Mac. README already says
  macOS 26+, so shipped behavior and docs agree.
- **Bundle identifier stays `com.voicy.app`.** It is not a domain anyone owns,
  and a real reverse-DNS id would be tidier, but every TCC grant the current
  user has (Microphone, Contacts, Accessibility, Input Monitoring) is keyed to
  this identifier plus the signing identity. Changing it silently drops all of
  them. Change it once, before first public release, never after.

## 3. Clean-checkout completeness

Verified by cloning the repo to a scratch directory and building there. Nothing
is missing:

- No build artifact is required. `.build/`, `dist/`, `build/`, and `main` are
  ignored and regenerated.
- No generated audio is required to build or to pass `--unit-tests`.
  `Tests/audio/*.wav` and `Tests/audio/aug/` are ignored by design and are
  regenerated by `Tools/gen-test-audio.sh` (needs `say`) and
  `Tools/gen-augmented-audio.sh` (needs `ffmpeg`). Only the ASR evaluation
  harness needs them.
- No absolute local path appears in `build.sh`, `Package.swift`, `Info.plist`,
  or `Tools/*.sh`.
- No bundled resource is needed. The only `Bundle.main` use is `SelfTest.swift`
  reading its own identity, and `Package.swift` declares no resources, so an
  empty `Contents/Resources` is correct.
- The app ships no icon (`CFBundleIconFile` is absent). Harmless for an
  `LSUIElement` app, which shows a menu bar glyph and no Dock tile, but it does
  mean a generic icon in Finder. Cosmetic, needs an asset, not a build fix.

Sole prerequisite for a clean checkout: macOS with Xcode 16 or newer (Swift 6).

## Release checklist

Everything below needs credentials or a browser and was **not** done here. In
order:

1. **Apple Developer account.** Paid membership ($99/yr). Note the Team ID.
2. **Developer ID Application certificate.** Create it at
   developer.apple.com > Certificates, download, double-click to add to the
   login keychain. Confirm with
   `security find-identity -v -p codesigning` — the entry must read
   `Developer ID Application: <name> (<TeamID>)`. `build.sh` prefers a
   `Developer ID Application` identity automatically once it exists.
3. **Decide the final bundle identifier before this release, not after.**
   See the note above; changing it later resets every user's permissions.
4. **Harden the runtime.** Notarization requires it. Add
   `--options runtime` to the `codesign` call in `build.sh`, plus an
   entitlements file granting `com.apple.security.device.audio-input` and
   `com.apple.security.automation.apple-events` only if actually needed. Then
   re-run the full permission flow, because hardening can break TCC prompts.
5. **Notarize.**
   ```
   ditto -c -k --keepParent dist/Voicy.app dist/Voicy.zip
   xcrun notarytool store-credentials voicy-notary \
     --apple-id <apple-id> --team-id <TeamID> --password <app-specific-password>
   xcrun notarytool submit dist/Voicy.zip --keychain-profile voicy-notary --wait
   xcrun stapler staple dist/Voicy.app
   spctl -a -vvv -t install dist/Voicy.app   # must print "accepted / Notarized Developer ID"
   ```
   The app-specific password comes from appleid.apple.com, not the account
   password.
6. **Verify on a Mac that has never run Voicy.** Fresh TCC state is the only
   honest test of the four permission prompts. Run `--selftest` first; on a
   clean machine Speech and Contacts correctly report "not determined" until
   first use.
7. **Package for distribution.** A zip of the stapled `.app` is enough; a signed
   DMG is nicer. Notarize the DMG too if you ship one.
8. **Landing page deploy** (`landing/`, Cloudflare Wrangler). Needs
   `wrangler login` in a browser. Not run here.
9. **Tag the release** and bump `CFBundleShortVersionString` /
   `CFBundleVersion` in `Info.plist`. `CFBundleVersion` must increase on every
   build you hand to anyone.

## Verification run

From a clean clone of `HEAD`, with no other setup:

```
git clone <repo> clean && cd clean
./build.sh
./dist/Voicy.app/Contents/MacOS/Voicy --unit-tests
./dist/Voicy.app/Contents/MacOS/Voicy --selftest
```

Build completed in about 40 s (warnings only, no errors) and produced
`dist/Voicy.app` signed as `com.voicy.app`. `--unit-tests` printed
`RESULT: all checks passed`. `--selftest` passed every environment check;
Speech and Contacts reported "not determined", which is the expected state for a
bundle whose TCC prompts have not been answered yet, not a build failure.
