import Foundation

/// Calls back on the main actor when anything in a folder changes: a file saved in place, or
/// replaced by an editor's atomic save.
@MainActor
final class DirectoryWatcher {
    private var sources: [any DispatchSourceFileSystemObject] = []
    private let directory: URL
    private let onChange: @MainActor () -> Void
    private var debounce: Task<Void, Never>?

    init(_ directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
        arm()
    }

    /// Watches the folder and each file in it; files are re-watched after every change, since an
    /// atomic save swaps in a new file.
    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in [directory] + files {
            let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.arm()
            self.onChange()
        }
    }

    isolated deinit {
        for source in sources { source.cancel() }
    }
}
