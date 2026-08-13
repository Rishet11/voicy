import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Raw Accessibility-tree primitives for the WhatsApp send path.
///
/// READ-ONLY BY DESIGN. Every function here inspects state; none of them
/// synthesizes input. There is deliberately no key-posting helper: driving
/// WhatsApp's composer with a synthetic Return is send-path automation, and
/// WhatsApp permanently bans accounts for it. Do not add one back. The user's
/// own keypress inside WhatsApp is the send.
///
/// There is no `osascript` anywhere either: macOS attributes Accessibility
/// permission to the process that *requests* it, so shelling out would put the
/// prompt under Terminal and silently break the trust check.
enum WhatsAppAccessibility {

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

    /// Whether the frontmost app is WhatsApp proper (by bundle id or name).
    static func frontmostIsWhatsApp() -> Bool {
        guard let pid = frontmostPID() else { return false }
        return isWhatsApp(pid: pid)
    }

    static func isWhatsApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        return bundleID.contains("whatsapp") || name.contains("whatsapp")
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

    /// True when the frontmost app is WhatsApp AND its focused element is a
    /// text input (the composer). This is the readiness signal we poll for.
    static func isWhatsAppFocusedOnTextInput() -> Bool {
        guard frontmostIsWhatsApp() else { return false }
        guard let focused = focusedElement() else { return false }
        return isTextInput(focused)
    }

    /// The current value of the focused text input (nil if not readable or not
    /// a text input). Used to verify the composer emptied after Return.
    static func focusedTextValue() -> String? {
        guard frontmostIsWhatsApp() else { return nil }
        guard let focused = focusedElement() else { return nil }
        guard isTextInput(focused) else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value)
        guard err == .success, let v = value as? String else { return nil }
        return v
    }

    // MARK: - Readiness probes (read-only)

    /// PID of the running WhatsApp application, whether or not it is frontmost.
    /// Nil means the app is not running at all, which is a distinct failure
    /// from "running but not ready".
    static func whatsAppPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first { app in
            let bundleID = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            return bundleID.contains("whatsapp") || name.contains("whatsapp")
        }?.processIdentifier
    }

    /// True when WhatsApp is running AND exposes at least one window. A running
    /// app with no window is the normal state a fraction of a second after the
    /// deep link launches it, so this is worth distinguishing.
    static func whatsAppHasWindow() -> Bool {
        guard let pid = whatsAppPID() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard err == .success, let list = windows as? [AXUIElement] else { return false }
        return !list.isEmpty
    }

    /// True when a send affordance is present in WhatsApp's focused window.
    ///
    /// This is a readiness signal only. Nothing here presses it: the button is
    /// observed so the app can say "the chat is not in a sendable state"
    /// instead of leaving the user staring at a composer that will not commit.
    static func whatsAppSendButtonExists() -> Bool {
        guard let pid = whatsAppPID() else { return false }
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