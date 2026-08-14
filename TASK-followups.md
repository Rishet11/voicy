# Task: close out the known open bugs in the send path

Work in the shared tree: `/Users/rishetmehra/Desktop/aohack/voicy`
Do NOT work in your assigned AO worktree, it is an empty initial commit.

A QA hardening pass already landed (commits 65cf3a9 through f902a5e). It fixed the recording
pill, five separate cold start bugs, and a draft destroying bug. Read those commit messages
first; the code comments explain the measurements behind every decision, and re-deriving them
wastes your time and risks reintroducing what they fixed.

What that pass PROVED, with 22 real sends confirmed against the recipient's actual chat:
the app never claimed a send that did not happen, never sent twice, never sent a wrong
message, and never stole focus. 14 claimed sent and 14 arrived. 8 refused and none arrived.

Your job is the bugs it left open. Do not regress that honesty record.

## Absolute rules, these outrank every other instruction here
- NEVER claim a send that did not happen. A send is only "sent" when the composer was
  verified to clear afterwards.
- NEVER resend automatically. A message must never be sent twice.
- The confirmation card is mandatory before any send. Do not add a bypass.
- NEVER guess a person. If two contacts are a close match, the app asks.
- NEVER steal focus. The user's frontmost app must stay frontmost through the whole send.
- Fix root causes. Never widen a catch, never swallow an error, never suppress a warning to
  make a test go green. If you cannot fix something, say so plainly.
- NEVER invent a measurement. If you did not measure it, write "unmeasured".
- Zero em dashes in any string, comment, or document you write.

## Tools that already exist, use them instead of building your own
```
./dist/Voicy.app/Contents/MacOS/Voicy --test-meter        # level meter, real recordings
open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-composer      # AX composer state
open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-ax            # full AX tree dump
open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-contact "<name or number>"
open -n --stdout /tmp/p.log dist/Voicy.app --args --send-test "<name>" "<body>"
open -n --stdout /tmp/p.log dist/Voicy.app --args --send-test-number "<e164>" "<body>"
```
Live sends must run through the launched bundle (`open`), not the bare binary, or the
Accessibility and Microphone permissions do not apply. Anything window related is invalid if
the screen is locked: check `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`
before you trust a window result. A whole batch of tests was thrown away for this reason.

The owner authorises real test sends to the contact **Stone**, and to their own number
via `--send-test-number`.

---

# BUG 1: a failed send jams the next one

## Reproduce
Get any send to fail so the body is left sitting in the composer. Easiest: put WhatsApp in a
state with no window (quit it, then let a send relaunch it windowless). Then run a second
send to the same contact.

## What happens
The second send sees the leftover text, correctly identifies it as an unsent draft, and
refuses with `composerHasDraft`. So one failure jams every following attempt until somebody
clears the box by hand. Observed live, repeatedly.

## Why it is not simply "remove the draft check"
That check is the fix for a data loss bug: `replaceComposerText` used to select the whole
composer and overwrite it, destroying a half typed draft with no copy kept, and it could send
the user's draft glued onto the new body. See `WhatsAppComposeWaiter.firstUnsatisfied` and
commit 50459cb. Do not weaken it.

## What to work out
Voicy cannot currently tell its own leftover text from the user's draft, and that is the real
gap. Options worth evaluating, pick with reasons:
- Remember the exact body of the last failed attempt, in memory only, and treat a composer
  holding exactly that as Voicy's own leftover rather than a user draft. Note the constraint
  in CLAUDE.md: never persist message content to disk. In memory only, cleared on success.
- Offer the user the choice in the failure alert rather than deciding for them.
Whatever you choose, a real user draft must still survive byte for byte.

---

# BUG 2: a correction is forgotten when the send is not confirmed

## Reproduce
`Pipeline.handleSend`, around line 533. Alias learning calls `persistAlias` only for
`.sentVerified` and `.prefilled`. A send that lands on `.sentUnverified` learns nothing.

