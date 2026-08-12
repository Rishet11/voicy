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

    init(capacity: Int = 30) {
        self.capacity = capacity
        self.bars = Array(repeating: 0, count: capacity)
    }

    /// Feed one real RMS measurement (clamped to 0...1). A light exponential
    /// smoothing makes the meter feel organic, but every visible change still
    /// traces to an actual amplitude value.
    func push(_ rms: Float) {
        let clamped = min(max(rms, 0), 1)
        smoothed = smoothed * 0.55 + clamped * 0.45
        if bars.count >= capacity { bars.removeFirst() }
        bars.append(smoothed)
    }
}

/// The pulse on the left of the pill: a red dot with an expanding halo.
/// (This is a deliberate visual pulse, not the audio meter.)
private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.35))
                .frame(width: 20, height: 20)
                .scaleEffect(pulsing ? 1.7 : 1.0)
                .opacity(pulsing ? 0 : 0.55)
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.7), radius: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

/// The live waveform: a row of bars whose heights are proportional to the most
/// recent RMS samples. Driven entirely by `RecordingLevels`.
private struct Waveform: View {
    let bars: [Float]

    private var gradient: LinearGradient {
        LinearGradient(colors: [.red.opacity(0.95), .orange],
                       startPoint: .bottom, endPoint: .top)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(gradient)
                    .frame(width: 3, height: max(4, 6 + CGFloat(level) * 18))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

/// The pill's SwiftUI body. Sized by the panel; contents are self-centered.
struct RecordingIndicatorView: View {
    let levels: RecordingLevels

    init(levels: RecordingLevels) {
        self.levels = levels
    }

    var body: some View {
        HStack(spacing: 10) {
            RecordingDot()
            Waveform(bars: levels.bars)
                .frame(width: 96, height: 24)
            Text("Recording")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }
}

/// Owns the floating, non-activating panel that hosts the pill. Kept alive for
/// the whole app life so `show()` is just an `orderFrontRegardless` — fast
/// enough to hit the 100 ms budget.
@MainActor
public final class RecordingIndicatorController {
    private let levels = RecordingLevels()
    private let panel: NSPanel
    private let hosting: NSHostingView<RecordingIndicatorView>

    public init() {
        let host = NSHostingView(rootView: RecordingIndicatorView(levels: levels))
        self.hosting = host

        let size = NSSize(width: 156, height: 46)
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
        positionTopCenter()
        panel.orderFrontRegardless()
    }

    /// Hide the pill.
    public func hide() {
        panel.orderOut(nil)
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
        let y = frame.maxY - size.height - 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}