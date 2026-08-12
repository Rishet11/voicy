import AppKit
import SwiftUI

// MARK: - Settings window
//
// Hosts `SettingsView` in a normal, closable window (not a borderless panel:
// Settings is a deliberate, key-owning interaction like the confirm panel).
// Exposed so W1 (AppDelegate) can wire a "Settings..." menu item to
// `SettingsWindowController.shared.show()`.

/// Owns the Settings window and keeps it alive for the app's lifetime so the
/// first open is instant and the model (permission state + toggles) is retained.
@MainActor
public final class SettingsWindowController {
    public static let shared = SettingsWindowController()

    private let model = SettingsModel()
    private let window: NSWindow

    private init() {
        let hosting = NSHostingView(rootView: SettingsView(
            model: model,
            onClose: { SettingsWindowController.shared.close() }
        ))

        let size = NSSize(width: 440, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voicy Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    /// Bring the Settings window to the front, creating state fresh from the
    /// live permission APIs on appear. Safe to call from a menu item action.
    public func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window.orderOut(nil)
    }

    public var isVisible: Bool { window.isVisible }
}