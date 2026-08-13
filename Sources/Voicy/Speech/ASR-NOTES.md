# ASR accuracy work

## Log
- Created ASR-NOTES.md; listed Speech/ dir (Transcriber.swift, LegacySpeechTranscriber.swift) and Tests/audio/ (23 clips incl. manifest.tsv).
- Read Transcriber.swift (SpeechAnalyzer engine, macOS 26 API) and LegacySpeechTranscriber.swift (SFSpeechRecognizer fallback, en_US default).
- Read manifest.tsv (22 clips; names Pulkit/Aarav/Siddharth/Aditi/Shreya/Rahul/Meera/Xavier). Found harness entry in Sources/Voicy/Testing/TestHarness.swift.
- BASELINE (en_US SpeechAnalyzer): 22/22 pass, min 101.4 / median 123.3 / max 291.9 ms. Name mangling observed: msg-pulkit-saying="Paul Kit", msg-pulkit-bare="Polka", send-a-message="Arav", name-last-send="Polkit", name-last-say="our ab", name-last-tell="Polka", name-last-before="our ad", indian-aditi="Adidi", no-number="Mira Krishna", verbless-siddharth="Sidharth"; also special-chars/long-body/name-last-long="Polkit". Unit tests green (send path 6/6; full unit suite PASS).
- Env: macOS 26.5.1 (25F80), Swift 6.3.2, target arm64-apple-macosx26.0. SDK swiftinterface exists (36,648 bytes). Grep confirms: AssetInventory.status(forModules:), assetInstallationRequest(supporting:), AssetInstallationRequest.downloadAndInstall(), SpeechTranscriber.supportedLocales/installedLocales (get async).
- ObjC header SFSpeechLanguageModel.h: SFSpeechLanguageModel.Configuration(languageModel:vocabulary:weight:); prepareCustomLanguageModel(for:configuration:completion:) (macOS 14+); docs say pass config to SFSpeechRecognitionRequest.customizedLanguageModel OR DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:). SFCustomLanguageModelData has export(to:).
- LOCALE PROBE (scratch swift in /tmp, printed real output): SpeechTranscriber.supportedLocales = 30 locales incl. en_IN. installedLocales = 9, INCLUDES en_IN (no download needed). supportedLocale(equivalentTo: en_IN) = en_IN. AssetInventory.status for en_IN module = supported. So en_IN is available WITHOUT any asset install.
- Added VOICY_TRANSCRIBER_LOCALE env seam to TranscriberFactory.make() (Transcriber.swift ~lines 102-114). Default en_US unchanged.
- en_IN SUITE RUN (VOICY_TRANSCRIBER_LOCALE=en_IN): 22/22 pass. min 116.9 / median 184.2 / max 373.2 ms — ~1.5x SLOWER than en_US. Transcripts BYTE-IDENTICAL to en_US on every clip, including all mangled names (Paul Kit, Polka, Arav, Polkit, our ab, our ad, Adidi, Mira Krishna, Sidharth). Verdict: en_IN changes nothing on this engine. Latency rules it out even if it had helped.
- Verified in SDK headers/interface: SFSpeechRecognitionRequest.customizedLanguageModel: SFSpeechLanguageModelConfiguration? (macOS 14+); SFCustomLanguageModelData.PhraseCount(phrase:count:); PhraseCountsFromTemplates(classes:builder:); TemplatePhraseCountGenerator.Template(_ body:count:); data.insert(phraseCount:); export(to:) async; SFSpeechLanguageModel.prepareCustomLanguageModel(for:configuration:completion:). All real, none invented.
- Plan: VOICY_ENGINE seam in TranscriberFactory: legacy | legacy-lm (legacy recognizer + custom LM) | dictation-lm (new SpeechAnalyzer with DictationTranscriber + ContentHint.customizedLanguage). LM built from per-call hints, cached. All inside Speech/.
- Read full arm64e-apple-macos.swiftinterface myself (lines 49-167 DictationTranscriber incl. ContentHint.customizedLanguage(modelConfiguration:) at line 74; 208-251 SpeechAnalyzer(modules:); 302-437 SpeechTranscriber presets; 513-639 SFCustomLanguageModelData with PhraseCount(phrase:count:), Template(_ body:count:), insert(template:count:), PhraseCountsFromTemplates(classes:builder:), export(to:) at line 630). Read Headers/SFSpeechLanguageModel.h: prepareCustomLanguageModelForUrl:configuration:completion: (macOS 14+), Configuration initWithLanguageModel:vocabulary: (Swift: Configuration(languageModel:vocabulary:)). Read Headers/SFSpeechRecognitionRequest.h line 74: customizedLanguageModel property (macOS 14+). All real.
- Read TestHarness inject() (lines 216-234): harness calls engine.transcribeDetailed, passes hints from FixtureContacts (givenName/familyName/nickname/org/displayName), measures transcribeMs around the call, uses TranscriberFactory.make() — so a VOICY_ENGINE env seam exercises every engine on all 22 clips without touching Testing/.
- Read Core/Pipeline.swift: Pipeline calls transcriber.transcribe(pcm:hints:) exactly once and does intent/resolution itself. Since Core/ is off-limits, a "fallback only when recipient fails to resolve" hybrid cannot be wired into the shipped path from Speech/ alone; if measurements justify it I will report the exact one-line hook Core would need instead of faking it.
- COMPILE+RUN PROBE (/tmp/speechprobe.swift, swiftc -parse-as-library -target arm64-apple-macos26.0): verified for real, not from docs: SFCustomLanguageModelData(locale:identifier:version:) + insert(phraseCount: PhraseCount(phrase:count:)) compiles; export(to:) writes training data; SFSpeechLanguageModel.Configuration(languageModel:) compiles; prepareCustomLanguageModel(for:configuration:completion:) completes with NO error and WRITES the compiled LM artifact to disk; SFSpeechRecognitionRequest.customizedLanguageModel settable; DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:) constructs. Every signature used in the plan now exists on this exact SDK.
- Implemented: CustomLanguageModel.swift (actor cache, PhraseCount count=1000 per hint, export + prepare pipeline); LegacySpeechTranscriber gained useCustomLanguageModel flag + lazy requestAuthorization + request.customizedLanguageModel; Transcriber.swift gained shared SpeechBufferFactory/AudioTranscribeFailure, DictationLanguageModelTranscriber (DictationTranscriber + customizedLanguage content hint, punctuation only, no alternatives), VOICY_ENGINE switch in make().
- swift build PASSES with the new code — proves every API signature used is real (compiler checks against the SDK).
- VOICY_ENGINE=legacy SUITE RUN: 16/22 pass. min 85.3 / median 211.5 / max 989.7 ms (max blows 800 ms budget; first clip cold). Names: Pulkit->"Paul"/"Paul Kitt", Aarav->"our", Aditi->"Addi", Rahul->"Rajol". Legacy engine WITHOUT LM is worse than the shipped engine on both accuracy and latency. Authorization already granted, no prompt needed.
- VOICY_ENGINE=legacy-lm SUITE RUN: 16/22 pass. min 100.4 / median 189.5 / max 1576.1 ms (first clip includes one-time LM compile; still blows budget). Transcripts BYTE-IDENTICAL to legacy WITHOUT LM — customizedLanguageModel changed nothing on this suite ("Paul", "our", "Addi" all persist). LM build itself succeeded (framework logged model creation).
- Weight=1.0 rerun (legacy-lm): 16/22, SAME transcripts as weight-default and no-LM legacy ("Paul", "our", "Addi", "Paul Kitt"). Max bias weight changes nothing.
- VOICY_ENGINE=dictation-lm SUITE RUN: 15/22 pass. min 175.6 / median 395.3 / max 2243.7 ms — 3x slower than shipped engine, blows budget badly. Names unchanged or worse ("Paul", "our", "Addi", "Mira"). Verified on disk: languageModel.bin 6.5 MB + data-*.bin 1.3 KB in tmp/voicy-language-models — the LM was genuinely built and attached.
- CustomPronunciation experiment RESULT (legacy-lm suite): still 16/22, SAME transcripts ("Paul", "our", "Addi", "Paul Kitt"). Pronunciation terms change nothing on this engine.
- CRITICAL: discovered the builds for the weight=1.0 and CustomPronunciation runs were FAILING (error: init(languageModel:vocabulary:weight:) is macOS 26.0+ but package targets macOS 14), so those suite runs silently used a STALE binary. Weight=1.0 and pronunciation results above are INVALID; re-measuring with a fixed, availability-gated build.
- legacy-lm RERUN with VALID weight=1.0 build: 16/22, min 132.7 / median 252.7 / max 1963.4 ms. Transcripts IDENTICAL to default-weight legacy-lm ("Paul", "our", "Addi", "Paul Kitt"). Weight genuinely changes nothing.
- Verified swift build is green at 10:42 with the availability-gated code (2.5 MB binary, current tree). The pronunciation rerun had NOT been done on a valid build (line 25 result came from a stale binary per line 26) — running VOICY_LM_PRONUNCIATIONS=1 legacy-lm suite now on the valid build.
- VOICY_LM_PRONUNCIATIONS=1 legacy-lm suite on VALID build: 16/22, min 115.8 / median 286.9 / max 2000.0 ms. Names still mangled identically ("our", "Paul Kitt", "Send hello to Pulkit" passes by luck of context). CustomPronunciation terms change NOTHING on this engine. Closing the pronunciation thread: dead.
- Last untried LM variant: the documented template-class form (TemplatePhraseCountGenerator, define class CONTACT_NAME, insert template "[CONTACT_NAME]" count 1000) vs the flat PhraseCount list used so far. Adding VOICY_LM_TEMPLATES=1 gate to CustomLanguageModel.swift.
- TRAP AVOIDED: first template-suite attempt ran a STALE binary — the build was broken mid-flight by a SIBLING worker's in-progress Diagnostics/SelfTest.swift edits (their missing funcs: checkBundleIdentity/checkAliasStore/checkBlocklist/sampleContactQualityStats). That 16/22 run is INVALID. New rule for the rest of this task: after every build, verify `strings .build/debug/Voicy | grep -q VOICY_LM_TEMPLATES` before trusting a run.
- FALSIFICATION RESULT (legacy-badlm, valid build): 16/22, NO errors, transcripts identical to real legacy runs. Pointing customizedLanguageModel at a nonexistent file changed NOTHING — the legacy recognizer silently IGNORES the property on this machine. This explains why the real LM also changed nothing.
- FALSIFICATION RESULT (dictation-badlm, valid build): 13/22, NO errors from the nonexistent model config — DictationTranscriber also ignores/falls back silently. Neither engine honors customizedLanguageModel on this machine; transcript mangling identical.
- PRONUNCIATIONS RUN (valid build, legacy-lm + VOICY_LM_PRONUNCIATIONS=1): 16/22, min 99.6 / median 230.6 / max 2351.0 ms. Transcripts IDENTICAL to legacy-lm without pronunciations. CustomPronunciation also changes nothing.
- Matrix complete. All engines measured. Shipped default path never touched; validating default suite + unit tests next.
- FINAL VALIDATION: default suite 22/22 (transcripts byte-identical to baseline), unit tests all pass (send path 6/6), name-last-say.wav single-clip PASS. Second default run: min 129.6 / median 156.7 / max 316.5 ms — within budget, close to baseline (123.3 ms); an earlier inflated run (median 314.7) was machine load (warm-up itself took 1.7 s).

