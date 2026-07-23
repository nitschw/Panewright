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
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    public init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
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
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
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
