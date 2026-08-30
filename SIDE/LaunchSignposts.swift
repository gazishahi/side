import Foundation
import os.signpost

/// Launch instrumentation, so claims about startup can be measured rather than asserted.
///
/// The 2026-08-30 audit flagged the absence of these as the reason no performance claim about
/// launch could be made honestly. They cost nothing when Instruments isn't recording — the
/// signpost calls compile down to a check against a disabled log.
///
/// To read them: Instruments → os_signpost, or
/// `xcrun xctrace record --template 'os_signpost' --launch -- <path to Side.app>`.
enum LaunchSignposts {
    private static let log = OSLog(subsystem: "com.side.app", category: "Launch")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: [String: (OSSignpostID, CFAbsoluteTime)] = [:]

    static func begin(_ name: StaticString, key: String? = nil) {
        let id = OSSignpostID(log: log)
        lock.lock()
        active["\(name)"] = (id, CFAbsoluteTimeGetCurrent())
        lock.unlock()
        os_signpost(.begin, log: log, name: name, signpostID: id)
    }

    static func end(_ name: StaticString) {
        lock.lock()
        let entry = active.removeValue(forKey: "\(name)")
        lock.unlock()
        guard let (id, started) = entry else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
        // Also printed in debug builds: Instruments is the right tool, but a number in the
        // console is what actually gets looked at during day-to-day work.
        #if DEBUG
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print(String(format: "[launch] %@: %.1f ms", "\(name)", elapsed))
        #endif
    }
}
