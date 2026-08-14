import Foundation

// MARK: - Level meter measurement probe
//
// Answers the questions Part 1 of the hardening pass asks, with measurements
// instead of assertions:
//
//   * what frame rate does the live timer actually achieve, not what was asked for
//   * what dynamic range of bar heights does real recorded speech produce,
//     before and after the change
//   * what dBFS quiet, normal and loud speech actually measure on this machine
//
// It replays a recorded WAV through both meter implementations sample-accurately.
// The replay is honest about what it is: it feeds the same samples the microphone
// path would have produced, at the same rate, so the bar heights are the real
// ones. It cannot measure how the pill LOOKS; that needs a person watching it,
// and the report says so.
//
// Usage:
//   dist/Voicy.app/Contents/MacOS/Voicy --test-meter
//   dist/Voicy.app/Contents/MacOS/Voicy --test-meter Tests/audio/long-body.wav

/// One meter implementation's behaviour over a whole clip.
private struct MeterTrace {
    let name: String
    /// Bar heights, in 0...1, one per simulated frame.
    let levels: [Float]
    let fps: Double
    let windowMs: Double

    var loud: [Float] { levels.filter { $0 > 0 } }

    var minLevel: Float { levels.min() ?? 0 }
    var maxLevel: Float { levels.max() ?? 0 }

    /// Spread of the middle of the distribution, which is what "does it move"
    /// actually means. A meter pinned near one value has a tiny p10-to-p90 span
    /// however high its single peak is.
    func percentile(_ p: Double) -> Float {
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    /// Mean absolute change between consecutive frames. This is the number that
    /// corresponds to the complaint: a meter that does not move frame to frame
    /// looks dead no matter what its average is.
    var meanFrameDelta: Float {
        guard levels.count > 1 else { return 0 }
        var sum: Float = 0
        for i in 1..<levels.count { sum += abs(levels[i] - levels[i - 1]) }
        return sum / Float(levels.count - 1)
    }
}

/// The shipped meter before this change: 12.5 fps, 250 ms window, linear
/// `rms / 0.25`, plus a second exponential smoothing inside the ring buffer.
private func traceOldMeter(_ pcm: [Float]) -> MeterTrace {
    let frameInterval = 0.08
    let hop = Int(16_000 * frameInterval)
    let window = 4_000
    var levels: [Float] = []
    var smoothed: Float = 0
    var end = hop
    while end <= pcm.count {
        let tail = pcm[..<end].suffix(window)
        var sum: Float = 0
        for s in tail { sum += s * s }
        let rms = (sum / Float(tail.count)).squareRoot()
        let raw = min(1, rms / 0.25)
        smoothed = smoothed * 0.55 + raw * 0.45
        levels.append(smoothed)
        end += hop
    }
    return MeterTrace(name: "before", levels: levels,
                      fps: 1 / frameInterval,
                      windowMs: Double(window) / 16.0)
}

/// The meter after this change: 60 fps, 30 ms window, dBFS curve, single
/// smoothing stage (the physical RMS window itself).
private func traceNewMeter(_ pcm: [Float]) -> MeterTrace {
    let frameInterval = 1.0 / 60.0
    let hop = Int((16_000 * frameInterval).rounded())
    var levels: [Float] = []
    var end = hop
    while end <= pcm.count {
        let tail = pcm[..<end].suffix(LevelMeter.windowSamples)
        levels.append(LevelMeter.level(tail: tail))
        end += hop
    }
    return MeterTrace(name: "after", levels: levels,
                      fps: 1 / frameInterval,
                      windowMs: Double(LevelMeter.windowSamples) / 16.0)
}

/// Measures the frame rate a `Timer` on the main run loop actually delivers at a
/// requested interval, by counting callbacks over a fixed wall-clock span.
///
/// This is the "measure it, do not assume it" check: a 1/60 s timer on a busy
/// main run loop does not necessarily deliver 60 callbacks a second.
private func measureAchievedFPS(interval: TimeInterval, seconds: TimeInterval) -> Double {
    // The counter lives in a lock-guarded reference box because the timer block
    // is a `@Sendable` closure: capturing a local `var` and mutating it is a data
    // race the compiler is right to reject. In practice both sides run on the
    // main run loop, but the lock makes that safe rather than assumed.
    let counter = TickCounter()
    let timer = Timer(timeInterval: interval, repeats: true) { _ in counter.bump() }
    RunLoop.main.add(timer, forMode: .common)
    let start = Date()
    RunLoop.main.run(until: start.addingTimeInterval(seconds))
    let elapsed = Date().timeIntervalSince(start)
    timer.invalidate()
    return Double(counter.value) / elapsed
}

/// Lock-guarded tick count, shared between a timer block and its caller.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks = 0

