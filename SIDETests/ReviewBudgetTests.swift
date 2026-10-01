import XCTest
@testable import Side

/// Review with a big change set: how long showing it takes, what it costs in memory, and how
/// scrolling through it holds up. Limits in `Budgets.table`. `SIDE_REVIEW_DIFF` names a real
/// `git diff` output to use instead of the generated one.
@MainActor
final class ReviewBudgetTests: XCTestCase {
    /// 500 files of real-looking Swift: most modified in a few places, some new, some deleted.
    private static func generatedDiff(files: Int = 500) -> String {
        var out = ""
        for f in 0..<files {
            let path = "Sources/Module\(f / 50)/File\(f).swift"
            out += "diff --git a/\(path) b/\(path)\n"
            switch f % 10 {
            case 0:
                out += "new file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,120 @@\n"
                for l in 0..<120 { out += "+    let value\(l) = compute(\(l), scale: \(f)) // added\n" }
            case 1:
                out += "deleted file mode 100644\n--- a/\(path)\n+++ /dev/null\n@@ -1,60 +0,0 @@\n"
                for l in 0..<60 { out += "-    func removed\(l)() -> Int { \(l) }\n" }
            default:
                out += "--- a/\(path)\n+++ b/\(path)\n"
                for h in 0..<4 {
                    let start = 1 + h * 80
                    out += "@@ -\(start),10 +\(start),12 @@ struct Type\(f) {\n"
                    for l in 0..<3 { out += "     let context\(h)_\(l) = \"unchanged\"\n" }
                    out += "-    var old\(h) = legacy(\(h))\n"
                    for l in 0..<3 { out += "+    var new\(h)_\(l) = modern(\(h), \(l))\n" }
                    for l in 0..<6 { out += "     let trailing\(h)_\(l) = \(l)\n" }
                }
            }
        }
        return out
    }

