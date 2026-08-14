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

// Test harness: `--test-audio <file>`, `--test-audio-suite <manifest>`,
// `--unit-tests`, `--test-latency`. Feeds pre-recorded audio into the real
// pipeline so every stage after the microphone is verifiable without a human
// holding a key and speaking. Returns immediately when no test flag is present.
runTestHarnessIfRequested()

// Live send diagnostic: `--send-test "<spoken recipient>" "<body>"` drives the
// real send path (resolution -> guard -> background WhatsApp sender) without
// the confirm card. The caller asserts the human confirmation.
runSendTestIfRequested()

// Live composer diagnostic: `--probe-composer`, `--probe-composer-set <text>`,
// `--probe-composer-link <e164> <body>`. Reads WhatsApp's Accessibility tree and
// reports what the deep link does to a composer that already holds a draft. It
// never submits anything.
runComposerProbeIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()