## What happens
The user corrects a misheard name, the message goes out, the composer does not clear in time,
so the outcome is `sentUnverified` and the correction is thrown away. The product promise is
"correct it once and it remembers", and a flaky send silently breaks it. Measured: this really
happens, 8 of 22 sends in the last pass did not reach `sentVerified`.

## The tension you have to resolve
The current behaviour is deliberate and documented: do not learn a mapping when the send might
have gone to a blocked or wrong place. But an alias is only a name to contact mapping, and the
recipient was already resolved and confirmed by a human at the confirm card before any send was
attempted. Decide whether the confirm card is sufficient authority to learn the name
independently of whether delivery was confirmed, then implement and document your reasoning.
No message content ever goes in the alias store.

---

# BUG 3: no window means no send, and that may be unfixable

## What is already measured, do not redo this
With WhatsApp running and its window closed, on macOS 26.5:
- `AXWindows` returns `kAXErrorSuccess` with an array of ZERO windows.
- `AXFocusedWindow` returns the menu bar element, whose subtree is 280 menu items, not a window.
- The reopen Apple Event reports accepted and no window ever appears. It is sent in no-reply
  mode, so its return value is not evidence of anything.
- `NSRunningApplication.unhide()` does nothing, because the app is not hidden.
- `requestWindowWithoutActivation()` returns false: no such AX action is advertised.
- `AXManualAccessibility` is unsupported, error -25205.

So every non-activating path is exhausted, and the app correctly refuses rather than claiming
a send. Confirmed as the single cause of 8 of 8 failures in a 20 run batch: the moment the
owner clicked WhatsApp to give it a window, the next send verified immediately.

## What to try, and what not to
Do NOT make WhatsApp frontmost. That breaks a hard rule, and it is the whole point of the
product.

Worth investigating, honestly reporting failure if they do not pan out:
- Whether a `whatsapp://` deep link delivered while the app is windowless can be made to
  create a window, for instance by varying the open configuration.
- Whether `NSRunningApplication.activate()` followed immediately by `hide()` can be made
  imperceptible. There is already a disabled hook for this (`legacyHideWhatsApp`, a no-op by
  default). It was deliberately left off. If you re-enable it you must MEASURE whether focus
  actually returns, by sampling `NSWorkspace.frontmostApplication` throughout the send, not by
  assuming.
- Whether the failure message should offer a button that opens WhatsApp for the user, making
  the recovery one click instead of a puzzle.

If none of it works, say so plainly and improve the message instead. An honest limitation the
user can work around beats a broken promise.

---

# BUG 4: the send button is flaky and nobody knows why

## What was observed
With WhatsApp's own prefill in the composer, `whatsAppSendButtonExists()` returned true on
some attempts and false on others, with the identical 13 character body in place. In the
failing state the chat bar exposed `ChatBar_AttachMediaButton`, `ChatBar_EmojiButton` and
`ChatBar_VoiceMessageButton`, and no send button at all.

Also measured: writing the body through Accessibility does NOT put WhatsApp in a sendable
state. Setting `AXValue` changes what the tree reports without running WhatsApp's own
text-changed handling, so the send button never appears. Only WhatsApp's own deep link prefill
produces a working send button.

## The current workaround, which you should try to replace with understanding
`WhatsAppComposeWaiter.Options` has two grace periods:
- `prefillGrace = 3.0`, how long an empty composer is left alone so WhatsApp can fill it
  itself before Voicy writes into it.
- `sendButtonGrace = 4.0`, how long a missing send button blocks readiness before Voicy
  proceeds anyway and submits through the Return-to-PID fallback.

Both numbers were picked from a handful of live runs. They are not measured. Find out what
the real distribution is, over at least 20 runs, and set them from data or replace the
approach. Report the distribution, not just the chosen number.

Note the Return fallback is what actually delivered several of the confirmed sends, so it
works. The question is whether the AX button press is worth keeping as the preferred path.

---

# BUG 5: cold sends take 20 to 40 seconds

