# UI work

## Frozen symbols (called from Core/Pipeline.swift — DO NOT change signatures)

- `RecordingIndicatorController` (class)
  - `init()`
  - `show()`
  - `hide()`
  - `updateLevel(_ rms: Float)`
- `ConfirmPanelController` (class)
  - `init()`
  - `show(payload: VoicyConfirmPayload, onSend: @escaping (VoicyRecipient, String) -> Void, onCancel: @escaping () -> Void, onDismiss: (() -> Void)? = nil)`
- `VoicyConfirmPayload` (struct): `recipients: [VoicyRecipient]`, `message: String`, `transcript: String?`, `init(recipients:message:transcript:)`
- `VoicyRecipient` (struct): `id, displayName, givenName, familyName, phoneDisplay, phoneE164, appName, appSymbol`, full memberwise `init`

## Log

- Read all UI/ files + grepped Core/Pipeline.swift for dependents (see above).
- Plan: route every magic number in RecordingIndicator/ConfirmCard/ConfirmPanel/SettingsView through Theme.swift; upgrade waveform to 32-bar rolling history; make avatar colour deterministic via `Theme.Colors.tint(for:)`; add accessibility labels/hints/traits; respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Done. Added `Theme.Layout` + `Theme.Motion.reduceMotionEnabled`/`plainFade`. Rewired RecordingIndicator, ConfirmCard, ConfirmPanel, SettingsView to Theme tokens only. `swift build` -> Build complete. `Voicy --unit-tests` -> all checks passed.

## Minimalism pass (2026-08-13)

Re-verified frozen surface against Core/Pipeline.swift (grep above) - unchanged: RecordingIndicatorController.init/show/hide/updateLevel(Float), ConfirmPanelController.init/show(payload:onSend:onCancel:onDismiss:), VoicyConfirmPayload, VoicyRecipient. No signatures touched.

BEFORE dimensions (from Theme.Layout as read):
- pillSize: 176x46 (+20pt top inset), waveform 32 bars x 3pt wide, 2pt spacing, frame 108x24, dot 10pt + 20pt halo. Pill padding: horizontal lg(16) x vertical md(12). Capsule bg .ultraThinMaterial, 1px border, shadow radius 14.
- cardWidth: 420, cardMinHeight: 120, padding Space.xl (32) all sides, corner radius xl(20), avatarSize 42, appIconBadgeSize 44. Display name font size 28. Message field in its own bordered sub-box with an uppercase "MESSAGE" label above it.

Owner verdict: capsule too big, panel reads like a banner not a HUD. Product is "a voice OS".

Plan:
1. RecordingIndicator: shrink pillSize to ~120x30, top inset to ~10, waveform to 14 bars x 2pt, frame ~52x14, dot 6pt/12pt halo, padding sm/xs, lighter shadow (radius 8), drop 1px border to a near-invisible hairline (opacity halved), corner = pill already.
2. ConfirmCard: cut cardWidth to ~300, cardMinHeight to ~90, padding to Space.md (12), corner to lg(16). Remove "MESSAGE" eyebrow label and its box-in-a-box; message becomes the single largest text (display size) directly under a compact recipient row (avatar+name+masked number on one line, no app icon badge — fold into the row). Shortcut hints become a single monospace footer line (keycap font), no per-hint icon glyphs, no Divider. Same treatment for ambiguous/notFound states: tighter, no dividers, smaller headline.
3. Send button becomes a small icon-only affordance to cut visual weight, kept accessible via label/hint.
4. All new sizes added as named tokens under Theme.Layout / Theme.Typography; no magic numbers in views.
5. Animations: kept spring-based, shortened `standard` response slightly for snappier settle; reduce-motion path untouched.

AFTER dimensions: pillSize 120x30 (top inset 10), waveform 14 bars x 2pt/1pt spacing, frame 52x14, dot 6/12. Card width 300, minHeight 90, padding 12, corner 16, avatar 34.

Non-obvious APIs verified:
- NSWorkspace.accessibilityDisplayShouldReduceMotion - https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion (already in use, unchanged)
- No new AppKit/SwiftUI APIs introduced beyond ones already present in the file (Capsule, RoundedRectangle, Font.system design: .monospaced, .ultraThinMaterial) - all pre-existing in this codebase.
