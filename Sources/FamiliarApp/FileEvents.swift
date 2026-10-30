import CoreServices
import Foundation

/// Watches the chosen folders with FSEvents and, once things go quiet for a few seconds, calls `onChange` with the
/// paths that changed, so a new file is searchable soon after it lands without re-checking every folder. `full` is
/// true when macOS says it lost track (events dropped, a disk mounted or unmounted): then everything is checked.
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let onChange: ([String], Bool) -> Void
    private var pending: DispatchWorkItem?
    private var changedPaths = Set<String>()
    private var needsFull = false

    init(onChange: @escaping ([String], Bool) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ folders: [URL]) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lostTrack = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount)
            var full = false
            for i in 0..<count where flags[i] & lostTrack != 0 { full = true }
            // Changes only inside hidden folders (.git churn, editors' swap files) don't matter.
            let visible = list.filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            if !visible.isEmpty || full { watcher.changed(visible, full: full) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func changed(_ paths: [String], full: Bool) {
        changedPaths.formUnion(paths)
        needsFull = needsFull || full
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.changedPaths), full = self.needsFull
            self.changedPaths.removeAll()
            self.needsFull = false
            self.onChange(paths, full)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
