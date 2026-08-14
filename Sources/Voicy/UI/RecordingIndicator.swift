import AppKit
import SwiftUI
import Observation

// MARK: - Recording pill
//
// A tiny floating capsule near the top-center of the screen that appears the
// instant recording starts. It drives a live waveform from the real RMS
// amplitude fed in via `updateLevel(_:)` — there is no timer faking the meter.
// The panel is non-activating and floating so it never steals keyboard focus.

/// Holds the waveform's recent RMS samples. The box is a ring buffer of the
/// last `capacity` levels; every sample is a real measurement pushed in by the
/// audio capture path.
@MainActor
@Observable
final class RecordingLevels {
    private(set) var bars: [Float]
    private let capacity: Int

    init(capacity: Int = Theme.Layout.waveformBarCount) {
        self.capacity = capacity
        self.bars = Array(repeating: 0, count: capacity)
    }

    /// Feed one real level measurement (clamped to 0...1) and shift the ring
    /// buffer by one. Each bar is exactly one measured 30 ms RMS window, in
    /// dBFS, straight from `LevelMeter`.
    ///
    /// There used to be an exponential smoothing stage here, on top of a level
    /// that was already an average over a 250 ms window. Two smoothers in series
    /// is why the pill looked dead, and this is the one that had to go: the other
    /// is a physical average of real samples, while this one blurred each
    /// historical bar into its neighbour and destroyed the syllable structure
    /// that makes a waveform read as a voice. The bars are a scrolling history,
    /// so smoothing ACROSS positions is not smoothing at all, it is smearing.
    func push(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        if bars.count >= capacity { bars.removeFirst() }
        bars.append(clamped)
    }

    /// Flatten every bar. Called when the pill is shown or hidden so the tail of
    /// the previous recording cannot appear as the start of the next one.
    func reset() {
        bars = Array(repeating: 0, count: capacity)
    }
}

/// The recognizer's current, revisable reading. This is display-only state:
/// the send path must use the finalized transcript returned by the speech
/// session, never this provisional value.
@MainActor
@Observable
final class RecordingTranscript {
    private(set) var text = ""
    private(set) var isProvisional = false

    func update(_ text: String) {
        self.text = text
        isProvisional = true
    }

    func clear() {
        text = ""
        isProvisional = false
    }
}

/// The pulse on the left of the pill: a coloured dot with an expanding halo.
/// (This is a deliberate visual pulse, not the audio meter.)
private struct RecordingDot: View {
    @Environment(\.colorScheme) private var scheme
    @State private var pulsing = false
    private var reduceMotion: Bool { Theme.Motion.reduceMotionEnabled }

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        ZStack {
            Circle()
                .fill(palette.live.opacity(0.35))
                .frame(width: Theme.Layout.dotHaloSize, height: Theme.Layout.dotHaloSize)
                .scaleEffect(pulsing && !reduceMotion ? 1.7 : 1.0)
                .opacity(pulsing && !reduceMotion ? 0 : 0.55)
            Circle()
                .fill(palette.live)
                .frame(width: Theme.Layout.dotSize, height: Theme.Layout.dotSize)
                .shadow(color: palette.live.opacity(0.7), radius: 4)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(Theme.Motion.breathing) {
                pulsing = true
            }
        }
        .accessibilityHidden(true) // decorative; the pill's own label covers state
    }
}