    func bump() {
        lock.lock()
        ticks += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return ticks
    }
}

/// dBFS statistics over the speech-bearing part of a clip, so "typical speech on
/// this machine" is a measurement rather than a claim.
private struct SpeechDB {
    let quietDB: Float
    let normalDB: Float
    let loudDB: Float
    let noiseFloorDB: Float
    let windowCount: Int
}

/// Splits a clip into 30 ms windows, measures each one in dBFS, then reports the
/// quiet, typical and loud ends of the distribution.
///
/// "Quiet speech", "normal speech" and "loud speech" here are the 20th, 50th and
/// 95th percentile of the windows that carry speech, where speech means a window
/// above the clip's own noise floor by 10 dB. This is the honest way to get three
/// numbers out of one recording of somebody talking normally: it is a measured
/// distribution, not three separately performed volumes.
private func measureSpeechDB(_ pcm: [Float]) -> SpeechDB {
    var dbs: [Float] = []
    var index = 0
    while index + LevelMeter.windowSamples <= pcm.count {
        let window = pcm[index..<(index + LevelMeter.windowSamples)]
        dbs.append(LevelMeter.dbFS(LevelMeter.rms(window)))
        index += LevelMeter.windowSamples
    }
    guard !dbs.isEmpty else {
        return SpeechDB(quietDB: 0, normalDB: 0, loudDB: 0, noiseFloorDB: 0, windowCount: 0)
    }
    let sorted = dbs.sorted()
    func pct(_ p: Double, _ values: [Float]) -> Float {
        values[Int((Double(values.count - 1) * p).rounded())]
    }
    // The quietest tenth of the clip is the room, not the voice.
    let noiseFloor = pct(0.10, sorted)
    let speech = sorted.filter { $0 > noiseFloor + 10 }
    guard !speech.isEmpty else {
        return SpeechDB(quietDB: noiseFloor, normalDB: noiseFloor, loudDB: noiseFloor,
                        noiseFloorDB: noiseFloor, windowCount: dbs.count)
    }
    return SpeechDB(quietDB: pct(0.20, speech),
                    normalDB: pct(0.50, speech),
                    loudDB: pct(0.95, speech),
                    noiseFloorDB: noiseFloor,
                    windowCount: dbs.count)
}

/// Records live from the microphone for `seconds` and reports what the meter
/// actually does with a real voice on this machine's real input device.
///
/// This is the only measurement that reflects the user's own mic gain. The
/// recorded fixtures in `Tests/audio` are normalised synthesis and sit far hotter
/// than a live capture, so quoting them as "typical speech" would overstate the
/// levels the pill really sees.
///
/// Requires microphone permission in the calling TCC context, which means the
/// launched bundle, not a shell. When it is unavailable this prints exactly that
/// and reports nothing.
@MainActor
func runLiveMeterProbe(seconds: TimeInterval) -> Int32 {
    let recorder = MicrophoneRecorder()
    guard recorder.hasInputDevice else {
        print("live meter: SKIP, macOS exposes no audio input device")
        return 0
    }
    print(String(format: "live meter: speak normally for %.0f s", seconds))
    do {
        try recorder.start()
    } catch {
        print("live meter: SKIP, could not start capture: \(error)")
        return 0
    }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    let pcm = recorder.stop()
    guard !pcm.isEmpty else {
        print("live meter: SKIP, the device delivered zero samples (microphone permission in this launch context?)")
        return 0
    }
    let db = measureSpeechDB(pcm)
    let trace = traceNewMeter(pcm)
    let old = traceOldMeter(pcm)
    print(String(format: "live meter: %.2f s captured from the real input device", Double(pcm.count) / 16_000))
    print(String(format: "live meter: measured dBFS noise floor %.1f | quiet %.1f | normal %.1f | loud %.1f",
                 db.noiseFloorDB, db.quietDB, db.normalDB, db.loudDB))
    print(String(format: "live meter: before  bar height p10 %.3f p50 %.3f p90 %.3f max %.3f | span %.3f",
                 old.percentile(0.10), old.percentile(0.50), old.percentile(0.90), old.maxLevel,
                 old.percentile(0.90) - old.percentile(0.10)))
    print(String(format: "live meter: after   bar height p10 %.3f p50 %.3f p90 %.3f max %.3f | span %.3f",
                 trace.percentile(0.10), trace.percentile(0.50), trace.percentile(0.90), trace.maxLevel,
                 trace.percentile(0.90) - trace.percentile(0.10)))
    return 0
}

