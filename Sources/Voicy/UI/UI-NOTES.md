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