    /// A real diff, its files stepped through one at a time as holding the down arrow in the file
    /// list does (SIDE_REVIEW_DIFF; SIDE_REVIEW_STEP_FROM, the first file's path suffix). Each
    /// step's time to a drawn frame goes to SIDE_REVIEW_STEP_OUT. Skipped without a diff.
    func testSteppingThroughFiles() throws {
        try Budgets.skipUnlessEnabled()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SIDE_REVIEW_DIFF"] else { throw XCTSkip("set SIDE_REVIEW_DIFF") }
        let diff = try String(contentsOfFile: path, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1512, height: 945), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewer = DiffDocumentView(frame: window.contentRect(forFrameRect: window.frame))
        viewer.autoresizingMask = [.width, .height]
        window.contentView = viewer
        window.orderFront(nil)
        if env["SIDE_REVIEW_SIDE_BY_SIDE"] == "1" { viewer.diffLayout = .sideBySide }
        viewer.render(diffText: diff)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        Budgets.settle(2)
        let files = viewer.diff.files
        let start = env["SIDE_REVIEW_STEP_FROM"].flatMap { suffix in files.firstIndex { $0.path.hasSuffix(suffix) } } ?? 0
        let count = Int(env["SIDE_REVIEW_STEP_COUNT"] ?? "30") ?? 30
        let out = env["SIDE_REVIEW_STEP_OUT"] ?? "/tmp/side-review-steps.txt"
        try? "\(getpid())".write(toFile: out + ".pid", atomically: true, encoding: .utf8)
        Budgets.settle(1.5)  // for a profiler to attach
        var lines: [String] = []
        let cpu = Budgets.cpuSeconds(), wall = CACurrentMediaTime()
        for index in start..<min(files.count, start + count) {
            let began = CACurrentMediaTime()
            viewer.scrollToFile(index)
            window.displayIfNeeded()
            for editor in viewer.editors { editor.render() }
            let ms = (CACurrentMediaTime() - began) * 1000
            // As key repeat does: the next press about 33 ms later.
            Budgets.settle(Double(env["SIDE_REVIEW_STEP_PAUSE"] ?? "0.033") ?? 0.033)
            let longest = files[index].hunks.flatMap(\.lines).map { $0.slice.utf16.count }.max() ?? 0
            lines.append(String(format: "%7.1f ms  +%d -%d  longest line %d  %@", ms, files[index].addedCount, files[index].removedCount, longest, files[index].path))
        }
        lines.append(String(format: "total %.1f s, %.0f%% of a core", CACurrentMediaTime() - wall, (Budgets.cpuSeconds() - cpu) / (CACurrentMediaTime() - wall) * 100))
        try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    func testABigChangeSet() throws {
        try Budgets.skipUnlessEnabled()
        let env = ProcessInfo.processInfo.environment
        let diff = try env["SIDE_REVIEW_DIFF"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? Self.generatedDiff()
        let fileCount = UnifiedDiff.parse(diff).files.count
        var worst: (open: Double, memory: Double, scroll: Double) = (0, 0, 0)
        var flingCPU = 0.0, flingDetail = ""
        var details: [String] = []
        for layout in [DiffLayout.unified, .sideBySide] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
            let viewer = DiffDocumentView()
            viewer.diffLayout = layout
            container.addSubview(viewer)
            NSLayoutConstraint.activate([
                viewer.topAnchor.constraint(equalTo: container.topAnchor), viewer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                viewer.leadingAnchor.constraint(equalTo: container.leadingAnchor), viewer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            // The file list beside it, following the diff as the stage has it follow.
            let rail = ReviewFileRail(frame: NSRect(x: 0, y: 0, width: 240, height: 900))
            container.addSubview(rail)
            viewer.onTopFileChange = { [weak rail] index in rail?.follow(index) }
            window.contentView = container
            window.orderFront(nil)
            // The first frame in a process brings the graphics driver's working memory and the
            // window's drawables, whatever is drawn: a small diff first, so the measure is the
            // change set's.
            viewer.render(diffText: Self.generatedDiff(files: 2))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            Budgets.settle(0.5)
            let before = Budgets.footprintMB()
            var open = 0.0
            autoreleasepool {
                let start = CACurrentMediaTime()
                viewer.render(diffText: diff)
                rail.items = viewer.diff.files.map { ReviewFileRail.Item(path: $0.path, added: $0.addedCount, removed: $0.removedCount,
                                                                          isNew: $0.isNew, isDeleted: $0.isDeleted, viewed: false) }
                window.layoutIfNeeded()
                window.displayIfNeeded()
                open = (CACurrentMediaTime() - start) * 1000
            }
            Budgets.settle(1)
            // As a person scrolls: 45 points a frame from the top, for 600 frames. Less any
            // wait for a free drawable: this loop outruns the display.
            var frames: [Double] = []
            var peak = Budgets.footprintMB()
            if let first = viewer.editors.first {
                var y: CGFloat = 0
                for _ in 0..<600 {
                    y += 45
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        var waited = 0.0
                        for editor in viewer.editors { editor.scrollY = y; editor.render(); waited += editor.drawableWaitMilliseconds.last ?? 0 }
                        frames.append((CACurrentMediaTime() - start) * 1000 - waited)
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
                    }
                    peak = max(peak, Budgets.footprintMB())
                }
                _ = first
            }
            // Then the whole change set, top to bottom, as someone reading every file would.
            if layout == .unified, let first = viewer.editors.first {
                let end = first.documentLayout.contentHeight
                let cpuStart = Budgets.cpuSeconds(), wallStart = CACurrentMediaTime()
                var y: CGFloat = 0, allFrames: [Double] = []
                while y < end {
                    y += 90
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        var waited = 0.0
                        for editor in viewer.editors { editor.scrollY = y; editor.render(); waited += editor.drawableWaitMilliseconds.last ?? 0 }
                        allFrames.append((CACurrentMediaTime() - start) * 1000 - waited)
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
                    }
                    if allFrames.count % 20 == 0 { peak = max(peak, Budgets.footprintMB()) }
                }
                let wall = CACurrentMediaTime() - wallStart
                print(String(format: "REVIEWALL %d frames over %.0f pt in %.1f s, CPU %.0f%%, frame p50 %.2f p99 %.2f ms, peak +%.0f MB", allFrames.count, end, wall,
                             (Budgets.cpuSeconds() - cpuStart) / wall * 100, Budgets.percentile(allFrames, 0.5), Budgets.percentile(allFrames, 0.99), peak - before))
                // A fling, as the owner reported (2026-09-30: 100–167% CPU and lag): top to bottom
                // and back at 1,500 points a frame, paced at 120 Hz, then a second to settle. The
                // CPU is the whole process's, background work included, over all of it.
                let flingStart = Budgets.cpuSeconds(), flingWall = CACurrentMediaTime()
                var flingFrames: [Double] = []
                for direction in [1.0, -1.0] {
                    var position: CGFloat = direction > 0 ? 0 : end
                    while direction > 0 ? position < end : position > 0 {
                        position += CGFloat(1500 * direction)
                        autoreleasepool {
                            let start = CACurrentMediaTime()
                            var waited = 0.0
                            for editor in viewer.editors { editor.scrollY = max(0, position); editor.render(); waited += editor.drawableWaitMilliseconds.last ?? 0 }
                            flingFrames.append((CACurrentMediaTime() - start) * 1000 - waited)
                            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 120))
                        }
                    }
                }
                Budgets.settle(1)
                let flingSeconds = CACurrentMediaTime() - flingWall
                flingCPU = (Budgets.cpuSeconds() - flingStart) / flingSeconds * 100
                flingDetail = String(format: "%d frames in %.1f s, then a second settling; frame p99 %.2f ms", flingFrames.count, flingSeconds, Budgets.percentile(flingFrames, 0.99))
            }
            let p99 = Budgets.percentile(frames, 0.99)
            // The window-sized drawing buffers are the window's cost, not the change set's.
            let drawables = Double(viewer.editors.map(\.drawableMemoryBytes).reduce(0, +)) / 1_048_576
            let memory = peak - before - drawables
            worst = (max(worst.open, open), max(worst.memory, memory), max(worst.scroll, p99))
            details.append(String(format: "%@: open %.0f ms, +%.0f MB and %.0f MB of drawables, scroll p99 %.2f ms", "\(layout)", open, memory, drawables, p99))
            window.contentView = nil
            window.close()
            Budgets.settle(0.3)
        }
        let detail = "\(fileCount) files; " + details.joined(separator: "; ")
        Budgets.check("review.open", worst.open, detail: detail)
        Budgets.check("review.memory", worst.memory, detail: detail)
        Budgets.check("review.scroll", worst.scroll, detail: detail)
        Budgets.check("review.fling.cpu", flingCPU, detail: flingDetail)
    }
}