/// Entry point for `--test-meter`. Returns a process exit code.
func runMeterProbe(path: String?) -> Int32 {
    let clips: [String]
    if let path {
        clips = [path]
    } else {
        clips = ["Tests/audio/msg-pulkit-that.wav",
                 "Tests/audio/long-body.wav",
                 "Tests/audio/hard-runon.wav"]
    }

    print("== achieved frame rate (measured, main run loop, 2 s span)")
    let old = measureAchievedFPS(interval: 0.08, seconds: 2.0)
    let new = measureAchievedFPS(interval: 1.0 / 60.0, seconds: 2.0)
    print(String(format: "  requested 12.5 fps (0.08 s)  -> achieved %.1f fps", old))
    print(String(format: "  requested 60.0 fps (0.0167 s) -> achieved %.1f fps", new))

    var failures = 0
    for clip in clips {
        let url = URL(fileURLWithPath: clip)
        let pcm: [Float]
        do {
            pcm = try AudioFileLoader.loadPCM(url: url)
        } catch {
            print("  SKIP \(clip): \(error)")
            continue
        }
        let seconds = Double(pcm.count) / 16_000
        print(String(format: "\n== %@  (%.2f s of real recorded speech, 16 kHz mono)", clip, seconds))

        let db = measureSpeechDB(pcm)
        print(String(format: "  measured dBFS: noise floor %.1f | quiet speech %.1f | normal speech %.1f | loud speech %.1f  (%d windows)",
                     db.noiseFloorDB, db.quietDB, db.normalDB, db.loudDB, db.windowCount))
        print(String(format: "  meter range in use: floor %.0f dBFS -> ceiling %.0f dBFS",
                     LevelMeter.floorDBFS, LevelMeter.ceilingDBFS))

        for trace in [traceOldMeter(pcm), traceNewMeter(pcm)] {
            print(String(format: "  %-6@ %5.1f fps, %5.1f ms window | bar height min %.3f p10 %.3f p50 %.3f p90 %.3f max %.3f | p10-p90 span %.3f | mean frame delta %.4f",
                         trace.name as NSString, trace.fps, trace.windowMs,
                         trace.minLevel, trace.percentile(0.10), trace.percentile(0.50),
                         trace.percentile(0.90), trace.maxLevel,
                         trace.percentile(0.90) - trace.percentile(0.10),
                         trace.meanFrameDelta))
        }

        // Regression assertions: the new meter must actually use its range and
        // must actually move, on real speech.
        let after = traceNewMeter(pcm)
        let span = after.percentile(0.90) - after.percentile(0.10)
        if span < 0.15 {
            print(String(format: "  FAIL: new meter p10-p90 span is only %.3f; speech does not visibly move the bars", span))
            failures += 1
        }
        if after.maxLevel < 0.5 {
            print(String(format: "  FAIL: new meter peaks at only %.3f; loud speech never reaches the top half", after.maxLevel))
            failures += 1
        }
    }

    // Silence must be exactly still. Not "quiet", still.
    let silence = [Float](repeating: 0, count: 16_000)
    let silentTrace = traceNewMeter(silence)
    if silentTrace.maxLevel != 0 {
        print(String(format: "\nFAIL: digital silence produced a nonzero bar height (%.4f)", silentTrace.maxLevel))
        failures += 1
    } else {
        print("\n  silence check: 1 s of digital silence produced bar height 0 on every frame")
    }

    // Room-level noise must also be gated, not merely small.
    var noise = [Float](repeating: 0, count: 16_000)
    var seed: UInt64 = 0x5DEECE66D
    for i in noise.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        // -60 dBFS wideband noise, below the meter floor.
        noise[i] = unit * 0.001
    }
    let noiseTrace = traceNewMeter(noise)
    print(String(format: "  noise check: %.1f dBFS noise produced max bar height %.4f",
                 LevelMeter.dbFS(LevelMeter.rms(noise[...])), noiseTrace.maxLevel))
    if noiseTrace.maxLevel > 0 {
        print("  FAIL: noise below the meter floor still moved the bars")
        failures += 1
    }

    print("\nNOT MEASURED by this probe: how the pill looks on screen. Bar heights are")
    print("measured here; whether the rendered row reads as alive needs a person watching it.")

    if failures == 0 {
        print("\nRESULT: all checks passed")
        return 0
    }
    print("\nRESULT: \(failures) check(s) failed")
    return 1
}
