import AppKit
import CoreGraphics
import Foundation

/// Push-to-talk hotkey: hold the RIGHT Option key to record, release to stop.
///
/// Listens on a global CGEventTap for `.flagsChanged`. We distinguish the right
/// Option key (keycode `0x3D`, `kVK_RightOption`) from the left Option
/// (`0x3A`, `kVK_Option`) by the raw keycode, not just the modifier flags —
/// both keys set `.option` in the flags, so the keycode is the only reliable
/// discriminator.
@MainActor
final class PushToTalkHotkey {
    enum HotkeyError: Error {
        case notGranted
        case tapCreationFailed
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    /// Called on the main thread when the user presses/releases the key.
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    // Carbon keycodes.
    nonisolated static let rightOptionKeycode: CGKeyCode = 0x3D // kVK_RightOption
    nonisolated static let leftOptionKeycode: CGKeyCode = 0x3A // kVK_Option

    /// Asks the user for Input Monitoring permission if it has not been granted.
    /// Returns true if we hold (or can request) access.
    static func requestInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() { return true }
        return CGRequestListenEventAccess()
    }

    var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Starts the global event tap. Throws if permission is missing or the tap
    /// cannot be created.
    func start() throws {
        guard hasInputMonitoring else {
            throw HotkeyError.notGranted
        }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hotkey = Unmanaged<PushToTalkHotkey>.fromOpaque(refcon).takeUnretainedValue()
            hotkey.handle(event: event, type: type)
            return Unmanaged.passUnretained(event)
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Nonisolated entry point invoked on the event-tap thread. Only inspects
    /// the event and then hops to the main actor to update state / fire callbacks.
    private nonisolated func handle(event: CGEvent, type: CGEventType) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let nowDown = event.flags.contains(.maskAlternate)
        guard keycode == Self.rightOptionKeycode else { return }

        Task { @MainActor [weak self] in
            self?.updatePressed(nowDown)
        }
    }

    private func updatePressed(_ nowDown: Bool) {
        if nowDown && !isDown {
            isDown = true
            onKeyDown?()
        } else if !nowDown && isDown {
            isDown = false
            onKeyUp?()
        }
    }
}