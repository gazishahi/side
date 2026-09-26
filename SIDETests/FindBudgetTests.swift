import AlloyAppKit
import XCTest
@testable import Side

/// Find in a 100,000-line file: every match, and stepping to the next. Limits in `Budgets.table`.
@MainActor
final class FindBudgetTests: XCTestCase {
    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        try Budgets.skipUnlessEnabled()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("findbudget-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let tabs = try XCTUnwrap(make.topRowContent)
        for child in [make.view, tabs, make.paletteSurface!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor), tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor), make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            make.paletteSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
            make.paletteSurface.centerXAnchor.constraint(equalTo: container.centerXAnchor), make.paletteSurface.widthAnchor.constraint(equalToConstant: 640),
            make.paletteSurface.heightAnchor.constraint(equalToConstant: 300),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDownWithError() throws {
        window?.contentView = nil
        window?.close()
        window = nil
        make = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 100,000 lines of real Swift: Alloy's editor view, repeated.
    private func bigFile() throws -> (URL, String) {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/Alloy/Sources/AlloyAppKit/AlloyEditorView.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        while out.count < 100_000 { out.append(contentsOf: lines.prefix(100_000 - out.count)) }
        let text = out.joined(separator: "\n")
        let url = root.appendingPathComponent("Big.swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, text)
    }

    func testFindInABigFile() throws {
        let (url, text) = try bigFile()
        make.revealFile(url, line: nil)
        Budgets.settle(20) { make.editor.document?.length == (text as NSString).length }
        let document = try XCTUnwrap(make.editor.document)
        // Matching, as the palette does it: over the document's text (a view of the rope).
        var worst = 0.0
        var details: [String] = []
        for (query, options) in [("setNeedsRender", InFileFind.Options()), ("self", InFileFind.Options()),
                                 ("func \\w+\\(", InFileFind.Options(regularExpression: true)), ("Scroll", InFileFind.Options(caseSensitive: true, wholeWord: true))] {
            let find = InFileFind(query: query, options: options)
            let start = CACurrentMediaTime()
            let result = find.matches(in: document.text)
            let ms = (CACurrentMediaTime() - start) * 1000
            worst = max(worst, ms)
            details.append(String(format: "“%@” %d%@ in %.0f ms", query, result.ranges.count, result.truncated ? "+" : "", ms))
        }
        Budgets.check("find.matches", worst, detail: details.joined(separator: ", "))

        // Stepping with the palette open: select, scroll there, and the frame that shows it.
        make.presentFind(replace: false)
        make.searchField.stringValue = "setNeedsRender"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: make.searchField)
        Budgets.settle(0.5)
        let view = (make.editor as! AlloyEditorEngine).view
        var steps: [Double] = [], stepOnly: [Double] = []
        for _ in 0..<300 {
            autoreleasepool {
                let start = CACurrentMediaTime()
                make.findNext(forward: true)
                stepOnly.append((CACurrentMediaTime() - start) * 1000)
                view.render()
                steps.append((CACurrentMediaTime() - start) * 1000 - (view.drawableWaitMilliseconds.last ?? 0))
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
            }
        }
        Budgets.check("find.next", Budgets.percentile(steps, 0.99), detail: String(format: "median %.2f ms over 300 steps; the step without its frame p99 %.2f ms", Budgets.percentile(steps, 0.5), Budgets.percentile(stepOnly, 0.99)))
    }
}
