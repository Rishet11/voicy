import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Raw Accessibility-tree primitives for the Telegram send path.
///
/// AX inspection is read-only. The only input primitive is the explicit,
/// post-confirmation Return in `postReturn()`. Same discipline as
/// `WhatsAppAccessibility`: no `osascript` anywhere, ever.
enum TelegramAccessibility {

    /// Bundle ids of the two Telegram Mac clients. Release Telegram Desktop
    /// ships as `org.telegram.desktop` (verified in tdesktop's own
    /// CMakeLists.txt); the App Store "Telegram for macOS" build is
    /// `ru.keepcoder.Telegram`. Both handle the `tg://` scheme.
    static let telegramBundleIDs = ["org.telegram.desktop", "ru.keepcoder.Telegram"]

    /// True when either Telegram client is installed. This is the distinct
    /// "Telegram not installed" check; "installed but not running" is a
    /// separate failure reported by the compose waiter.
    static func isInstalled() -> Bool {
        telegramBundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// Checks whether this process holds Accessibility permission, prompting
    /// the user if `prompt` is true and the app is trusted-eligible.
    static func isTrusted(prompt: Bool) -> Bool {
        // Swift 6 strict concurrency rejects the Carbon global `kAXTrustedCheckOptionPrompt`
        // (a mutable global). Its documented value is the literal below.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// PID of the frontmost application, or nil if it cannot be determined.
    static func frontmostPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard err == .success, let appRef = focusedApp else { return nil }
        let app = (appRef as! AXUIElement)
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return nil }
        return pid
    }

    /// Whether the frontmost app is a Telegram client (by bundle id or name).
    static func frontmostIsTelegram() -> Bool {
        guard let pid = frontmostPID() else { return false }
        return isTelegram(pid: pid)
    }

    static func isTelegram(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        return bundleID.contains("telegram") || name.contains("telegram")
    }

    /// The currently focused element of the frontmost app, if any.
    static func focusedElement() -> AXUIElement? {
        guard let pid = frontmostPID() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let focusedRef = focused else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// True when the frontmost app is Telegram AND its focused element is a
    /// text input (the message composer). This is the readiness signal we
    /// poll for.
    static func isTelegramFocusedOnTextInput() -> Bool {
        guard frontmostIsTelegram() else { return false }
        guard let focused = focusedElement() else { return false }
        return isTextInput(focused)
    }

    /// The current value of the focused text input (nil if not readable or not
    /// a text input). Used to verify the composer holds the exact body.
    static func focusedTextValue() -> String? {
        guard frontmostIsTelegram() else { return nil }
        guard let focused = focusedElement() else { return nil }
        guard isTextInput(focused) else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value)
        guard err == .success, let v = value as? String else { return nil }
        return v
    }

    /// Posts Return only after the sender has verified the focused composer.
    /// This is deliberately CGEventPost, never a shell or AppleScript path.
    static func postReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Readiness probes (read-only)

    /// PID of a running Telegram client, whether or not it is frontmost.
    /// Nil means Telegram is not running at all, which is a distinct failure
    /// from "running but not ready".
    static func telegramPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first { app in
            let bundleID = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            return bundleID.contains("telegram") || name.contains("telegram")
        }?.processIdentifier
    }

    /// True when Telegram is running AND exposes at least one window. A running
    /// app with no window is the normal state a fraction of a second after the
    /// deep link launches it, so this is worth distinguishing.
    static func telegramHasWindow() -> Bool {
        guard let pid = telegramPID() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard err == .success, let list = windows as? [AXUIElement] else { return false }
        return !list.isEmpty
    }

    /// True when a send affordance is present in Telegram's focused window.
    ///
    /// Readiness signal only. Nothing here presses it: the button is observed
    /// so the app can say "the chat is not in a sendable state" instead of
    /// leaving the user staring at a composer that will not commit.
    static func telegramSendButtonExists() -> Bool {
        guard let pid = telegramPID() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        guard err == .success, let windowRef = window else { return false }
        return containsSendButton(windowRef as! AXUIElement, depth: 0)
    }

    /// Depth-limited search for a button whose description reads as "send".
    /// Bounded so a pathological AX tree cannot hang the poll loop.
    private static func containsSendButton(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 8 else { return false }
        if role(of: element) == (kAXButtonRole as String), describesSend(element) { return true }

        var children: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard err == .success, let list = children as? [AXUIElement] else { return false }
        for child in list where containsSendButton(child, depth: depth + 1) { return true }
        return false
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

