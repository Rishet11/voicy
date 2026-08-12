import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Raw Accessibility-tree primitives for the WhatsApp send path.
///
/// Everything here is a tiny, nonisolated, side-effect-light wrapper around the
/// AX C API plus the one safe way to post a Return (`CGEventPost`). There is no
/// `osascript` anywhere: macOS attributes Accessibility permission to the
/// process that *requests* it, so shelling out would put the prompt under
/// Terminal and silently break the trust check.
enum WhatsAppAccessibility {
    /// Carbon virtual keycode for Return.
    static let returnKeycode: CGKeyCode = 36 // kVK_Return

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

    /// Posts a physical Return key-down + key-up at the HID event tap.
    static func postReturn() {
        let down = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: returnKeycode,
            keyDown: true
        )
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: returnKeycode,
            keyDown: false
        )
        up?.post(tap: .cghidEventTap)
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