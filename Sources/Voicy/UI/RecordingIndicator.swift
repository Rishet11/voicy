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
    private var smoothed: Float = 0
    private let capacity: Int

    init(capacity: Int = Theme.Layout.waveformBarCount) {
        self.capacity = capacity
        self.bars = Array(repeating: 0, count: capacity)
    }

    /// Feed one real RMS measurement (clamped to 0...1). A light exponential
    /// smoothing makes the meter feel organic, but every visible change still
    /// traces to an actual amplitude value. Shifts the ring buffer by one.
    func push(_ rms: Float) {
        let clamped = min(max(rms, 0), 1)
        smoothed = smoothed * 0.55 + clamped * 0.45
        if bars.count >= capacity { bars.removeFirst() }
        bars.append(smoothed)
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
private struct Waveform: View {
    @Environment(\.colorScheme) private var scheme
    let bars: [Float]
    private var reduceMotion: Bool { Theme.Motion.reduceMotionEnabled }

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
                    .animation(reduceMotion ? Theme.Motion.plainFade : Theme.Motion.snappy, value: level)
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
        positionTopCenter()
        panel.orderFrontRegardless()
    }

    /// Hide the pill.
    public func hide() {
        transcript.clear()
        panel.orderOut(nil)
    }

    /// Updates the display with a revisable speech-engine result. This value is
    /// intentionally not exposed as a sendable transcript or callback.
    public func updateTranscript(_ text: String) {
        Task { @MainActor in
            self.transcript.update(text)
        }
    }

    /// Feed a real RMS amplitude. Safe to call from the audio capture thread.
    public func updateLevel(_ rms: Float) {
        Task { @MainActor in
            self.levels.push(rms)
        }
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
