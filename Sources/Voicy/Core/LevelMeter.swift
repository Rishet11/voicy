import Foundation

// MARK: - Level meter math
//
// The recording pill's bar heights come from here and nowhere else. Every value
// this type produces is a function of real captured samples: there is no idle
// animation, no synthetic motion, no floor that moves on its own. Silence in
// means zero out.
//
// It is a plain value type with no UI and no audio dependency so the numbers can
// be measured against recorded speech (`--test-meter`) instead of guessed at.
//
// Three decisions live here, each one measured rather than assumed:
//
//  1. WINDOW. RMS is taken over the newest 30 ms, not 250 ms. Syllable energy in
//     speech sits around 4 to 8 Hz, so a 250 ms window spans a whole syllable
//     and averages its rise and fall into one flat number. 30 ms is short enough
//     to track a syllable and long enough to be a stable amplitude estimate at
//     16 kHz (480 samples).
//
//  2. CURVE. Loudness perception is logarithmic, so the bar height is linear in
//     dBFS, not in raw amplitude. Normal speech measures around -30 dBFS, which
//     under the old `rms / 0.25` linear map produced a bar height of about 0.13:
//     the meter spent the whole utterance in the bottom eighth of its range.
//
//  3. GATE. Anything at or below the floor maps to exactly 0, so room noise
//     does not make the bars twitch. When there is no sound there is no
//     movement.
enum LevelMeter {

    /// Analysis window in samples at the 16 kHz analysis rate: 30 ms.
    ///
    /// Long enough that the RMS estimate is not dominated by a single pitch
    /// period (a 100 Hz male fundamental is 10 ms), short enough to resolve
    /// syllable onsets.
    static let windowSamples = 480

    /// Bar height 0 at and below this level. Measured room noise on this machine
    /// sits under it, so silence reads as silence.
    static let floorDBFS: Float = -50

    /// Bar height 1 at and above this level. Chosen so loud speech reaches the
    /// top of the meter without clipping the whole upper range away.
    static let ceilingDBFS: Float = -10

    /// Root mean square of a sample window. Zero for an empty window.
    static func rms(_ window: ArraySlice<Float>) -> Float {
        guard !window.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in window { sum += sample * sample }
        return (sum / Float(window.count)).squareRoot()
    }

    /// Amplitude as dBFS. Digital silence has no logarithm, so it is reported at
    /// the floor rather than as negative infinity.
    static func dbFS(_ rms: Float) -> Float {
        guard rms > 0 else { return floorDBFS }
        return 20 * log10(rms)
    }

    /// Bar height in 0...1 for one already-computed RMS value.
    ///
    /// Linear in dBFS between the floor and the ceiling, hard clamped at both
    /// ends. The clamp at the bottom is the noise gate.
    static func level(rms: Float) -> Float {
        let db = dbFS(rms)
        guard db > floorDBFS else { return 0 }
        let normalized = (db - floorDBFS) / (ceilingDBFS - floorDBFS)
        return min(max(normalized, 0), 1)
    }

    /// Bar height for the newest `windowSamples` of a capture buffer. This is
    /// the call the live meter makes, once per frame.
    static func level(tail: ArraySlice<Float>) -> Float {
        level(rms: rms(tail))
    }
}
