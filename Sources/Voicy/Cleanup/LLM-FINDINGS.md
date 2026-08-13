# On-device cleanup findings

On this machine, `SystemLanguageModel.default.availability` is `available`.
With the assets downloaded, one targeted probe measured:

- cold call: 3896.8 ms
- warm call 2: 859.4 ms
- warm call 3: 909.4 ms

Earlier, before the assets finished downloading, a cold call exceeded 15
seconds and warmed calls exceeded 25 seconds without returning. Those hangs
were not used as latency numbers.

The live path therefore keeps the on-device pass disabled. The shipped
behavior is `TranscriptCleaner.rulesOnly`, which is deterministic and
deletion-only. `DisfluencyCleanup.apply` retains a hard 250 ms timeout for
future controlled testing, but it is not used by the live pipeline until
warmed latency is proven safe.

## Re-test

Compile and run the committed targeted probe:

```bash
mkdir -p .build
swiftc -parse-as-library Sources/Voicy/Cleanup/TranscriptCleaner.swift \
  Sources/Voicy/Cleanup/LLMCleaner.swift Tools/llm-probe.swift \
  -o .build/llm-probe
perl -e 'alarm 30; exec @ARGV' .build/llm-probe
```

It prints availability and three calls on one roughly 25-word sentence. Do
not run the full live-LLM suite because it can hang for minutes.
