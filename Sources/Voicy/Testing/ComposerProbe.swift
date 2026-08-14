import AppKit
import Foundation
import ApplicationServices
import CoreGraphics

// MARK: - Live composer diagnostic
//
// Answers one question that cannot be answered by reading code: what does the
// WhatsApp deep link actually DO to a composer that already holds the user's
// half typed draft. Does it replace the draft, append to it, or refuse?
//
// The send path's behaviour when a draft is present depends entirely on that
// answer, so it is measured here rather than assumed.
//
// This tool NEVER submits anything. It reads the Accessibility tree, optionally
// writes a known draft into the composer, optionally fires the deep link, and
// reports what the composer then contains. There is no send button press and no
// Return anywhere in this file.
//
// Usage (via the launched bundle, so Accessibility permission applies):
//   open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-composer
//   open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-composer-set "half typed dr"
//   open -n --stdout /tmp/p.log dist/Voicy.app --args --probe-composer-link <e164> "body"

/// Classifies what the composer holds relative to a known draft and body, so the
/// output never has to print the raw text.
private func classify(_ text: String?, draft: String, body: String) -> String {
    guard let text else { return "composer not exposed (nil)" }
    if text.isEmpty { return "empty" }
    if text == body { return "exactly the new body (the draft was destroyed)" }
    if text == draft { return "exactly the old draft (the body did not land)" }
    if text == draft + body { return "draft followed by body (concatenated)" }
    if text == body + draft { return "body followed by draft (concatenated)" }
    if text.contains(draft) && text.contains(body) { return "contains both draft and body" }
    if text.contains(body) { return "contains the body plus something else" }
    if text.contains(draft) { return "contains the draft plus something else" }
    return "something else entirely, \(text.count) chars"
}

/// Resolves a spoken name to one E.164 number through the real contact stack, so
/// the probe can never be pointed at an arbitrary chat by a mistyped number.
@MainActor
enum ComposerProbeResolver {
    static func e164(forSpoken spoken: String) async -> String? {
        let index = ContactIndex()
        do {
            try await index.load()
        } catch {
            print("[probe] contacts failed to load: \(error)")
            return nil
        }
        switch ContactResolver().resolve(spoken: spoken, contacts: index.contacts,
                                        aliases: AliasStore().lookup) {
        case .resolved(let contact):
            return contact.preferredE164
        case .ambiguous(let candidates):
            print("[probe] \(candidates.count) candidates for \"\(spoken)\"; refusing to guess")
            return nil
        case .notFound:
            return nil
        }
    }
}

