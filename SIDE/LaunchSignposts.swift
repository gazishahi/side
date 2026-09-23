import Foundation
import Heron
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

    /// Milliseconds from the process's exec to now — the part of launch that happens before any
    /// of our code runs (dyld, framework loading, static initializers). Not measurable from inside
    /// by timers, which is why every earlier launch number started at `main` and quietly left this
    /// out; a half-bounce budget has to include it.
    static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// Printed once, with the first frame, so the report shows the whole span the user waits.
    static func reportProcessStart() {
        guard reportingEnabled, let sinceStart = millisecondsSinceProcessStart() else { return }
        print(String(format: "[launch] processStart→firstFrame (wall): %.1f ms", sinceStart))
        fflush(stdout)
    }

    static func end(_ name: StaticString) {
        lock.lock()
        let entry = active.removeValue(forKey: "\(name)")
        lock.unlock()
        guard let (id, started) = entry else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
        // Printed when asked for, in *any* build configuration — not `#if DEBUG`.
        //
        // Debug-only reporting is how you end up quoting Debug numbers, which are not the
        // numbers users experience: this app builds Debug with `-Onone` for its own sources.
        // A launch claim has to be measurable in the configuration that ships, so the report
        // is gated on a launch argument rather than on the build.
        //
        //     Side.app/Contents/MacOS/Side -SideLaunchReport YES
        if reportingEnabled {
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print(String(format: "[launch] %@: %.1f ms", "\(name)", elapsed))
            fflush(stdout)
        }
    }

    /// Read once — `UserDefaults` lookups on every signpost would themselves show up in the
    /// measurement.
    private static let reportingEnabled = UserDefaults.standard.bool(forKey: "SideLaunchReport")
}
