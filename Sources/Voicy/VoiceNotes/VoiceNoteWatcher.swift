import Foundation
import CoreServices

/// Watches a directory tree (via FSEvents with file-level events) for newly
/// created `.opus` files.
///
/// - Recurses automatically (FSEvents watches the whole subtree).
/// - Handles paths containing spaces and arbitrarily deep nesting.
/// - A file that is still being written is not emitted until its size has
///   stopped changing (`stabilityDelay`), so readers never see a truncated file.
///
/// Concurrency: all mutable state is confined to the serial `queue` (or is
/// written once before the run-loop thread starts). `@unchecked Sendable` is
/// safe because the FSEvents C callback hops onto `queue` before touching any
/// state; nothing is mutated from the run-loop thread directly.
final class VoiceNoteWatcher: @unchecked Sendable {

    /// Invoked on the watcher's serial queue when a settled `.opus` file is
    /// detected. The URL is absolute. Assigned after init so callers can build
    /// self-referential wiring (e.g. a pipeline whose callback captures itself).
    private var onNewOpus: ((URL) -> Void)?

    private var stream: FSEventStreamRef?
    private var runLoopThread: Thread?
    private let stabilityDelay: TimeInterval
    private let maxStabilityChecks: Int

    /// Serial queue on which callbacks and stability checks run, and through
    /// which `onNewOpus` is delivered.
    private let queue = DispatchQueue(label: "voicy.voicenotes.watcher")
    private var stopped = false
    private var pendingSizes: [String: Int] = [:]   // path -> last observed size
    private var pendingChecks: [String: Int] = [:]  // path -> consecutive stable counts

    init(stabilityDelay: TimeInterval = 1.0,
         maxStabilityChecks: Int = 8) {
        self.stabilityDelay = stabilityDelay
        self.maxStabilityChecks = maxStabilityChecks
    }

    /// The signature of `FSEventStreamCreate`'s callback is fixed at stream
    /// creation time, so the handler is attached after init completes. Deferred
    /// so a pipeline that needs to capture itself in the handler can do so
    /// without referencing `self` before initialization finishes.
    func setOnNewOpus(_ handler: @escaping (URL) -> Void) {
        queue.sync {
            onNewOpus = handler
        }
    }

    /// Start watching `root` (a directory). FSEvents emits file-level events
    /// for the entire subtree. Returns immediately; events are delivered
    /// asynchronously.
    func start(watching root: URL) {
        let rootPath = root.path
        guard FileManager.default.fileExists(atPath: rootPath) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, cfPaths, flagsPtr, _ in
            guard let info else { return }
            let watcher = Unmanaged<VoiceNoteWatcher>.fromOpaque(info).takeUnretainedValue()
            // The C callback runs on the run-loop thread. Materialize the C
            // arrays into Sendable Swift values here, before hopping onto the
            // watcher's serial queue — raw pointers are not Sendable and must
            // not cross the queue boundary.
            let paths: [String]? = {
                let array = Unmanaged<CFArray>.fromOpaque(cfPaths).takeUnretainedValue() as NSArray
                return array as? [String]
            }()
            let flags: [UInt32] = {
                var values = [UInt32]()
                values.reserveCapacity(numEvents)
                for i in 0..<numEvents {
                    values.append(flagsPtr[i])
                }
                return values
            }()
            watcher.queue.async {
                watcher.handleFileEvents(paths: paths, flags: flags)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }

        self.stream = stream
        stopped = false

        let thread = Thread { [weak self] in
            guard let self, let stream = self.stream else { return }
            let runLoop = RunLoop.current
            FSEventStreamScheduleWithRunLoop(
                stream, runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
            guard FSEventStreamStart(stream) else { return }
            while !self.stopped {
                runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        thread.name = "voicy.voicenotes.watcher-runloop"
        runLoopThread = thread
        thread.start()
    }

    /// Stop watching and tear down the FSEvents stream.
    func stop() {
        queue.sync {
            stopped = true
        }
        runLoopThread = nil
    }
}
// MARK: - Event handling

extension VoiceNoteWatcher {

    private func handleFileEvents(paths: [String]?,
                                  flags: [UInt32]) {
        guard let paths else { return }
        for (i, path) in paths.enumerated() {
            guard path.hasSuffix(".opus"),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let eventFlags = i < flags.count ? flags[i] : 0
            // File-level flags: item created, renamed, or modified. A rename
            // into place (WhatsApp writes then renames) also counts as new.
            let isNewOrModified = (eventFlags & UInt32(kFSEventStreamEventFlagItemCreated) != 0) ||
                                  (eventFlags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0) ||
                                  (eventFlags & UInt32(kFSEventStreamEventFlagItemModified) != 0)
            guard isNewOrModified else { continue }
            scheduleStabilityCheck(path: path)
        }
    }

    /// Repeatedly re-stat `path` until its size is stable (or we hit the max
    /// check count), then emit it.
    private func scheduleStabilityCheck(path: String) {
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let lastSize = pendingSizes[path] ?? -1
        pendingSizes[path] = currentSize

        if currentSize == lastSize, lastSize >= 0 {
            let stable = (pendingChecks[path] ?? 0) + 1
            pendingChecks[path] = stable
            if stable >= 2 {
                pendingSizes.removeValue(forKey: path)
                pendingChecks.removeValue(forKey: path)
                emit(url: URL(fileURLWithPath: path))
                return
            }
        } else {
            pendingChecks[path] = 0
        }

        // Not stable yet; re-check after a delay, unless we've tried too long.
        let checksSoFar = pendingChecks[path] ?? 0
        if checksSoFar >= maxStabilityChecks {
            pendingSizes.removeValue(forKey: path)
            pendingChecks.removeValue(forKey: path)
            emit(url: URL(fileURLWithPath: path))
            return
        }

        queue.asyncAfter(deadline: .now() + stabilityDelay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.scheduleStabilityCheck(path: path)
        }
    }

    private func emit(url: URL) {
        onNewOpus?(url)
    }
}