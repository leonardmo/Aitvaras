import CoreServices
import Foundation

/// Small recursive macOS file watcher backed by FSEvents. It deliberately
/// emits only an invalidation signal: Indexer remains the source of truth and
/// performs its existing mtime/hash scan after events have been coalesced.
final class FileSystemWatcher: @unchecked Sendable {
    let events: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let paths: [String]
    private let queue = DispatchQueue(label: "app.aitvaras.rag-fsevents", qos: .utility)
    private let lock = NSLock()
    private var eventStream: FSEventStreamRef?

    init(paths: [String]) {
        self.paths = paths
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard eventStream == nil, !paths.isEmpty else { return eventStream != nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags) else { return false }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        eventStream = stream
        return true
    }

    func stop() {
        lock.lock()
        let stream = eventStream
        eventStream = nil
        lock.unlock()

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        continuation.finish()
    }

    private static let callback: FSEventStreamCallback = {
        _, clientInfo, eventCount, _, _, _ in
        guard eventCount > 0, let clientInfo else { return }
        let watcher = Unmanaged<FileSystemWatcher>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()
        watcher.continuation.yield(())
    }
}
