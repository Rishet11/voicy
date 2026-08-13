import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import CoreGraphics
import Observation
import Speech
import SwiftUI

// MARK: - Settings (progressive permissions)
//
// Implements the binding permission model (CLAUDE.md): Tier-1 permissions are
// required at launch; Tier-2 are OPTIONAL upgrades the user opts into here. Each
// Tier-2 toggle states plainly what it unlocks, which macOS permission it needs,
// and offers a button that opens the exact System Settings pane.

/// The System Settings Privacy panes each permission maps to. Voicy never tries
/// to grant these programmatically (macOS forbids it); it only opens the right
/// pane and lets the user decide.
enum SystemSettingsPane {
    static let base = "x-apple.systempreferences:com.apple.preference.security?Privacy_"

    static let microphone = makeURL("Microphone")
    static let speechRecognition = makeURL("SpeechRecognition")
    static let contacts = makeURL("Contacts")
    static let listenEvent = makeURL("ListenEvent")
    static let accessibility = makeURL("Accessibility")
    static let soundInput = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?Input")!

    private static func makeURL(_ pane: String) -> URL {
        URL(string: base + pane)!
    }
}

/// UI-facing model for the Settings window. Owns the persisted Tier-2 feature
/// toggles and reads live permission state from the macOS APIs whenever the
/// window appears. Lives entirely inside UI/ so it never reaches into other
/// workers' directories.
@MainActor
@Observable
final class SettingsModel {

    // MARK: Tier-2 feature toggles (persisted in UserDefaults)

    /// "Hold a key to talk" -> grants Input Monitoring (Right-Option push-to-talk).
    /// When off, Voicy uses the Carbon hotkey (Ctrl+Space) which needs no permission.
    var holdToTalk: Bool {
        didSet { UserDefaults.standard.set(holdToTalk, forKey: Self.tier2Key("holdToTalk")) }
    }

    /// "Send without pressing Enter" -> grants Accessibility (synthetic Return).
    /// When off, WhatsApp opens pre-filled and the user presses Enter themselves.
    var sendWithoutEnter: Bool {
        didSet { UserDefaults.standard.set(sendWithoutEnter, forKey: Self.tier2Key("sendWithoutEnter")) }
    }

    /// Bumped on every refresh so the view re-reads the live permission APIs.
    private(set) var refreshVersion = 0

    private static func tier2Key(_ suffix: String) -> String { "voicy.tier2.\(suffix)" }

    init() {
        let d = UserDefaults.standard
        holdToTalk = d.bool(forKey: Self.tier2Key("holdToTalk"))
        sendWithoutEnter = d.bool(forKey: Self.tier2Key("sendWithoutEnter"))
    }

    // MARK: Live permission state

    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var speechRecognitionGranted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    var contactsGranted: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Actions

