import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Raw Accessibility-tree primitives for the WhatsApp send path.
///
/// Every probe reads WhatsApp's Accessibility tree through its PID, so none of
/// them requires WhatsApp to be frontmost. The submission primitives likewise
/// target WhatsApp specifically (`AXPress` on the send button, or a Return
/// delivered to the app's PID via `CGEventPostToPid`) and never move focus:
/// the whole send runs in the background while the user keeps working.
///
/// There is no `osascript` anywhere either: macOS attributes Accessibility
/// permission to the process that *requests* it, so shelling out would put the
/// prompt under Terminal and silently break the trust check.
enum WhatsAppAccessibility {

    private static let mainBundleIdentifier = "net.whatsapp.WhatsApp"

    /// Checks whether this process holds Accessibility permission, prompting
    /// the user if `prompt` is true and the app is trusted-eligible.
    static func isTrusted(prompt: Bool) -> Bool {
        // Swift 6 strict concurrency rejects the Carbon global `kAXTrustedCheckOptionPrompt`
        // (a mutable global). Its documented value is the literal below.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Process identity

    /// PID of the running WhatsApp application, whether or not it is frontmost.
    /// Nil means the app is not running at all, which is a distinct failure
    /// from "running but not ready".
    static func whatsAppPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == mainBundleIdentifier
        }?.processIdentifier
    }

    static func isWhatsApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == mainBundleIdentifier
    }

    /// Asks a running WhatsApp process to reopen its main window, matching a
    /// Dock click without activating the app. This is needed because a
    /// windowless WhatsApp does not expose a composer until it receives this
    /// Apple Event.
    static func sendReopenEvent(toPID pid: pid_t) -> Bool {
        guard isWhatsApp(pid: pid) else { return false }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do {
            // An empty option set is the no-reply send mode. Waiting for a
            // reply would make a background reopen depend on WhatsApp's UI.
            try event.sendEvent(options: [], timeout: 2.0)
            return true
        } catch {
            return false
        }
    }

    /// Uses an advertised Accessibility action to request a window without
    /// activating WhatsApp. This is a fallback for app versions that do not
    /// handle the reopen Apple Event.
    static func requestWindowWithoutActivation() -> Bool {
        guard let pid = whatsAppPID() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var actions: CFArray?
        guard AXUIElementCopyActionNames(app, &actions) == .success,
              let names = actions as? [String] else { return false }
        for action in names where action.localizedCaseInsensitiveContains("reopen")
            || action.localizedCaseInsensitiveContains("show")
            || action == (kAXRaiseAction as String) {
            if AXUIElementPerformAction(app, action as CFString) == .success { return true }
        }
        return false
    }

    // MARK: - Window discovery (background-safe, PID-based)

    /// All windows WhatsApp exposes through Accessibility, in list order. When
    /// the window list is empty, falls back to the focused-window attribute,
    /// which some app versions still expose while backgrounded.
    private static func windows() -> [AXUIElement] {
        guard let pid = whatsAppPID() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            return list
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focusedRef = focused else { return [] }
        return [(focusedRef as! AXUIElement)]
    }

    /// True when WhatsApp is running AND exposes at least one window. A running
    /// app with no window is the normal state a fraction of a second after the
    /// deep link launches it, so this is worth distinguishing.
    static func whatsAppHasWindow() -> Bool {
        !windows().isEmpty
    }

    // MARK: - Composer probes (read-only, window-based)

    /// The chat composer inside any WhatsApp window. Prefers the `AXTextArea`
    /// role (the chat composer) over `AXTextField` (the search box), so the
    /// search field can never be mistaken for the composer.
    static func composerElement() -> AXUIElement? {
        var fieldFallback: AXUIElement?
        for window in windows() {
            for element in descendants(of: window) where isTextInput(element) {
                if role(of: element) == (kAXTextAreaRole as String) { return element }
                if fieldFallback == nil { fieldFallback = element }
            }
        }
        return fieldFallback
    }

    /// The current value of the chat composer (nil when the composer is not
    /// exposed yet, e.g. WhatsApp is still loading the chat).
    static func composerTextValue() -> String? {
        guard let composer = composerElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    /// Whether the composer no longer holds `expected` — the post-send
    /// verification signal. A composer that has vanished counts as cleared.
    static func composerCleared(expected: String) -> Bool {
        guard let text = composerTextValue() else { return true }
        return text != expected
    }

    /// Replace the composer text through Accessibility, never by sending
    /// destructive keystrokes. Used when the deep link's prefill did not land
    /// (e.g. cold launch). Selecting the existing range makes the clear
    /// operation explicit before writing the confirmed body.
    static func replaceComposerText(with text: String) -> Bool {
        guard let composer = composerElement() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXValueAttribute as CFString, &value) == .success,
              let current = value as? String else { return false }
        var selectedRange = CFRange(location: 0, length: (current as NSString).length)
        guard AXUIElementSetAttributeValue(composer, kAXSelectedTextRangeAttribute as CFString,
                                           AXValueCreate(.cfRange, &selectedRange)!) == .success,
              AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, "" as CFTypeRef) == .success,
              AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFTypeRef) == .success else {
            return false
        }
        var updated: CFTypeRef?
        guard AXUIElementCopyAttributeValue(composer, kAXValueAttribute as CFString, &updated) == .success else {
            return false
        }
        return (updated as? String) == text
    }

    // MARK: - Send button

    /// The send affordance in any WhatsApp window, found by role and by a
    /// description/title/identifier that reads as "send".
    static func sendButtonElement() -> AXUIElement? {
        for window in windows() {
            for element in descendants(of: window)
            where role(of: element) == (kAXButtonRole as String) && describesSend(element) {
                return element
            }
        }
        return nil
    }

    /// True when a send affordance is present. Readiness signal only; nothing
    /// here presses it.
    static func whatsAppSendButtonExists() -> Bool {
        sendButtonElement() != nil
    }

    /// Presses the send button through the Accessibility press action. This is
    /// the preferred background submission: it never synthesizes keyboard
    /// input and never requires WhatsApp to be frontmost.
    static func pressSendButton() -> Bool {
        guard let button = sendButtonElement() else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: - Submission

    /// Submits the ready composer without bringing WhatsApp forward. Returns
    /// `.pressedButton` when the AX send button accepted a press, `.postedReturn`
    /// when a Return was delivered straight to WhatsApp's PID, and nil when
    /// WhatsApp vanished so neither path is possible.
    static func submitSend() -> WhatsAppSubmitKind? {
        if pressSendButton() { return .pressedButton }
        guard let pid = whatsAppPID() else { return nil }
        postReturn(toPID: pid)
        return .postedReturn
    }

    /// Posts one Return directly into WhatsApp's event queue via
    /// `CGEventPostToPid`. The app does not need to be frontmost, which is what
    /// keeps the send in the background. Deliberately not a shell or
    /// AppleScript path.
    static func postReturn(toPID pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    // MARK: - Focus restoration (safety net)

    /// If the system put WhatsApp frontmost anyway (a cold-launch quirk on some
    /// macOS versions), hand focus straight back to the app the user was in.
    /// Called from the sender's `defer` after every open.
    static func restoreFrontmostIfWhatsApp(previous: NSRunningApplication?) {
        guard let current = NSWorkspace.shared.frontmostApplication,
              current.bundleIdentifier == mainBundleIdentifier else { return }
        guard let previous, previous.bundleIdentifier != mainBundleIdentifier else { return }
        previous.activate(options: [.activateIgnoringOtherApps])
    }

    /// Hides WhatsApp without quitting it — the Cmd+H behaviour. Every window
    /// leaves the screen, the app keeps running, and its Accessibility tree
    /// stays readable, so a hidden WhatsApp can still receive the verified
    /// submit. macOS hands focus back to the previously active app.
    static func hideWhatsAppIfRunning() {
        guard let pid = whatsAppPID(),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.hide()
    }

    static func unhideWhatsAppIfRunning() {
        guard let pid = whatsAppPID(),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
    }

    // MARK: - Tree walking (bounded)

    /// All descendants of `element`, depth-limited so a pathological AX tree
    /// cannot hang the poll loop. The root itself is not included.
    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        var collected: [AXUIElement] = []
        collectDescendants(of: element, depth: 0, into: &collected)
        return collected
    }

    private static func collectDescendants(of element: AXUIElement, depth: Int,
                                           into collected: inout [AXUIElement]) {
        guard depth <= 12 else { return }
        if depth > 0 { collected.append(element) }
        var children: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard err == .success, let list = children as? [AXUIElement] else { return }
        for child in list {
            collectDescendants(of: child, depth: depth + 1, into: &collected)
        }
    }

    private static func describesSend(_ element: AXUIElement) -> Bool {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute] {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if err == .success, let text = value as? String, text.lowercased().contains("send") {
                return true
            }
        }
        return false
    }

    // MARK: - Role checks

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element) else { return false }
        return role == (kAXTextAreaRole as String)
            || role == (kAXTextFieldRole as String)
    }

    private static func role(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard err == .success, let r = role as? String else { return nil }
        return r
    }
}