---

# Session 2: honest measurement

## Why the old number was not evidence

The suite reported "22/22 pass". That number says the intent pipeline produced
the expected recipient and body. It does not say the recognizer heard the
words, and it cannot: the cases that cover mangled names expect a non-match, so
a clip where "Aarav" comes back as "our ab" PASSES. Pass/fail therefore cannot
distinguish an engine getting better from one getting worse.

Added `Sources/Voicy/Testing/WordErrorRate.swift` (Levenshtein with backtrace,
so substitutions / deletions / insertions are reported separately) and a
`--test-wer <manifest>` mode. Scoring normalizes case, punctuation and spelled
numbers, so "at 5" for "at five" is not counted as an error; what is left is
acoustic error only. Corpus WER is total errors over total reference words, not
the mean of per-clip rates, which would let a 4-word clip weigh as much as a
40-word one.

    --test-wer <manifest>       score every clip
    --wer-out <file.tsv>        write per-clip scores
    --wer-compare <file.tsv>    print this run against an earlier one

## Corpus changes made before baselining

- The `Aman` (en_IN) voice is BROKEN on this machine right now: `say -v Aman`
  exits 0 and writes a 4266-byte stub (0.13 s of nothing) for any input. The
  three committed `Aman` clips were generated when it still worked, so nobody
  noticed. Regenerating them today would have silently produced silent clips
  and looked like a catastrophic engine regression. Switched those rows to
  `Rishi` (en_IN, verified working) and added a size guard to
  `Tools/gen-test-audio.sh` that rejects any clip shorter than 30 ms per
  character of input text. Verified the guard fires on Aman and passes on Rishi.
