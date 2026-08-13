# On-device cleanup findings

On this machine, a cold `LLMCleaner` call exceeded 15 seconds without
returning. After the model warm-up, the second and third calls still exceeded
25 seconds without returning. The model's availability could not be
determined from the hang.

The live path therefore keeps the on-device pass disabled. The shipped
behavior is `TranscriptCleaner.rulesOnly`, which is deterministic and
deletion-only. `DisfluencyCleanup.apply` retains a hard 250 ms timeout for
future controlled testing, but it is not used by the live pipeline until
warmed latency is proven safe.

## Re-test

Run a targeted probe that calls `LLMCleaner().warm()` once, then times exactly
two sequential `LLMCleaner().clean()` calls on a roughly 25-word sentence.
Record each elapsed time and stop the probe if either call exceeds 250 ms. Do
not run the full live-LLM suite because it can hang for minutes.