@MainActor
func runComposerProbeIfRequested() {
    let args = CommandLine.arguments
    let flags = ["--probe-composer", "--probe-composer-set", "--probe-composer-link", "--probe-window", "--probe-ax", "--probe-contact"]
    guard args.contains(where: { flags.contains($0) }) else { return }

    // Contact loading is async, so run the body in a Task and pump the main run
    // loop, the same shape as the send-test runner.
    let done = ComposerProbeFlag()
    Task { @MainActor in
        await composerProbeBody(args: args)
        done.value = true
    }
    while !done.value {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    exit(0)
}

@MainActor
private final class ComposerProbeFlag {
    var value = false
}

@MainActor
private func composerProbeBody(args: [String]) async {
    func value(after flag: String, offset: Int = 1) -> String? {
        guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
        let candidate = args[i + offset]
        return candidate.hasPrefix("--") ? nil : candidate
    }

    print("[probe] Accessibility trusted: \(WhatsAppAccessibility.isTrusted(prompt: false))")
    print("[probe] WhatsApp running: \(WhatsAppAccessibility.whatsAppPID() != nil)")
    print("[probe] WhatsApp has a window: \(WhatsAppAccessibility.whatsAppHasWindow())")
    let initial = WhatsAppAccessibility.composerTextValue()
    print("[probe] composer exposed: \(initial != nil), length: \(initial?.count ?? -1)")
    print("[probe] send button present: \(WhatsAppAccessibility.whatsAppSendButtonExists())")

    // Read-only contact lookup. Prints which contact owns a number, or which
    // contacts a spoken name matches, so a live send can be aimed by NAME after
    // confirming who that name is. Sends nothing and writes nothing.
    if let query = value(after: "--probe-contact") {
        let index = ContactIndex()
        do {
            try await index.load()
        } catch {
            print("[probe] contacts failed to load: \(error)")
            return
        }
        let digits = query.filter(\.isNumber)
        if !digits.isEmpty {
            let matches = index.contacts.filter { contact in
                contact.phones.contains { $0.e164.hasSuffix(digits) }
            }
            print("[probe] \(matches.count) contact(s) hold a number ending \(digits.suffix(4)):")
            for contact in matches {
                print("[probe]   \"\(contact.displayName)\" -> +...\(contact.preferredE164?.suffix(4) ?? "none")")
            }
        }
        switch ContactResolver().resolve(spoken: query, contacts: index.contacts,
                                        aliases: AliasStore().lookup) {
        case .resolved(let contact):
            print("[probe] spoken \"\(query)\" resolves to \"\(contact.displayName)\" +...\(contact.preferredE164?.suffix(4) ?? "none")")
        case .ambiguous(let candidates):
            print("[probe] spoken \"\(query)\" is ambiguous across \(candidates.count): \(candidates.map(\.displayName).joined(separator: ", "))")
        case .notFound:
            print("[probe] spoken \"\(query)\" matches no contact")
        }
    }

    if args.contains("--probe-ax") {
        let locked = (CGSessionCopyCurrentDictionary() as NSDictionary?)?["CGSSessionScreenIsLocked"]
        print("[probe] screen locked: \(locked ?? "no")")
        guard let pid = WhatsAppAccessibility.whatsAppPID() else {
            print("[probe] WhatsApp is not running")
            return
        }
        let app = AXUIElementCreateApplication(pid)

        var windows: CFTypeRef?
        let windowsErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        let windowList = windows as? [AXUIElement]
        print("[probe] AXWindows error=\(windowsErr.rawValue) isArray=\(windowList != nil) count=\(windowList?.count ?? -1)")

        var focused: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        print("[probe] AXFocusedWindow error=\(focusedErr.rawValue) present=\(focused != nil)")

        var attributes: CFArray?
        if AXUIElementCopyAttributeNames(app, &attributes) == .success,
           let names = attributes as? [String] {
            print("[probe] app AX attributes: \(names.sorted().joined(separator: ", "))")
        } else {
            print("[probe] app AX attributes: could not be read")
        }

        // Electron and some Catalyst apps expose no AX tree at all until a client
        // sets AXManualAccessibility on the application element. If that is what is
        // happening, this flips the whole tree on.
        let setErr = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        print("[probe] set AXManualAccessibility error=\(setErr.rawValue)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var windows2: CFTypeRef?
        let windowsErr2 = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows2)
        let windowList2 = windows2 as? [AXUIElement]
        print("[probe] after manual AX: AXWindows error=\(windowsErr2.rawValue) count=\(windowList2?.count ?? -1)")
        print("[probe] after manual AX: hasWindow=\(WhatsAppAccessibility.whatsAppHasWindow()) composerExposed=\(WhatsAppAccessibility.composerTextValue() != nil)")

        // How deep and how wide is the tree really, and does the composer sit
        // below the depth limit the production walker uses?
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let ref = focusedWindow {
            let window = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
            var roleCounts: [String: Int] = [:]
            var maxDepth = 0
            var total = 0
            func walk(_ element: AXUIElement, depth: Int) {
                guard depth <= 30, total < 20_000 else { return }
                total += 1
                maxDepth = max(maxDepth, depth)
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                   let r = role as? String {
                    roleCounts[r, default: 0] += 1
                    if r == (kAXTextAreaRole as String) || r == (kAXTextFieldRole as String) {
                        print("[probe]   text input found at depth \(depth), role \(r)")
                        // Why does composerTextValue() return nil for this?
                        var v: CFTypeRef?
                        let vErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v)
                        let asString = v as? String
                        print("[probe]     AXValue error=\(vErr.rawValue) isString=\(asString != nil) length=\(asString?.count ?? -1) type=\(v == nil ? "nil" : String(describing: CFGetTypeID(v!)))")
                        var names: CFArray?
                        if AXUIElementCopyAttributeNames(element, &names) == .success,
                           let list = names as? [String] {
                            print("[probe]     attributes: \(list.sorted().joined(separator: ", "))")
                        }
                    }
                }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                      let list = children as? [AXUIElement] else { return }
                for child in list { walk(child, depth: depth + 1) }
            }
            // What does WhatsApp actually call its buttons? The send matcher looks
            // for the word "send" in the description, title, or identifier, and if
            // none of them carry it the readiness check can never be satisfied.
            func dumpButtons(_ element: AXUIElement, depth: Int) {
                guard depth <= 20 else { return }
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                   let r = role as? String, r == (kAXButtonRole as String) {
                    func attr(_ name: String) -> String {
                        var v: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(element, name as CFString, &v) == .success,
                              let s = v as? String, !s.isEmpty else { return "-" }
                        return s
                    }
                    let desc = attr(kAXDescriptionAttribute as String)
                    let title = attr(kAXTitleAttribute as String)
                    let ident = attr(kAXIdentifierAttribute as String)
                    let help = attr(kAXHelpAttribute as String)
                    if desc != "-" || title != "-" || ident != "-" || help != "-" {
                        print("[probe]   button d=\(depth) desc=\"\(desc)\" title=\"\(title)\" id=\"\(ident)\" help=\"\(help)\"")
                    }
                }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                      let list = children as? [AXUIElement] else { return }
                for child in list { dumpButtons(child, depth: depth + 1) }
            }
            dumpButtons(window, depth: 0)

            walk(window, depth: 0)
            print("[probe] focused window subtree: \(total) elements, max depth \(maxDepth)")
            print("[probe] roles: \(roleCounts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        }
    }

    if args.contains("--probe-window") {
        if let pid = WhatsAppAccessibility.whatsAppPID(),
           let app = NSRunningApplication(processIdentifier: pid) {
            print("[probe] WhatsApp isHidden: \(app.isHidden), isActive: \(app.isActive), isFinishedLaunching: \(app.isFinishedLaunching)")
            print("[probe] reopen Apple Event accepted: \(WhatsAppAccessibility.sendReopenEvent(toPID: pid))")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("[probe] after reopen, hasWindow: \(WhatsAppAccessibility.whatsAppHasWindow())")
            WhatsAppAccessibility.unhideWhatsAppIfRunning()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("[probe] after unhide, isHidden: \(app.isHidden), hasWindow: \(WhatsAppAccessibility.whatsAppHasWindow())")
            print("[probe] requestWindowWithoutActivation: \(WhatsAppAccessibility.requestWindowWithoutActivation())")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            print("[probe] after requestWindow, hasWindow: \(WhatsAppAccessibility.whatsAppHasWindow())")
            print("[probe] composer exposed now: \(WhatsAppAccessibility.composerTextValue() != nil)")
        } else {
            print("[probe] WhatsApp is not running")
        }
    }

    if let draft = value(after: "--probe-composer-set") {
        let ok = WhatsAppAccessibility.replaceComposerText(with: draft)
        let after = WhatsAppAccessibility.composerTextValue()
        print("[probe] wrote a \(draft.count) char draft: \(ok), composer now holds \(after?.count ?? -1) chars, matches: \(after == draft)")
    }

    if let spoken = value(after: "--probe-composer-link"),
       let body = value(after: "--probe-composer-link", offset: 2) {
        // Resolved by name through the real resolver, never by a raw number on
        // the command line. A draft written by this probe must be able to land in
        // the authorised test contact's chat and nowhere else.
        guard let phone = await ComposerProbeResolver.e164(forSpoken: spoken) else {
            print("[probe] FAIL could not resolve \"\(spoken)\" to one contact with a phone number")
            exit(1)
        }
        let draft = WhatsAppAccessibility.composerTextValue() ?? ""
        print("[probe] before the link, composer holds \(draft.count) chars")
        do {
            let url = try WhatsAppDeepLink.sendURL(phone: phone, text: body)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            print("[probe] deep link opened non-activating, body \(body.count) chars")
        } catch {
            print("[probe] FAIL could not build the deep link: \(error)")
            exit(1)
        }
        // Poll for four seconds so a slow chat switch is not mistaken for a
        // refusal, and report every distinct state the composer passes through.
        var seen: [String] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 4.0 {
            let state = classify(WhatsAppAccessibility.composerTextValue(), draft: draft, body: body)
            if seen.last != state { seen.append(state) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        print("[probe] composer states after the link, in order:")
        for state in seen { print("[probe]   \(state)") }
    }
}
