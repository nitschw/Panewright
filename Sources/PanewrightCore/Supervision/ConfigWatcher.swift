import Darwin
import Foundation

/// Watches the Panewright config directory and fires (debounced) when
/// anything inside changes. Editors save atomically (write to temp + rename),
/// so watching the directory is more reliable than watching the file's vnode.
public final class ConfigWatcher: @unchecked Sendable {
    public struct WatchError: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "cannot watch \(path)" }
    }

    private let queue = DispatchQueue(label: "dev.panewright.config-watcher")
    private let directory: URL
    private let watchedFile: URL?
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var poll: DispatchSourceTimer?
    private var lastModified: Date?

    public init(
        directory: URL, file: URL? = nil, onChange: @escaping @Sendable () -> Void
    ) {
        self.directory = directory
        self.watchedFile = file
        self.onChange = onChange
    }

    public func start() throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw WatchError(path: directory.path)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .extend],
            queue: queue)
        source.setEventHandler { [weak self] in
            // Directory events fire for *any* file in the config folder —
            // todo.txt, pills.tsv, favorites — and re-applying on those
            // caused a rewrite → apply → reload → rewrite storm. Only a
            // genuine change to the config file counts.
            self?.scheduleChangeIfConfigTouched()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
        startModificationPoll()
    }

    /// Directory events miss in-place rewrites (some editors, and any tool
    /// that truncates rather than renames), so also watch the file's mtime.
    private func startModificationPoll() {
        guard let watchedFile else { return }
        lastModified = Self.modificationDate(of: watchedFile)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = Self.modificationDate(of: watchedFile)
            if let current, current != self.lastModified {
                self.lastModified = current
                self.scheduleChange()
            }
        }
        timer.resume()
        poll = timer
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    public func stop() {
        source?.cancel()
        source = nil
        poll?.cancel()
        poll = nil
    }

    private func scheduleChangeIfConfigTouched() {
        guard let watchedFile else {
            scheduleChange()
            return
        }
        let current = Self.modificationDate(of: watchedFile)
        guard current != lastModified else { return }
        lastModified = current
        scheduleChange()
    }

    // Debounce: editors produce bursts of directory events per save.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    deinit {
        stop()
    }
}
