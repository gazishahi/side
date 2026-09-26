import AlloyAppKit
import XCTest
@testable import Side

/// SIDE_RFC_IDE_ESSENTIALS.md, step 9: what the language features cost Side itself, apart from
/// the server. Limits in `Budgets.table`.
@MainActor
final class IDEBudgetTests: XCTestCase {
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        try Budgets.skipUnlessEnabled()
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
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private func diagnostic(_ line: Int, _ message: String, _ severity: LSPDiagnosticSeverity) -> LSPDiagnostic {
        LSPDiagnostic(range: LSPRange(start: LSPPosition(line: line, character: 4), end: LSPPosition(line: line, character: 12)),
                      severity: severity, message: message, source: "ts")
    }

    /// What tsserver says about `useState`, the size of a real hover.
    private static let hoverMarkdown = """
    ```typescript
    (alias) function useState<S>(initialState: S | (() => S)): [S, React.Dispatch<React.SetStateAction<S>>] (+1 overload)
    import useState
    ```
    Returns a stateful value, and a function to update it.

    """ + String(repeating: "The initial state is used only during the first render; later renders ignore it, and a function passed as the initial state is called once. See **useReducer** for state with more than one sub-value, and `useSyncExternalStore` for state that lives outside React. ", count: 12) + """

    *@version* — 16.8.0

    *@see* — [https://react.dev/reference/react/useState](https://react.dev/reference/react/useState)
    """

    func testHoverAndSignatureCardsAreCheap() throws {
        let card = InfoCard()
        let anchor = NSRect(x: 400, y: 400, width: 60, height: 16)
        let problems = [diagnostic(0, "Cannot find name 'x'.", .error), diagnostic(0, "'y' is declared but never used.", .warning)]
        var hover: [Double] = []
        for _ in 0..<40 {
            hover.append(milliseconds {
                card.show(MakeWorkspaceViewController.hoverContent(problems: problems, markdown: Self.hoverMarkdown), near: anchor, in: window)
            })
            card.hide()
        }
        // The first show makes the panel and its glass, once a session: reported, not budgeted.
        let warmHover = Array(hover.dropFirst())
        Budgets.check("hover.show", percentile(warmHover, 0.99), detail: String(format: "p50 %.2f ms; the session's first %.1f ms", percentile(warmHover, 0.5), hover[0]))

        let help = LSPSignatureHelp(signatures: [
            .init(label: "setTimeout(handler: TimerHandler, timeout?: number, ...arguments: any[]): number", documentation: "Schedules a timer.",
                  parameters: [.init(range: 11..<32, documentation: nil), .init(range: 34..<50, documentation: "The delay in **ms**.")], activeParameter: nil),
            .init(label: "setTimeout(callback: (args: void) => void, ms?: number): NodeJS.Timeout", documentation: nil, parameters: [], activeParameter: nil),
        ], activeSignature: 0, activeParameter: 1)
        var signature: [Double] = []
        for _ in 0..<40 {
            signature.append(milliseconds { card.show(MakeWorkspaceViewController.render(help), near: anchor, in: window) })
            card.hide()
        }
        Budgets.check("signature.show", percentile(signature, 0.99), detail: String(format: "p50 %.2f ms (the card already made)", percentile(signature, 0.5)))
    }

    func testShowProblemsWithFiveThousand() throws {
        let root = URL(fileURLWithPath: "/tmp/side-problems-budget")
        for file in 0..<250 {
            let diagnostics = (0..<20).map { diagnostic($0 * 3, "Property 'value\($0)' does not exist on type 'Props\(file)'.", $0 % 4 == 0 ? .error : .warning) }
            make.recordProblemsForTesting(diagnostics, for: root.appendingPathComponent("src/module\(file / 25)/file\(file).ts"))
        }
        var times: [Double] = []
        for _ in 0..<5 {
            times.append(milliseconds { make.presentPalette(.problems) })
            XCTAssertEqual(make.problemRowCountForTesting, 5000)
            make.dismissPaletteForTesting()
        }
        Budgets.check("problems.open", times.max()!, detail: String(format: "five opens, fastest %.1f ms", times.min()!))
    }
}