/// The live waveform: a row of bars whose heights are proportional to the most
/// recent RMS samples, held in a rolling ring buffer so it reads as sound
/// rather than a single pulsing blob. Driven entirely by `RecordingLevels`.
///
/// The bars carry no animation of their own. That is not an oversight: the
/// levels arrive at 60 Hz, and the spring that used to be attached here took
/// about 200 ms to settle, so every bar rendered a heavily lagged version of
/// audio that was already 16 ms old. The requirement is that the pill responds
/// within one frame of speech starting, and an interpolating spring is exactly
/// what prevents that. The data is the animation.
private struct Waveform: View {
    @Environment(\.colorScheme) private var scheme
    let bars: [Float]

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        let gradient = LinearGradient(colors: [palette.live.opacity(0.95), palette.live.opacity(0.55)],
                                       startPoint: .bottom, endPoint: .top)
        HStack(alignment: .center, spacing: Theme.Layout.waveformBarSpacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: Theme.Layout.waveformBarWidth / 2, style: .continuous)
                    .fill(gradient)
                    .frame(width: Theme.Layout.waveformBarWidth,
                           height: max(Theme.Layout.waveformMinBarHeight,
                                       Theme.Layout.waveformMinBarHeight
                                        + CGFloat(level) * Theme.Layout.waveformMaxBarHeight))
            }
        }
    }
}

/// The pill's SwiftUI body. Sized by the panel; contents are self-centered.
struct RecordingIndicatorView: View {
    @Environment(\.colorScheme) private var scheme
    let levels: RecordingLevels
    let transcript: RecordingTranscript

    init(levels: RecordingLevels, transcript: RecordingTranscript) {
        self.levels = levels
        self.transcript = transcript
    }

    var body: some View {
        let palette = Theme.Colors.palette(scheme)
        HStack(spacing: Theme.Space.sm) {
            RecordingDot()
            Waveform(bars: levels.bars)
                .frame(width: Theme.Layout.waveformFrameSize.width,
                       height: Theme.Layout.waveformFrameSize.height)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                if !transcript.text.isEmpty {
                    Text(transcript.text)
                        .font(Theme.Typography.caption())
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
            }
                .font(Theme.Typography.callout(.semibold))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.12), radius: 14, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcript.text.isEmpty
                            ? "Recording voice message"
                            : "Recording voice message. Provisional transcript: \(transcript.text)")
        .accessibilityHint("Listening for your message. Release the shortcut key to finish.")
    }
}

/// Owns the floating, non-activating panel that hosts the pill. Kept alive for
/// the whole app life so `show()` is just an `orderFrontRegardless` — fast
/// enough to hit the 100 ms budget.
@MainActor
public final class RecordingIndicatorController {
    private let levels = RecordingLevels()
    private let transcript = RecordingTranscript()
    private let panel: NSPanel
    private let hosting: NSHostingView<RecordingIndicatorView>

    public init() {
        let host = NSHostingView(rootView: RecordingIndicatorView(levels: levels, transcript: transcript))
        self.hosting = host

        let size = NSSize(width: Theme.Layout.pillSize.width, height: Theme.Layout.pillSize.height)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // The pill is display-only; it must never intercept clicks.
        panel.ignoresMouseEvents = true

        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel
    }

    /// Reveal the pill at the top-center of the main screen.
    public func show() {
        transcript.clear()
        levels.reset()
        positionTopCenter()
        panel.orderFrontRegardless()
    }

    /// Hide the pill.
    public func hide() {
        transcript.clear()
        levels.reset()
        panel.orderOut(nil)
    }

    /// Updates the display with a revisable speech-engine result. This value is
    /// intentionally not exposed as a sendable transcript or callback.
    public func updateTranscript(_ text: String) {
        Task { @MainActor in
            self.transcript.update(text)
        }
    }

    /// Feed one real measured level, 0...1, from `LevelMeter`.
    ///
    /// Called straight through rather than through a `Task` hop: this type is
    /// already main-actor isolated and the caller is the main run loop's level
    /// timer, so a hop would only add an allocation and a scheduling delay 60
    /// times a second, and could deliver frames out of order under load.
    public func updateLevel(_ level: Float) {
        levels.push(level)
    }

    public var isVisible: Bool { panel.isVisible }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        // Just below the menu bar so it "floats" at the very top-center.
        let y = frame.maxY - size.height - Theme.Layout.pillTopInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
