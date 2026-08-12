import AppKit
import Darwin

// Unbuffer stdout. Without this, print() is block-buffered whenever the process
// is not attached to a TTY (i.e. launched as a .app), so pipeline diagnostics
// never reach the log file and we debug blind.
setvbuf(stdout, nil, _IONBF, 0)

// Menubar-only app entry. The app runs as a bundle (see build.sh) so its
// permission prompts attach to the bundled Voicy process, not a bare binary.
// Diagnostics: `Voicy --selftest` prints permission/environment state and exits.
// Must run before NSApplication takes over the main thread.
runSelfTestIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()