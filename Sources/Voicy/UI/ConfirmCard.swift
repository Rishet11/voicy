import SwiftUI
import Observation
import Contacts
import AppKit

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
    var heardName: String? {
        guard let transcript, !transcript.isEmpty else { return nil }
        if case .parsed(let intent) = IntentParser().parse(transcript) {
            return intent.recipientText
        }
        return nil
    }
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

/// A command-palette-style footer: small, monospace, unobtrusive key hints
/// joined on one line. Decorative; the real hints live on the controls.
private struct HintFooter: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.keycap(.medium))
            .foregroundStyle(Theme.Colors.palette(scheme).textTertiary)
            .accessibilityHidden(true)
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
        .padding(Theme.Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Corner.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Corner.lg, style: .continuous)
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
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // One line: avatar, name, masked number. No app icon badge, no
            // section header — this is a glance-and-confirm surface.
            HStack(spacing: Theme.Space.sm) {
                Avatar(recipient: recipient)
                Text(recipient.displayName)
                    .font(Theme.Typography.headline())
                    .lineLimit(1)
                Text(recipient.phoneDisplay)
                    .font(Theme.Typography.caption())
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(recipient.displayName), \(recipient.phoneDisplay), sending via \(recipient.appName)")

            // Editable message body — the REAL words, verbatim, never trimmed,
            // auto-capitalized or tidied. The largest, most important text on
            // the card.
            TextField("Message", text: $model.message, axis: .vertical)
                .font(Theme.Typography.body(.medium))
                .lineSpacing(3)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($bodyFocused)
                .accessibilityLabel("Message body, editable")
                .accessibilityValue(model.message)
                .accessibilityHint("Your exact words. Edit if needed, then press Return to send.")

            HStack(spacing: Theme.Space.sm) {
                HintFooter(text: "↵ send  ·  esc cancel  ·  ⌘e edit")
                Spacer(minLength: 0)
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(Theme.Typography.callout(.semibold))
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xs)
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
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Which \(firstGivenName)?")
                .font(Theme.Typography.headline())

            VStack(spacing: Theme.Space.xs) {
                ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, recipient in
                    candidateRow(recipient, selected: index == model.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
            .accessibilityElement(children: .contain)

            HintFooter(text: "↑↓ choose  ·  ↵ pick  ·  esc cancel")
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

    // MARK: Not found — actionable, specific next step

    private var notFoundView: some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            let contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
            let permissionMissing = contactsStatus == .denied ||
                contactsStatus == .restricted || contactsStatus == .notDetermined

            Text(permissionMissing ? "Contacts access is needed" : "No contact matched")
                .font(Theme.Typography.headline())
                .foregroundStyle(palette.textSecondary)

            if permissionMissing {
                Text("Voicy cannot search your contacts until Contacts access is enabled in System Settings.")
                    .font(Theme.Typography.body(.medium))
                    .lineSpacing(3)
            } else {
                let name = model.heardName ?? "the name in your message"
                Text("No contact matched \"\(name)\". Check the name and try again.")
                    .font(Theme.Typography.body(.medium))
                    .lineSpacing(3)
            }

            HStack(spacing: Theme.Space.sm) {
                if permissionMissing {
                    Button("Open Contacts Settings") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens System Settings where Contacts access can be enabled.")
                } else {
                    Button("Close and try again", action: onCancel)
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
                HintFooter(text: "esc cancel")
            }
        }
    }
}
