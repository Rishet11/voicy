import AppKit

/// Menubar app controller. Owns the status item and wires the end-to-end
/// pipeline (hotkey -> mic -> transcribe -> intent -> resolve -> confirm -> send).
///
/// Permission model (CLAUDE.md): Tier-1 permissions (Microphone, Contacts) are
/// requested once, on launch, by the pipeline. The default Ctrl+Space hotkey is
/// a Carbon hotkey that needs no permission, and Tier-2 privileges (Input
/// Monitoring, Accessibility) are only ever exercised if already granted — never
/// asked for at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let pipeline = Pipeline()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        pipeline.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let symbol = NSImage(systemSymbolName: "mic", accessibilityDescription: "Voicy")
            button.image = symbol
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Voicy — press Ctrl+Space to talk", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voicy", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}