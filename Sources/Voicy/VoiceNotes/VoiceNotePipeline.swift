import Foundation

/// Wires the watcher, decoder, and transcriber together into one self-contained
/// voice-note pipeline. The main app instantiates this with its own
/// `Transcriber`; the standalone CLI supplies `StubTranscriber`.
///
/// No dependency on any other Voicy module — safe to build on its own.
///
/// Concurrency: the pipeline is immutable after init (its state is the watcher,
/// the transcriber, and two closures). Work is dispatched onto the serial
/// `workQueue`, so `@unchecked Sendable` is safe.
final class VoiceNotePipeline: @unchecked Sendable {

    /// Delivers a completed transcription. `url` is the source `.opus` file.
    /// `text` is the transcription result.
    typealias ResultHandler = (URL, Result<String, Error>) -> Void

    private let watcher: VoiceNoteWatcher
    private let transcriber: any Transcriber
    private let onResult: ResultHandler
    private let root: URL
    private let workQueue = DispatchQueue(label: "voicy.voicenotes.decode",
                                          qos: .userInitiated)

    /// - Parameters:
    ///   - root: the directory to watch for `.opus` files.
    ///   - transcriber: engine used to turn PCM into text.
    ///   - hintsProvider: optional closure mapping a file URL to recognition
    ///     hints (contact name, chat topic, etc.). Defaults to empty.
    ///   - onResult: called once per settled file with the transcription.
    init(root: URL,
         transcriber: any Transcriber,
         hintsProvider: @escaping (URL) -> [String] = { _ in [] },
         onResult: @escaping ResultHandler) {
        self.transcriber = transcriber
        self.onResult = onResult
        self.root = root
        // Assign the stored watcher first so `self` is fully initialized, then
        // attach the callback (which captures `self` weakly). Referencing
        // `self.watcher` or `self` before every stored property is set would
        // trigger "self.watcher used before being initialized".
        self.watcher = VoiceNoteWatcher(stabilityDelay: 1.0, maxStabilityChecks: 8)
        self.watcher.setOnNewOpus { [weak self] url in
            self?.handle(url: url, hints: hintsProvider(url))
        }
    }

    func start() {
        watcher.start(watching: root)
    }

    func stop() {
        watcher.stop()
    }

    private func handle(url: URL, hints: [String]) {
        workQueue.async {
            do {
                let pcm = try OpusDecoder.decode(url: url)
                let text = try awaitSynchronousTranscribe(pcm: pcm, hints: hints, transcriber: self.transcriber)
                self.onResult(url, .success(text))
            } catch {
                self.onResult(url, .failure(error))
            }
        }
    }
}

// MARK: - Async bridging

/// Runs an async `Transcriber` call from a synchronous context by blocking a
/// work-queue thread until it completes. Acceptable for the decode pipeline;
/// the app can call the async entry point directly if preferred.
private func awaitSynchronousTranscribe(pcm: [Float],
                                        hints: [String],
                                        transcriber: any Transcriber) throws -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "voicy.voicenotes.transcribe-bridge")
    nonisolated(unsafe) var result: Result<String, Error> = .failure(NSError(domain: "voicy", code: -1))
    queue.async {
        Task {
            do {
                let text = try await transcriber.transcribe(pcm: pcm, hints: hints)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
    }
    semaphore.wait()
    return try result.get()
}