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

/// A small avatar with the contact's initials.
private struct Avatar: View {
    let recipient: VoicyRecipient
    private var initials: String {
        let g = recipient.givenName.prefix(1)
        let f = recipient.familyName.prefix(1)
        return String(g + f).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.accentColor.opacity(0.8), .accentColor.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
    }
}

/// The destination app icon badge.
private struct AppIconBadge: View {
    let symbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [.green.opacity(0.85), .green.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
    }
}

/// A subtle shortcut hint chip shown at the bottom of the card.
private struct ShortcutHint: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}
/// The SwiftUI confirm card. The panel hosts this inside an NSPanel.
struct ConfirmCardView: View {
    @Bindable var model: ConfirmModel
    var onSend: () -> Void
    var onCancel: () -> Void
    var onPick: (Int) -> Void

    @State private var appeared = false
    @FocusState private var bodyFocused: Bool

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
        Group {
            if model.isNotFound {
                notFoundView
            } else if model.isAmbiguous {
                ambiguousView
            } else if let recipient = model.primary {
                resolvedView(recipient)
            } else {
                Color.clear.frame(width: 420, height: 120)
            }
        }
        .frame(width: 420)
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        // Subtle scale + fade entrance, settling within ~300 ms.
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .onChange(of: model.editingRequested) { _, _ in
            bodyFocused = true
        }
    }

    // MARK: Resolved — one recipient

    private func resolvedView(_ recipient: VoicyRecipient) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                AppIconBadge(symbol: recipient.appSymbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipient.displayName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(recipient.phoneDisplay)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            Divider().opacity(0.5)

            // Editable message body — the REAL words, never a summary.
            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                TextField("Message", text: $model.message, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(bodyFocused ? 0.5 : 0.0), lineWidth: 1))
                    .focused($bodyFocused)
            }

            HStack(spacing: 16) {
                ShortcutHint(text: "Enter  Send", symbol: "return")
                ShortcutHint(text: "Esc  Cancel", symbol: "escape")
                ShortcutHint(text: "⌘E  Edit", symbol: "pencil")
                Spacer()
                Button(action: onSend) {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ambiguous — "Which <name>?"

    private var ambiguousView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which \(firstGivenName)?")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("I found a few matching contacts. Pick one.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, recipient in
                    candidateRow(recipient, selected: index == model.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 16) {
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
    private func candidateRow(_ recipient: VoicyRecipient, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Avatar(recipient: recipient)
            VStack(alignment: .leading, spacing: 1) {
                (Text(recipient.givenName) +
                 Text(recipient.familyName.isEmpty ? "" : " " + recipient.familyName)
                    .fontWeight(.bold))
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                Text(recipient.phoneDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: Not found — show the transcript

    private var notFoundView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("No contact found")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Text("I couldn't match a contact to what you said. Here's what I heard:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let transcript = model.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 15, design: .serif))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
            } else {
                Text("No transcript available.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            HStack(spacing: 16) {
                ShortcutHint(text: "Esc  Close", symbol: "escape")
                Spacer()
            }
        }
    }
}