import AppKit

/// Which display Voicy's panels should appear on.
///
/// `NSScreen.main` is the wrong answer here, and it is wrong in a way that only
/// shows up on a multi-display Mac. `NSScreen.main` is the screen containing the
/// window with keyboard focus. Voicy never takes keyboard focus: the pill and the
/// confirm card are both non-activating panels, deliberately, because stealing
/// focus is a hard rule. So `NSScreen.main` reports whichever screen holds some
/// other app's key window, which is not necessarily the screen the user is
/// looking at, and on a two monitor setup the pill can appear on the display the
/// user is not using.
///
/// The mouse pointer is the better signal available to a background app: it is
/// where the user's attention was last, it needs no permission, and it is correct
/// on a single display too.
enum ActiveScreen {
    /// The screen under the mouse pointer, falling back to the focused screen and
    /// then to the first attached screen. Nil only when macOS reports no screens
    /// at all, for instance with the lid closed and no external display.
    static var current: NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let under = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return under
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