- Added `Tests/audio/hard-manifest.tsv`: 10 hard cases (long run-on, digits and
  times, Hindi/English code switching, two adjacent names, homophone-dense body,
  Indian place names, terse clipped command, spelled letters, mid-sentence self
  correction, quiet trailing clause).
- Added `Tools/gen-augmented-audio.sh`: for each of the 32 clean clips it
  produces 8 degraded variants via ffmpeg (pink noise at 10 dB and 5 dB SNR,
  two-voice babble at 12 dB, 1.25x and 0.85x rate, -18 dB gain, first 250 ms
  removed, 1.5 s trailing silence). 256 clips. SNR is set by measuring both
  signals with `volumedetect` rather than by guessing a gain.
- Added `Tools/asr-build.sh`. Twice in the previous session a measurement ran
  against a STALE binary because a sibling worker's in-progress file broke the
  build. This builds the working tree, and only if that fails, mirrors the tree,
  reverts sibling-owned files to HEAD, builds that, and says loudly which files
  it reverted. It never edits the real tree.

## BASELINE, shipped default engine (SpeechAnalyzer + SpeechTranscriber, en_US)

Binary: mirror build, sibling-owned Contacts/FuzzyMatcher.swift,
Diagnostics/SelfTest.swift reverted to HEAD (the working tree did not compile;
none of those files are on the transcription path).

