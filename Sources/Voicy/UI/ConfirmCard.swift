import SwiftUI
import Observation

// MARK: - Confirm card
//
// The signature moment: the user sees the REAL recipient name, the REAL number
// (so a wrong match is catchable at a glance), and the REAL message body in an
// editable field. Never a generic summary — generic confirmations train people
// to click through blindly (Nielsen Norman).
//
// The card has three states, all driven by `ConfirmModel`:
//   - resolved   (one recipient): name large, number under, editable body, app icon
//   - ambiguous  (many recipients): "Which <name>?" with a selectable list
//   - not found  (zero recipients): shows the raw transcript

/// Backing state for the confirm card. Owned by the panel controller; the view
/// reads and mutates it. `@Observable` so the view tracks every change.
@MainActor
@Observable
final class ConfirmModel {
    var recipients: [VoicyRecipient] = []
    var message: String = ""
    var transcript: String? = nil
    var selectedIndex: Int = 0
    /// Set by the panel when Cmd+E is pressed so the view focuses the body field.
    var editingRequested = false

    var isAmbiguous: Bool { recipients.count > 1 }
    var isNotFound: Bool { recipients.isEmpty }
    var primary: VoicyRecipient? { recipients.count == 1 ? recipients[0] : nil }
    var selected: VoicyRecipient? {
        guard !recipients.isEmpty else { return nil }
        return recipients[min(max(selectedIndex, 0), recipients.count - 1)]
    }
}

/// A small avatar with the contact's initials. Colour is derived deterministically
/// from the contact's stable identifier so the same person is always the same
/// colour, regardless of display-name changes.
private struct Avatar: View {
    @Environment(\.colorScheme) private var scheme
    let recipient: VoicyRecipient
    private var initials: String {
        let g = recipient.givenName.prefix(1)
        let f = recipient.familyName.prefix(1)
        return String(g + f).uppercased()
    }

    var body: some View {
        let tint = Theme.Colors.tint(for: recipient.id)
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(Theme.Typography.callout(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
        .accessibilityHidden(true) // the containing row supplies the spoken label
    }
}

/// The destination app icon badge.
private struct AppIconBadge: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Corner.md, style: .continuous)
                .fill(LinearGradient(colors: [palette.success.opacity(0.85), palette.success.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: Theme.Layout.appIconBadgeSize, height: Theme.Layout.appIconBadgeSize)
        .accessibilityHidden(true)
    }
}

/// A subtle shortcut hint chip shown at the bottom of the card.
private struct ShortcutHint: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(Theme.Typography.caption(.medium))
        }
        .foregroundStyle(Theme.Colors.palette(scheme).textSecondary)
        .accessibilityHidden(true) // shortcuts are also exposed as hints on the controls
    }
}

/// The SwiftUI confirm card. The panel hosts this inside an NSPanel.
struct ConfirmCardView: View {
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: ConfirmModel
    var onSend: () -> Void
    var onCancel: () -> Void
    var onPick: (Int) -> Void

    @State private var appeared = false
    @FocusState private var bodyFocused: Bool
    private var reduceMotion: Bool { Theme.Motion.reduceMotionEnabled }

