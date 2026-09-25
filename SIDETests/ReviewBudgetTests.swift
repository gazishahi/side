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
            let scroll = NSScrollView(frame: window.contentRect(forFrameRect: window.frame))
            let viewer = DiffViewer()
            viewer.layout = layout
            scroll.documentView = viewer
            viewer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            window.contentView = scroll
            window.orderFront(nil)
            let before = footprintMB()
            let start = CACurrentMediaTime()
            viewer.render(diffText: diff)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let ms = (CACurrentMediaTime() - start) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            print(String(format: "BUDGET review %@: %d files, render %.0f ms, +%.0f MB", "\(layout)", UnifiedDiff.parse(diff).files.count, ms, footprintMB() - before))
            window.close()
        }
    }
}