### Clean synthetic corpus, 22 clips (Tests/audio/manifest.tsv)

corpus WER **10.4%**, corpus CER **4.2%**, 10/22 clips perfect.
latency median **108.2 ms**, p95 **145.4 ms**, max 231.3 ms.

    clip                  WER     CER    S/D/I   ms      hypothesis
    name-last-say        50.0%   26.7%   1/0/1    97.1   "Say hi to our ab."
    no-number            42.9%   13.5%   2/0/1   105.7   "Message Mira Krishna, and that I am late."
    name-last-tell       40.0%   28.6%   1/0/1    97.3   "Tell Polka that I am late."
    msg-pulkit-saying    33.3%    6.5%   1/0/1   106.9   "Message Paul Kit saying I am late."
    name-last-before     28.6%   11.4%   1/0/1   112.3   "Send happy New Year wishes to our ad."
    name-last-send       25.0%    5.0%   1/0/0    94.9   "Send hello to Polkit."
    special-chars        15.4%   14.8%   1/1/0   145.4   "Message Polkit that it is 50% off, and I need an answer."
    msg-pulkit-bare      14.3%   10.3%   1/0/0   108.2   "Message Polka, I am on my way."
    send-a-message       14.3%    2.4%   1/0/0   105.5   "Send Arav a message saying happy birthday."
    indian-aditi         11.1%    2.3%   1/0/0   111.1   "Send a message to Adidi saying call me back."
    name-last-long        7.7%    1.6%   1/0/0   139.6   "Send a message to Polkit saying I will call you in 10 minutes."
    long-body             3.6%    0.8%   1/0/0   231.3   "Message Polkit, that I am leaving the office now, ..."
    msg-pulkit-that       0.0%    0.0%   0/0/0   136.7   "Message Pulkit that I will reach Bangalore tomorrow."
    tell-fullname         0.0%    0.0%   0/0/0   111.9   "Tell Rahul Verma that the meeting is at five."
    text-verb             0.0%    0.0%   0/0/0   112.6   "Text Siddharth on my way now."
    indian-shreya         0.0%    0.0%   0/0/0   110.9   "Message Shreya that I am reaching in 10 minutes."
    indian-siddharth      0.0%    0.0%   0/0/0   104.4   "Tell Siddharth that the file is ready."
    british-pulkit        0.0%    0.0%   0/0/0   106.1   "Message Pulkit that I am running late."
    ambiguous-rahul       0.0%    0.0%   0/0/0    94.5   "Message Rahul that I am late."
    unknown-name          0.0%    0.0%   0/0/0   108.2   "Message Xavier Quinlan that I am late."
    no-verb               0.0%    0.0%   0/0/0   110.9   "What is the weather in Bangalore today?"
    verbless-siddharth    0.0%    0.0%   0/0/0   108.3   "Siddharth, that the file is ready."

