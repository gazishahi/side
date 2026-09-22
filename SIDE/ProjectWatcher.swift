import Foundation
import CoreServices

/// One FSEvents stream per project root, so open buffers, the file index, and `@`-mention
/// completion learn about changes made outside the editor — the user's terminal, `git pull`,
/// and above all the agent's own applied edits, which in an agentic IDE are the common case.
///
/// Before this there was no watching at all (2026-09-01 audit, H8): a clean tab showed stale
/// content indefinitely while Heron's read tools served disk, so the user and the agent were
/// discussing different code. Events are delivered on the main queue, batched by the stream's
/// latency; consumers get standardised file URLs and decide for themselves what to do.
@MainActor
final class ProjectWatcher {
    /// Posted with the watcher's root as `object` and `userInfo[pathsKey]` as `[String]`, for
    /// observers that don't own the watcher (Think's mention index).
    static let didChangeNotification = Notification.Name("SideProjectFilesDidChange")
    static let pathsKey = "paths"

    let root: URL
    private let onChange: ([URL]) -> Void
    /// Held in a Sendable box so `deinit` (nonisolated under Swift 6) can tear it down.
    private final class StreamBox: @unchecked Sendable { var ref: FSEventStreamRef? }
    private let box = StreamBox()

    init(root: URL, latency: TimeInterval = 0.4, onChange: @escaping ([URL]) -> Void) {
        // FSEvents reports real paths, so watch the real path — /var vs /private/var would otherwise
        // never match an open tab's (already symlink-resolved) URL.
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.onChange = onChange
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        // Not `IgnoreSelf`: the agent's write_file and Side's own saves are this process too, and
        // the index needs to hear about them. Open tabs tell their own writes apart by mtime.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [self.root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        box.ref = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream = box.ref {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info else { return }
        let paths = (unsafeBitCast(eventPaths, to: CFArray.self) as? [String]) ?? []
        let opaque = UInt(bitPattern: info)
        // Scheduled on the main dispatch queue above, so this is main-actor work already.
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: opaque) else { return }
            Unmanaged<ProjectWatcher>.fromOpaque(pointer).takeUnretainedValue().deliver(paths)
        }
    }

    private func deliver(_ paths: [String]) {
        // Git's own bookkeeping churns constantly and is nobody's file; Side's state directory
        // likewise. Worktree files that a checkout rewrites still arrive on their own paths.
        let urls = paths
            .filter { path in
                let components = path.split(separator: "/")
                return !components.contains(".git") && !components.contains(".side")
            }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard !urls.isEmpty else { return }
        onChange(urls)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: root, userInfo: [Self.pathsKey: urls.map(\.path)])
    }
}