    init(model: ConfirmModel,
         onSend: @escaping () -> Void,
         onCancel: @escaping () -> Void,
         onPick: @escaping (Int) -> Void) {
        self.model = model
        self.onSend = onSend
        self.onCancel = onCancel
        self.onPick = onPick
    }

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        Group {
            if model.isNotFound {
                notFoundView
            } else if model.isAmbiguous {
                ambiguousView
            } else if let recipient = model.primary {
                resolvedView(recipient)
            } else {
                Color.clear.frame(width: Theme.Layout.cardWidth, height: Theme.Layout.cardMinHeight)
            }
        }
        .frame(width: Theme.Layout.cardWidth)
        .padding(Theme.Space.xl)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Corner.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Corner.xl, style: .continuous)
            .strokeBorder(palette.border, lineWidth: 1))
        .modifier(Theme.surfaceShadow(scheme))
        // Subtle scale + fade entrance, settling within ~300 ms. Falls back to a
        // plain fade when Reduce Motion is on, per
        // https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .onAppear {
            withAnimation(reduceMotion ? Theme.Motion.plainFade : Theme.Motion.standard) {
                appeared = true
            }
        }
        .onChange(of: model.editingRequested) { _, _ in
            bodyFocused = true
        }
    }

    // MARK: Resolved — one recipient

    private func resolvedView(_ recipient: VoicyRecipient) -> some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                AppIconBadge(symbol: recipient.appSymbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipient.displayName)
                        .font(Theme.Typography.display())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(recipient.phoneDisplay)
                        .font(Theme.Typography.callout(.medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(recipient.displayName), \(recipient.phoneDisplay), sending via \(recipient.appName)")

            Divider().opacity(0.5)

            // Editable message body — the REAL words, verbatim, never trimmed,
            // auto-capitalized or tidied. Generous line height and no truncation.
            VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                Text("Message")
                    .font(Theme.Typography.micro())
                    .foregroundStyle(palette.textSecondary)
                    .textCase(.uppercase)
                    .accessibilityHidden(true)
                TextField("Message", text: $model.message, axis: .vertical)
                    .font(Theme.Typography.body())
                    .lineSpacing(4)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(Theme.Space.sm + 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Corner.sm + 2, style: .continuous)
                        .fill(palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Corner.sm + 2, style: .continuous)
                        .strokeBorder(palette.accent.opacity(bodyFocused ? 0.5 : 0.0), lineWidth: 1))
                    .focused($bodyFocused)
                    .accessibilityLabel("Message body, editable")
                    .accessibilityValue(model.message)
                    .accessibilityHint("Your exact words. Edit if needed, then press Return to send.")
            }

            HStack(spacing: Theme.Space.lg) {
                ShortcutHint(text: "Enter  Send", symbol: "return")
                ShortcutHint(text: "Esc  Cancel", symbol: "escape")
                ShortcutHint(text: "⌘E  Edit", symbol: "pencil")
                Spacer()
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(Theme.Typography.callout(.semibold))
                        .padding(.horizontal, Theme.Space.md + 2)
                        .padding(.vertical, Theme.Space.sm - 1)
                        .background(Capsule().fill(palette.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send message")
                .accessibilityHint("Sends to \(recipient.displayName) via \(recipient.appName)")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    // MARK: Ambiguous — "Which <name>?"

    private var ambiguousView: some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.md + 2) {
            Text("Which \(firstGivenName)?")
                .font(Theme.Typography.title())
            Text("I found a few matching contacts. Pick one.")
                .font(Theme.Typography.callout())
                .foregroundStyle(palette.textSecondary)

            VStack(spacing: Theme.Space.xs + 2) {
                ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, recipient in
                    candidateRow(recipient, selected: index == model.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
            .accessibilityElement(children: .contain)

            Divider().opacity(0.5)

            HStack(spacing: Theme.Space.lg) {
                ShortcutHint(text: "↑↓  Choose", symbol: "arrow.up.arrow.down")
                ShortcutHint(text: "Enter  Pick", symbol: "return")
                ShortcutHint(text: "Esc  Cancel", symbol: "escape")
                Spacer()
            }
        }
    }

    private var firstGivenName: String {
        model.recipients.first?.givenName ?? "them"
    }

    /// A selectable candidate row. The family (last) name is emphasized so a
    /// wrong match is obvious; the number underneath disambiguates further.
    /// Keyboard-navigable via arrow keys in `ConfirmPanelController`.
    private func candidateRow(_ recipient: VoicyRecipient, selected: Bool) -> some View {
        let palette = Theme.Colors.palette(scheme)
        return HStack(spacing: Theme.Space.md) {
            Avatar(recipient: recipient)
            VStack(alignment: .leading, spacing: 1) {
                (Text(recipient.givenName) +
                 Text(recipient.familyName.isEmpty ? "" : " " + recipient.familyName)
                    .fontWeight(.bold))
                    .font(Theme.Typography.body())
                    .foregroundStyle(palette.textPrimary)
                Text(recipient.phoneDisplay)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected ? palette.accent : palette.textTertiary)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.sm + 2, style: .continuous)
                .fill(selected ? palette.accent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Corner.sm + 2, style: .continuous)
                .strokeBorder(selected ? palette.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recipient.givenName) \(recipient.familyName), \(recipient.phoneDisplay)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selected ? "Currently selected. Press Return to confirm." : "Double-tap to select.")
    }

    // MARK: Not found — show the transcript, phrased as a question

    private var notFoundView: some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.md + 2) {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 24))
                    .foregroundStyle(palette.textSecondary)
                Text("Who did you mean?")
                    .font(Theme.Typography.title())
            }
            Text("I didn't catch a contact in this. Here's exactly what I heard — pick who it should go to.")
                .font(Theme.Typography.callout())
                .foregroundStyle(palette.textSecondary)

            if let transcript = model.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(Theme.Typography.body())
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Corner.sm + 2, style: .continuous)
                        .fill(palette.surface))
                    .accessibilityLabel("What I heard: \(transcript)")
            } else {
                Text("No transcript available.")
                    .font(Theme.Typography.callout())
                    .foregroundStyle(palette.textSecondary)
            }

            Divider().opacity(0.5)

            HStack(spacing: Theme.Space.lg) {
                ShortcutHint(text: "Esc  Close", symbol: "escape")
                Spacer()
            }
        }
    }
}
