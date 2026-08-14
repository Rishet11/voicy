import AppKit
import SwiftUI

// MARK: - Confirm panel
//
// Hosts `ConfirmCardView` in an NSPanel centered on screen, and turns the
// keyboard into the product's signature interactions:
//   - Enter        sends (or picks, when ambiguous)
//   - Esc          cancels
//   - Cmd+E        focuses the message body for editing
//   - ↑ / ↓        move the selection in the ambiguous picker
//
// The panel is floating above normal windows but activates only when shown so
// the confirm interaction genuinely intercepts keys (a confirmation dialog
// should have focus; the *recording* pill is the one that must not steal it).

/// Key codes for the shortcuts we answer to.
private enum Key {
    static let escape: UInt16 = 53
    static let `return`: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let up: UInt16 = 126
    static let down: UInt16 = 125
    static let e: UInt16 = 14
}

@MainActor
public final class ConfirmPanelController {
    private let model = ConfirmModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<ConfirmCardView>
    private var localMonitor: Any?
    private var onSend: ((VoicyRecipient, String) -> Void)?
    private var onCancel: (() -> Void)?
    private var onDismiss: (() -> Void)?

    public init() {
        let host = NSHostingView(rootView: ConfirmCardView(
            model: model,
            onSend: { },
            onCancel: { },
            onPick: { _ in }
        ))
        self.hosting = host

        let panel = NSPanel(contentRect: NSRect(origin: .zero,
                                                size: NSSize(width: Theme.Layout.cardWidth,
                                                             height: Theme.Layout.cardWidth * 0.7)),
                            styleMask: [.borderless],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        // `.fullScreenAuxiliary` is required, not decorative. Without it this
        // panel cannot join a full screen Space, so a user who finishes speaking
        // inside a full screen app sees the recording pill (which does set the
        // flag) and then no confirm card at all. Since the card is mandatory
        // before any send, that silently makes the whole app unusable in full
        // screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        self.panel = panel
    }

    /// Show the confirm card centered, wired to the given callbacks.
    /// - Parameters:
    ///   - payload: the recipient(s), message and optional transcript.
    ///   - onSend: called with the chosen recipient and the (possibly edited) body.
    ///   - onCancel: called when the user cancels.
    ///   - onDismiss: called whenever the panel closes (send or cancel).
    public func show(payload: VoicyConfirmPayload,
                     onSend: @escaping (VoicyRecipient, String) -> Void,
                     onCancel: @escaping () -> Void,
                     onDismiss: (() -> Void)? = nil) {
        self.onSend = onSend
        self.onCancel = onCancel
        self.onDismiss = onDismiss

        model.recipients = payload.recipients
        model.message = payload.message
        model.transcript = payload.transcript
        model.selectedIndex = 0
        model.editingRequested = false

        // Point the shared view at the real handlers.
        hosting.rootView = ConfirmCardView(
            model: model,
            onSend: { [weak self] in self?.send() },
            onCancel: { [weak self] in self?.cancel() },
            onPick: { [weak self] index in self?.pick(index) }
        )

        sizeToFit()
        positionCentered()
        installMonitor()

        // A confirmation dialog is the thing the user is acting on now, so it
        // takes focus on purpose (the recording pill does not).
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        removeMonitor()
        panel.orderOut(nil)
        onDismiss?()
    }

    public var isVisible: Bool { panel.isVisible }

    // MARK: Actions

    private func send() {
        guard let recipient = model.primary ?? model.selected else { return }
        let body = model.message
        dismiss()
        onSend?(recipient, body)
    }

    private func cancel() {
        dismiss()
        onCancel?()
    }

    private func pick(_ index: Int) {
        model.selectedIndex = index
        guard let chosen = model.selected else { return }
        // Collapse to a single recipient so the card flips to the resolved
        // (name + number + message) state; the user confirms with Enter.
        model.recipients = [chosen]
        model.selectedIndex = 0
    }

    private func focusEditing() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.editingRequested = true
    }
// MARK: Keyboard

    private func installMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.handleKey(event)
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    /// Maps a key event to a card action. Returns `nil` to swallow the event.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        // Cmd+E focuses the body field for editing.
        if cmd && (code == Key.e || event.charactersIgnoringModifiers?.lowercased() == "e") {
            focusEditing()
            return nil
        }

        // Esc cancels.
        if code == Key.escape {
            cancel()
            return nil
        }

        // Enter sends (resolved) or picks (ambiguous). Shift+Enter is passed
        // through so the body field can insert a newline while editing.
        if code == Key.return || code == Key.keypadEnter {
            if shift { return event }
            if model.isAmbiguous { pick(model.selectedIndex) } else { send() }
            return nil
        }

        // Arrow keys navigate the ambiguous picker.
        if model.isAmbiguous, code == Key.up || code == Key.down {
            let count = model.recipients.count
            guard count > 0 else { return nil }
            let delta = code == Key.down ? 1 : -1
            model.selectedIndex = (model.selectedIndex + delta + count) % count
            return nil
        }

        // Number keys are a fast, explicit choice in the candidate list.
        if model.isAmbiguous,
           let character = event.charactersIgnoringModifiers?.first,
           let number = character.wholeNumberValue,
           number >= 1, number <= model.recipients.count {
            pick(number - 1)
            return nil
        }

        return event
    }

    // MARK: Layout

    private func sizeToFit() {
        let width: CGFloat = Theme.Layout.cardWidth
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, Theme.Layout.cardMinHeight)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    private func positionCentered() {
        // The screen the user is actually on. See ActiveScreen.
        guard let screen = ActiveScreen.current else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
