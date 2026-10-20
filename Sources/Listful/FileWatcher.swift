import Foundation

/// Tells its owner when a file may have changed on disk. Watches the file
/// itself (for in-place writes) and its folder (for saves that replace the
/// file, as Listful's own and iCloud's do). The file is re-opened after each
/// event, since a replacement leaves the old descriptor pointing at the old
/// file. Bursts of events are coalesced into one call.
@MainActor final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    // Touched from deinit, which isn't main-actor isolated; only ever used on main.
    nonisolated(unsafe) private var folderSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var fileSource: DispatchSourceFileSystemObject?
    private var isChangePending = false

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        folderSource = makeSource(path: url.deletingLastPathComponent().path, events: .write)
        watchFile()
    }

    deinit {
        folderSource?.cancel()
        fileSource?.cancel()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func changed() {
        watchFile()
        guard !isChangePending else { return }
        isChangePending = true
        Task { [weak self] in
            // Let a burst of writes (e.g. iCloud delivering a file) settle.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            isChangePending = false
            onChange()
        }
    }
}
