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

    func testABigChangeSet() throws {
        try Budgets.skipUnlessEnabled()
        let env = ProcessInfo.processInfo.environment
        let diff = try env["SIDE_REVIEW_DIFF"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? Self.generatedDiff()
        let fileCount = UnifiedDiff.parse(diff).files.count
        var worst: (open: Double, memory: Double, scroll: Double) = (0, 0, 0)
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
    }
}
