# Send path safety

Audit of every code path that can produce an outbound WhatsApp message, plus the
tests that keep those paths closed. Line numbers refer to the state of the tree
at audit time (commit `16f2ae6` plus in-flight worker edits); the "after" notes
record what changed.

## 1. Audit map (as found)

Files read in full: `Send/WhatsAppSender.swift`, `Send/WhatsAppAccessibility.swift`,
`Send/WhatsAppDeepLink.swift`, `Send/Blocklist.swift`, plus the callers in
`Core/Pipeline.swift` and `UI/ConfirmPanel.swift`.

### Path A: confirm card -> auto-send with a synthesized Return (FATAL, removed)

`Core/Pipeline.swift:381` checked `WhatsAppAccessibility.isTrusted(prompt: false)`
and, when Accessibility was already granted, called
`WhatsAppSender.send(..., dryRun: false)` (`Pipeline.swift:385`).

`WhatsAppSender.send` then:
- opened the deep link, which pre-fills the composer (`WhatsAppSender.swift:92`)
- polled the Accessibility tree until WhatsApp was frontmost with a focused text
  input (`WhatsAppSender.swift:98`, `WhatsAppAccessibility.swift:71`)
- posted a synthetic Return into WhatsApp via `CGEventPost`
  (`WhatsAppSender.swift:106` -> `WhatsAppAccessibility.swift:90-103`)
- polled the composer to confirm it emptied (`WhatsAppSender.swift:109`)

Answers for this path as found:
- Could it fire without an explicit human confirmation? No. It was reachable only
  from `ConfirmPanelController.send()` (`ConfirmPanel.swift:111`), which runs on
  Enter or a click on the confirm card.
- Could it fire without a keystroke the user made? Yes. The Return that committed
  the message inside WhatsApp was synthesized by Voicy, not typed by the user.
  This is exactly the WhatsApp send-path automation the research report calls a
  permanent-ban risk: from WhatsApp's side it is indistinguishable from a bot
  driving the client.

Removed. `WhatsAppSender` no longer posts keystrokes, `postReturn` is gone from
`WhatsAppAccessibility`, and `Pipeline.handleSend` now takes the prefill path
unconditionally. See section 2.

### Path B: confirm card -> deep-link prefill only (kept, acceptable)

`Core/Pipeline.swift:395` `openPrefilledInWhatsApp` opens
`whatsapp://send?phone=...&text=...` and stops. The message sits unsent in the
compose field until the user presses Return themselves inside WhatsApp.

Answers for this path as found:
- Without explicit human confirmation? No, same confirm card gate.
- Without a user keystroke? The chat window opens and text is prefilled without a
  keystroke inside WhatsApp, but nothing is sent. No message leaves the account
  without the user's own Return.

This is the only send path that remains.

### Path C: "not found" confirm card (no send)

`Core/Pipeline.swift:255` shows a confirm card with no recipients when resolution
fails. `ConfirmPanelController.send()` returns early when there is no recipient
(`ConfirmPanel.swift:112`), and `handleSend` returns early when the recipient has
no phone number (`Pipeline.swift:363`). No outbound path.

### Path D: non-WhatsApp apps (no send)

`Core/Pipeline.swift:369` refuses when `intent.app != .whatsapp` instead of
faking a send. No outbound path.

### Path E: voice notes (no send)

`VoiceNotes/VoiceNoteWatcher.swift` + `VoiceNotePipeline.swift` are read-only:
watch a directory for `.opus`, decode, transcribe, hand the text to an
`onResult` closure. There is no sender import and no reply path. Verified by
grep: no reference to `WhatsAppSender`, `WhatsAppDeepLink`, `postReturn`, or
`NSWorkspace.open` anywhere under `VoiceNotes/`.

### Path F: test harness / dry run (no send)

`WhatsAppSender.send(dryRun: true)` logs intent and returns before touching
`NSWorkspace` or the Accessibility tree (`WhatsAppSender.swift:73-82`).

### Kill switch coverage as found (hole)

The blocklist was checked only inside `WhatsAppSender.send`
(`WhatsAppSender.swift:51-60`). Path B (`openPrefilledInWhatsApp`) never
consulted it, so a blocklisted contact's chat could still be opened with the
message prefilled. Once Path A was removed, Path B is the *only* send path, so
the blocklist would have covered nothing at all.

### Blocklist bypasses as found

`Blocklist.contains` (`Blocklist.swift:38-42`) trimmed whitespace and did an
exact `Set<String>` lookup. Every one of these got through a blocklist
containing `"919876543210"` / `"Rahul Sharma"`:

| Bypass | Why it worked |
| --- | --- |
| `+91 98765 43210` | different string than the stored digits |
| `098765 43210` | trunk-prefix zero, different string |
| `9876543210` | no country code, different string |
| `+91-98765-43210` | hyphens, different string |
| `rahul sharma` | case-sensitive lookup |
| `Rahul  Sharma` | collapsed inner whitespace not handled |
| `Rahúl Sharma` | diacritics not folded |

Aliases and phonetic matches are a separate concern: the blocklist sees whatever
name the resolver produced, so blocking a display name never blocked the alias
that resolves to the same number. Blocking by number is the durable protection,
which is why number normalization matters most.

### Visible kill switch: not implemented as found

There is no user-visible never-send control. `grep -rniE "kill.?switch|neverSend"`
over `UI/`, `Core/` and `Diagnostics/` returns only
`Diagnostics/SelfTest.swift:55 checkBlocklist()`. The only mechanism is a JSON
file at `~/Library/Application Support/Voicy/blocklist.json` that the user has to
know about and hand-edit. Recorded here rather than papered over; the mechanism
below is made airtight, but the UI affordance is still missing.

### Confirmation integrity as found (clean)

`ConfirmPanelController.send()` (`ConfirmPanel.swift:111-116`) reads the recipient
and body straight off the model that the card is rendering, then calls back:

```
let recipient = model.primary ?? model.selected
let body = model.message
dismiss()
onSend?(recipient, body)
```

`Pipeline.handleSend` uses that `recipient.phoneE164` and that `body` verbatim
(`Pipeline.swift:362`, `385`). There is no re-resolution after confirm and no
post-confirm mutation of the body: `TranscriptCleaner` runs *before* the payload
is built (`Pipeline.swift:317-323`), so the user sees the cleaned text they will
send. The "confirms Rahul, sends to Rohit" bug is not present.

## 2. Changes made

(filled in as the work lands, see log below)

## Log

- Audit map written from a full read of the four `Send/` files plus the
  `Core/Pipeline.swift` and `UI/ConfirmPanel.swift` call sites.