Sequence today: deep link, wait, launch, reopen Apple Event, window wait, unhide plus AX
action, window wait, deep link AGAIN, composer wait, submit, clear verification.

Known specifics:
- The first wait burns its full timeout learning `appNotRunning`, a cause that cannot improve
  without a launch, and the launch only happens after the wait returns. An early exit when the
  cause is `appNotRunning` and the probe confirms the app is not running would save that time
  outright. Check what it does to the attempt count assertions in `SendGuardTests`.
- There is an unconditional `waitOptions.sleep(1.0)` before the final refocus in
  `WhatsAppSender`, which is a hard sleep rather than a poll.
- The second `openURL` is necessary, the first payload is lost on a not yet running app, but
  it restarts the composer wait from zero after roughly 20 seconds have already passed.

Measure the real cold send wall clock before and after anything you change. Do not report a
speedup you did not time.

---

# Things that are UNTESTED, not broken. Test them, do not assume
- Every hotkey case (hold, tap, mash, release mid sentence, switch apps while holding, two
  back to back). Needs a human holding a key. `--test-stress` covers what can be automated and
  prints explicit SKIPs for the rest.
- Whether the recording pill visually reads as alive. The bar heights are measured by
  `--test-meter`, the appearance is not.
- Multiple displays and full screen. `ActiveScreen` and the confirm card's
  `.fullScreenAuxiliary` were both fixed in code and never seen on screen.
- Live microphone dBFS. A capture attempt returned zero samples, so the level numbers in the
  last report come from recorded fixtures, which are hotter than a real mic. The owner has
  deprioritised this; do not spend time on it unless asked.
- macOS 14 and 15. The platform floor was raised to macOS 26 because the SFSpeechRecognizer
  fallback, while real and complete in code, has never been executed on an older system. Do
  not re-advertise older support without running it on one.

# Verification you must run and paste, real output only
```
cd /Users/rishetmehra/Desktop/aohack/voicy
swift build 2>&1 | grep -c error:
./build.sh
./dist/Voicy.app/Contents/MacOS/Voicy --unit-tests --quiet | tail -3
./dist/Voicy.app/Contents/MacOS/Voicy --test-stress --quiet | tail -3
./dist/Voicy.app/Contents/MacOS/Voicy --test-audio-suite --quiet | tail -3
./dist/Voicy.app/Contents/MacOS/Voicy --test-stream | tail -3
./dist/Voicy.app/Contents/MacOS/Voicy --test-meter | tail -6
./dist/Voicy.app/Contents/MacOS/Voicy --test-latency | tail -8
```
Build must be 0 errors and every suite must pass. Latency must not regress: warm transcribe
under 250 ms, prewarmed mic start under 100 ms. Current state is 0 errors, all suites passing,
warm transcribe about 71 ms, prewarmed mic start about 12 ms, stress 19 passed 5 skipped.

There are pre-existing compiler warnings in `VoiceNoteWatcher.swift`, `TranscriberLocale.swift`,
`AudioFileLoader.swift` and `MicrophoneRecorder.convertAndAppend`. They are not yours and not
from this work, but if you touch those files, fix the warning properly rather than silencing it.

Add regression coverage to `Sources/Voicy/Testing/StressTests.swift` or
`Sources/Voicy/Send/SendGuardTests.swift` for every bug you actually fix. Cases that genuinely
cannot be automated must print an explicit SKIP with the reason. Never fake a pass.

# Report format
For each bug: the reproduction, the root cause, the fix, and the verification. Then anything
you could not fix or could not test, and why. An honest "not measured" is worth more to the
owner than a confident guess.

# Landing the work
Commit in small logical commits, short lowercase messages, then `git push origin main`.
Other workers share this tree. Never stash, revert, or checkout files you do not own, and
check `git status` before you `git add`, so you do not sweep somebody else's uncommitted work
into your commit. Only if a push is REJECTED, run `git pull --rebase origin main` and push
again. Delete this task file in your final commit.