    func refresh() { refreshVersion += 1 }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - SwiftUI view

/// The Settings window body. Two sections mirroring the permission model:
/// required (Tier-1) permissions with a status row each, and optional (Tier-2)
/// upgrades as toggles that describe what they unlock and which permission they
/// need.
struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: SettingsModel
    var onClose: () -> Void = {}

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    tier1Section
                    tier2Section
                    footerNote
                }
                .padding(Theme.Space.xl - 4)
            }
            Divider()
            footerButtons
        }
        .frame(width: 440)
        .background(palette.backgroundDeep)
        .id(model.refreshVersion) // re-evaluate on refresh -> re-read live permissions
        .onAppear {
            model.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        let palette = Theme.Colors.palette(scheme)
        return HStack(spacing: Theme.Space.md) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(palette.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Voicy Settings")
                    .font(Theme.Typography.headline(.bold))
                Text("Permissions and the features they unlock")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.Space.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: Tier 1 - required

    private var tier1Section: some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Required - needed for Voicy to work",
                         symbol: "checkmark.shield")

            permissionRow(
                title: "Microphone",
                detail: "Records your voice so it can be transcribed on-device.",
                granted: model.microphoneGranted,
                pane: SystemSettingsPane.microphone
            )

            permissionRow(
                title: "Speech Recognition",
                detail: "Turns the captured audio into the words you spoke.",
                granted: model.speechRecognitionGranted,
                pane: SystemSettingsPane.speechRecognition
            )

            permissionRow(
                title: "Contacts",
                detail: "Turns the name you speak into the right WhatsApp number.",
                granted: model.contactsGranted,
                pane: SystemSettingsPane.contacts
            )

            Text("With only these two, Voicy is fully functional: hotkey is Control+Space, and sending opens WhatsApp pre-filled for you to confirm.")
                .font(Theme.Typography.caption())
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: Tier 2 - optional upgrades

    private var tier2Section: some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Optional upgrades - each one a choice",
                         symbol: "slider.horizontal.3")

            tier2Row(
                toggle: $model.holdToTalk,
                title: "Hold a key to talk",
                unlocks: "Push-to-talk on a bare modifier (Right-Option).",
                permission: "Input Monitoring",
                granted: model.inputMonitoringGranted,
                pane: SystemSettingsPane.listenEvent
            )

            tier2Row(
                toggle: $model.sendWithoutEnter,
                title: "Send without pressing Enter",
                unlocks: "Completes the send with a synthetic Return once WhatsApp has focus.",
                permission: "Accessibility",
                granted: model.accessibilityTrusted,
                pane: SystemSettingsPane.accessibility
            )

            Text("Revoking a Tier-2 permission later degrades cleanly - Voicy keeps working, just without the optional shortcut.")
                .font(Theme.Typography.caption())
                .foregroundStyle(palette.textSecondary)
        }
    }

    private var footerNote: some View {
        Text("Speech recognition runs entirely on-device. Audio never leaves your Mac.")
            .font(Theme.Typography.caption())
            .foregroundStyle(Theme.Colors.palette(scheme).textSecondary)
    }

    // MARK: Footer

    private var footerButtons: some View {
        HStack {
            Button("Quit Voicy", role: .destructive) { model.quit() }
                .accessibilityHint("Quits Voicy entirely.")
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes Settings.")
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
    }

    // MARK: Shared row builders

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        let palette = Theme.Colors.palette(scheme)
        return Label {
            Text(text)
                .font(Theme.Typography.callout(.semibold))
        } icon: {
            Image(systemName: symbol)
                .font(Theme.Typography.callout(.semibold))
                .foregroundStyle(palette.textSecondary)
        }
        .foregroundStyle(palette.textSecondary)
        .accessibilityAddTraits(.isHeader)
    }

    /// Tier-1 status row: name, what it does, granted badge, and (when missing)
    /// an "Open System Settings" button for the exact pane.
    private func permissionRow(title: String,
                               detail: String,
                               granted: Bool,
                               pane: URL) -> some View {
        let palette = Theme.Colors.palette(scheme)
        return HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.body(.semibold))
                Text(detail).font(Theme.Typography.caption()).foregroundStyle(palette.textSecondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.caption(.medium))
                    .foregroundStyle(palette.success)
            } else {
                Button("Open System Settings") { model.open(pane) }
                    .controlSize(.small)
                    .accessibilityHint("Opens System Settings to grant \(title) access.")
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Corner.md, style: .continuous)
            .fill(palette.surface))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail) \(granted ? "Granted" : "Not granted")")
    }

    /// Tier-2 row: an on/off toggle for the feature plus, when it is ON but the
    /// permission is not yet granted, the button to open the needed pane.
    private func tier2Row(toggle: Binding<Bool>,
                          title: String,
                          unlocks: String,
                          permission: String,
                          granted: Bool,
                          pane: URL) -> some View {
        let palette = Theme.Colors.palette(scheme)
        return VStack(alignment: .leading, spacing: Theme.Space.sm + 2) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Typography.body(.semibold))
                    Text(unlocks).font(Theme.Typography.caption()).foregroundStyle(palette.textSecondary)
                }
                Spacer()
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(title)
                    .accessibilityHint("Requires \(permission).")
            }

            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                Text("Needs: \(permission)")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(palette.textSecondary)
                Spacer()

                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.caption(.medium))
                        .foregroundStyle(palette.success)
                } else if toggle.wrappedValue {
                    Button("Open System Settings") { model.open(pane) }
                        .controlSize(.small)
                        .accessibilityHint("Opens System Settings to grant \(permission) access.")
                } else {
                    Text("Off - not required")
                        .font(Theme.Typography.caption())
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Corner.md, style: .continuous)
            .fill(palette.surface))
    }
}