Every non-zero row except `no-number`, `special-chars` and `indian-siddharth`
is a contact name. 13 of the 19 total errors are name substitutions. The
recognizer is not bad at English; it is bad at these names specifically.

### Hard cases, 10 clips (Tests/audio/hard-manifest.tsv)

corpus WER **15.2%**, corpus CER **5.1%**, 1/10 clips perfect.
latency median **176.0 ms**, p95 **465.6 ms**.

    hard-numbers        35.5%   5 sub 6 del   "...at 740 in the morning on the 23rd and my seat is 11 C and the booking references 9421."
    hard-selfcorrect    28.6%                 "Tell a Didi, the meeting is at 4 Nozari at 5 in the evening."
    hard-spelling       27.8%                 "Message mirror that the gate code is B47K..."
    hard-codeswitch     26.7%   4 sub         "...peak high bus, Thoda traffic high."   (theek hai bas thoda traffic hai)
    hard-terse          14.3%                 "Text Darav running late start without me."
    hard-two-names      10.0%                 "Tell Siddharth and Arav..."
    hard-propernouns     5.9%                 "...moved to Koraminglar..."   (Koramangala)
    hard-homophones      4.8%                 "message rule that their 2 new offices..."   (Rahul)
    hard-runon           4.1%                 "Tell Polkit that I am leaving now..."
    hard-trailoff        0.0%

Code switching, spelled letters and long digit strings are real failure modes,
not just names. "no sorry" became "Nozari".

### Augmented corpus, 256 clips (Tests/audio/aug/manifest.tsv)

corpus WER **16.1%**, corpus CER **7.6%**, 57/256 clips perfect.
latency median **111.1 ms**, p95 **260.0 ms**, max 400.6 ms.

    variant      n    WER      CER      median ms
    clipstart    32   21.6%    16.7%    106.3    <- worst by a wide margin
    noise5       32   20.5%    10.3%    105.9
    noise10      32   17.9%     7.1%    108.1
    babble       32   15.0%     6.0%    110.1
    slow         32   14.2%     4.9%    111.8
    trailsil     32   13.4%     4.6%    113.0
    fast         32   13.2%     5.5%    107.1
    quiet        32   13.2%     5.5%    108.7

