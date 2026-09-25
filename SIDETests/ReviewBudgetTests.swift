import XCTest
@testable import Side

/// Review with a big change set: how long rendering the diff takes, and what it costs in memory.
/// Opt-in like `AlloyBudgetTests` (`SIDE_BUDGETS=1`, optimized); `SIDE_REVIEW_DIFF` names a
/// `git diff` output to render.
@MainActor
final class ReviewBudgetTests: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func testRenderingABigDiff() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SIDE_BUDGETS"] == "1", "set SIDE_BUDGETS=1 to measure")
        let diff = try String(contentsOfFile: try XCTUnwrap(env["SIDE_REVIEW_DIFF"]), encoding: .utf8)
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
            let before = footprintMB()
            var ms = 0.0
            autoreleasepool {
                let start = CACurrentMediaTime()
                viewer.render(diffText: diff)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                ms = (CACurrentMediaTime() - start) * 1000
            }
            for _ in 0..<20 { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) } }
            let opened = footprintMB() - before
            // Top to bottom, a screen at a time.
            var frames: [Double] = []
            if layout == .unified, ProcessInfo.processInfo.environment["SIDE_PROFILE_WAIT"] == "1" {
                print("PROFILEWAIT pid \(getpid())"); fflush(stdout)
                RunLoop.main.run(until: Date().addingTimeInterval(8))
            }
            if let editor = viewer.editors.first {
                let step = editor.viewport.height
                var y: CGFloat = 0
                let end = editor.documentLayout.contentHeight
                while y < end {
                    y += step
                    // Each step in its own pool, as each event is in the app.
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        var waited = 0.0
                        for other in viewer.editors { other.scrollY = y; other.render(); waited += other.drawableWaitMilliseconds.last ?? 0 }
                        // Less the wait for a free drawable: this loop outruns the display.
                        frames.append((CACurrentMediaTime() - start) * 1000 - waited)
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
                    }
                }
            }
            // And as a person scrolls: 45 points a frame from the top, for 600 frames.
            var smooth: [Double] = []
            if let editor = viewer.editors.first {
                for other in viewer.editors { other.scrollY = 0 }
                var y: CGFloat = 0
                for _ in 0..<600 {
                    y += 45
                    autoreleasepool {
                        let start = CACurrentMediaTime()
                        var waited = 0.0
                        for other in viewer.editors { other.scrollY = y; other.render(); waited += other.drawableWaitMilliseconds.last ?? 0 }
                        smooth.append((CACurrentMediaTime() - start) * 1000 - waited)
                        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
                    }
                }
                _ = editor
            }
            let smoothSorted = smooth.sorted()
            if !smoothSorted.isEmpty {
                print(String(format: "SMOOTH %@: p50 %.2f, p99 %.2f ms; %d of %d over 8.3 ms", "\(layout)", smoothSorted[smoothSorted.count / 2], smoothSorted[Int(Double(smoothSorted.count) * 0.99)], smooth.filter { $0 > 8.3 }.count, smooth.count))
            }
            let worst = frames.max() ?? 0
            let sorted = frames.sorted()
            let pick = { (p: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            print(String(format: "FRAMES %@: p50 %.1f, p95 %.1f, p99 %.1f ms; %d over 16 ms", "\(layout)", pick(0.5), pick(0.95), pick(0.99), frames.filter { $0 > 16 }.count))
            let categories = Process()
            categories.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            categories.arguments = ["\(getpid())"]
            let pipe = Pipe(); categories.standardOutput = pipe
            try? categories.run(); categories.waitUntilExit()
            let lines = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n").dropFirst(4).prefix(6)
            print("CATEGORIES \(layout)\n" + lines.joined(separator: "\n"))
            if layout == .unified, ProcessInfo.processInfo.environment["SIDE_HEAP_WAIT"] == "1" {
                print("HEAPWAIT pid \(getpid())"); fflush(stdout)
                RunLoop.main.run(until: Date().addingTimeInterval(90))
            }
            print(String(format: "BUDGET review %@: %d files, %d rows, open %.0f ms, +%.0f MB; scrolled %d screens, slowest %.1f ms, peak +%.0f MB",
                         "\(layout)", UnifiedDiff.parse(diff).files.count, viewer.rowCount, ms, opened, frames.count, worst, footprintMB() - before))
            window.close()
        }
    }
}