The headline result: **losing the first 250 ms of audio costs more accuracy
than mixing in noise at 5 dB SNR** (21.6% vs 20.5% WER, and CER 16.7% vs
10.3%). `clipstart` is a simulation of capture starting after the keypress,
which is exactly what the app does today. A pre-roll ring buffer is therefore
not a polish item, it is the largest single accuracy lever measured so far, and
it costs nothing at inference time.

Gain and speaking rate barely matter. Noise matters. Onset matters most.

## Pre-roll: measured, and the answer is do NOT build it

The augmented corpus showed `clipstart` (250 ms of onset removed) as the worst
degradation of all, worse than 5 dB SNR noise. That made a pre-roll ring buffer
look like the biggest cheap win available. Two measurements changed that
conclusion.

### 1. How much audio the app actually loses

Added onset instrumentation to `MicrophoneRecorder` and a `--test-onset` probe.
The first version of it measured the wrong thing and would have overstated the
problem by 4x, so both numbers are reported:

    cold        start() 159.5 ms   first callback 145.9 ms   AUDIO LOST 36.6 ms
    prewarmed   start()  38.6 ms   first callback 144.4 ms   AUDIO LOST 35.1 ms

`first callback` is when the tap fires. Most of it is simply the 4096-frame tap
buffer filling: 4096 frames at 48 kHz is 85 ms, and that audio is INSIDE the
buffer, not missing. Reading 144 ms as "lost audio" is wrong.

`AUDIO LOST` compares `start()` against the hardware timestamp (`AVAudioTime.hostTime`)
of the first captured sample, so it is the audio that genuinely never existed
anywhere and is the only part a pre-roll buffer could recover.

**The app loses about 35 ms, not 250 ms.**

### 2. What 35 ms is worth

Regenerated the corpus with an onset sweep (50 / 100 / 250 ms) so the cost
curve is measured rather than extrapolated. 320 clips:

    onset removed    corpus WER    corpus CER
    0 ms (clean)        12.9%          4.7%
    50 ms               14.2%          5.3%
    100 ms              15.0%          6.7%
    250 ms              21.6%         16.7%

The damage is strongly non-linear: 250 ms is catastrophic, 50 ms costs about
1.3 points of WER. The app's real 35 ms therefore costs roughly **one point of
WER**, and that is an upper bound, because the sweep cuts 35 ms out of speech
that starts immediately, while a push-to-talk user presses the key and then
starts speaking. The lead-in silence absorbs most of a 35 ms gap.

### 3. Why it is not worth building anyway

A ring buffer can only contain audio the microphone already captured. To have
anything from before the keypress, the microphone must be running before the
keypress. The hotkey IS the keypress: `PushToTalkHotkey` triggers on
`.flagsChanged` for right Option going down, so there is no earlier "armed"
state to hang a buffer on. The only way to fill the buffer is to keep the mic
open continuously, which means a permanent orange recording indicator and
directly contradicts the product's "pull to mic, never always-on" positioning.

Trading the app's central privacy claim for one point of WER is a bad trade.
Recommendation: do not build the pre-roll ring buffer. `MicrophoneRecorder`
keeps the instrumentation (it is 20 lines, costs nothing, and `--test-onset`
will catch it if a future change makes the gap grow), and no always-on capture
is introduced.

If onset ever needs to be recovered, the honest way is a UX change, not a
hidden buffer: arm on a distinct modifier and let the user see it. That is a
product decision, not an ASR one.

Numbers above: WER/CER taken from the file-fed path, which is deterministic.
The onset numbers came from the real capture path on the live microphone.
Latency medians in the 320-clip run were taken while the machine was under load
(load average 25, four other agents building), so they read ~25% higher than
the quiet-machine baseline; the WER and CER figures are unaffected by load.
