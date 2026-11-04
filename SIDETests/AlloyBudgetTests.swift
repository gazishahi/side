import AlloyAppKit
import AlloyCore
import AlloyRender
import XCTest
@testable import Side
@testable import SideAgents

/// SIDE_RFC_ALLOY.md's performance budgets, measured in Make itself. The limits are in
/// `Budgets.table`; `scripts/budgets.sh` runs these with the rest, optimized.
@MainActor
final class AlloyBudgetTests: XCTestCase {
    private var root: URL!
    private var make: MakeWorkspaceViewController!
    private var window: NSWindow!
    private var alloy: AlloyEditorEngine { make.editor as! AlloyEditorEngine }
    private var view: AlloyEditorView { alloy.view }

    override func setUpWithError() throws {
        try Budgets.skipUnlessEnabled()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("budgets-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        make = MakeWorkspaceViewController()
        make.loadViewIfNeeded()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // As the shell hosts it: Make's view, and its tab strip in the window's top row.
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let tabs = try XCTUnwrap(make.topRowContent)
        for child in [make.view, tabs] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor), tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 30),
            make.view.topAnchor.constraint(equalTo: container.topAnchor), make.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            make.view.leadingAnchor.constraint(equalTo: container.leadingAnchor), make.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    /// XCTest keeps every test's instance until the suite ends: let go of the window and Make,
    /// or each finished test's editor keeps its display link ticking under the next one's numbers.
    override func tearDownWithError() throws {
        window?.contentView = nil
        window?.close()
        window = nil
        make = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Files

    /// 100,000 lines of real Swift: Alloy's own editor view, repeated.
    private func swiftFile() throws -> URL {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packages/Alloy/Sources/AlloyAppKit/AlloyEditorView.swift"), encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        out.reserveCapacity(100_000)
        while out.count < 100_000 { out.append(contentsOf: lines.prefix(100_000 - out.count)) }
        let url = root.appendingPathComponent("Big.swift")
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func logFile() throws -> URL {
        let line = "2026-09-24T12:00:00.000Z INFO  request id=abc123 path=/api/v1/items status=200 took=12ms user=42\n"
        let url = root.appendingPathComponent("server.log")
        try String(repeating: line, count: 20_000_000 / line.utf8.count).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Measuring

    private func now() -> Double { CACurrentMediaTime() * 1000 }

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Open to first paint: from asking Make to open the file until Alloy has drawn it.
    private func open(_ url: URL) -> Double {
        let length = ((try? String(contentsOf: url, encoding: .utf8)) as NSString?)?.length ?? 0
        let framesBefore = view.framesDrawn
        let start = now()
        make.revealFile(url, line: nil)
        waitUntil { make.editor.document?.length == length && view.framesDrawn > framesBefore }
        let elapsed = now() - start
        XCTAssertEqual(make.editor.document?.length, length, "opened \(url.lastPathComponent)")
        return elapsed
    }


    // MARK: Budgets

    /// Each file opened three times (as three files, so each open is a real one), once Side has
    /// settled after launch; the first open also builds its language's grammar, off the main
    /// thread, which the first paint doesn't wait for.
    func testOpenToFirstPaint() throws {
        let swift = try swiftFile(), log = try logFile()
        waitUntil(1) { false }
        var results: [String: [Double]] = [:]
        for (name, source) in [("100k-line Swift", swift), ("20 MB log", log)] {
            let text = try String(contentsOf: source, encoding: .utf8)
            for i in 0..<3 {
                let url = root.appendingPathComponent("\(i)-" + source.lastPathComponent)
                try ("// copy \(i)\n" + text).write(to: url, atomically: true, encoding: .utf8)
                results[name, default: []].append(open(url))
                waitUntil(0.3) { false }
            }
        }
        let swiftMS = results["100k-line Swift"]!, logMS = results["20 MB log"]!
        Budgets.check("editor.open.swift", swiftMS.max()!, detail: String(format: "three opens: %.0f, %.0f, %.0f ms", swiftMS[0], swiftMS[1], swiftMS[2]))
        Budgets.check("editor.open.log", logMS.max()!, detail: String(format: "three opens: %.0f, %.0f, %.0f ms", logMS[0], logMS[1], logMS[2]))
    }

    /// Typing at the display's rate: a key on every other frame, drawn by the editor's own
    /// display link, as a person's keys are. Main-thread time per key is the key's handling (Make's
    /// and Alloy's) plus the frame that shows it, less any wait for a free drawable (that's the GPU
    /// pacing us, not work).
    func testKeystrokeToPixels() throws {
        _ = open(try swiftFile())
        window.makeFirstResponder(view.textView)
        (alloy.document as? AlloyEditorDocument)?.highlighter?.waitForParse()
        var generator = SystemRandomNumberGenerator()
        let lines = view.buffer.text.lineCount
        var keyWork: [Double] = [], perKey: [Double] = [], frameWork: [Double] = []
        var frame = 0, keys = 0
        view.onFrame = { [weak self] _ in
            guard let self else { return }
            frame += 1
            if keys % 30 == 0, frame % 2 == 1 {
                // Somewhere new (lines to lay out and color), on a frame of its own.
                let offset = self.view.buffer.text.offset(ofLine: Int.random(in: 0..<lines - 50, using: &generator))
                self.view.setSelections([Selection(caret: offset)])
                self.make.editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
                keys += 1
                return
            }
            guard frame % 2 == 0, keys < 330 else { return }
            let start = CACurrentMediaTime()
            self.view.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            let typed = CACurrentMediaTime()
            // The frame this tick would draw anyway, drawn here so it can be timed with its key.
            self.view.render()
            let wait = self.view.drawableWaitMilliseconds.last ?? 0
            keyWork.append((typed - start) * 1000)
            perKey.append((CACurrentMediaTime() - start) * 1000 - wait)
            frameWork.append(self.view.lastFrameStats.cpuMilliseconds)
            keys += 1
        }
        view.resetFrameCounters()
        waitUntil(30) { keys >= 330 }
        waitUntil(0.2) { false }
        view.onFrame = nil
        XCTAssertGreaterThan(keyWork.count, 250)
        Budgets.check("editor.keystroke", percentile(perKey, 0.99), detail: String(format: "p50 %.2f ms; the key %.2f, its frame %.2f ms at p99",
                                                                                    percentile(perKey, 0.5), percentile(keyWork, 0.99), percentile(frameWork, 0.99)))
    }

    /// Live Markdown: typing into a long document set as prose, in places all over it (lines to
    /// lay out in their fonts, rows to measure), each key timed to its frame.
    func testLiveMarkdownKeystrokeToPixels() throws {
        var blocks: [String] = []
        for i in 0..<2_000 {
            blocks.append(i % 5 == 0 ? "## Section \(i)" : "Some **bold** prose with *slanted* words, `code`, and a [link](https://example.com) in paragraph \(i), long enough to wrap across the column more than once on a normal window.")
            blocks.append("")
        }
        let url = root.appendingPathComponent("Long.md")
        try (blocks + Array(repeating: "Plain line.", count: 16_000)).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = open(url)
        defer { MakeWorkspaceViewController.preferences.removeObject(forKey: MakeWorkspaceViewController.liveMarkdownKey) }
        make.toggleLiveMarkdown(nil)
        XCTAssertTrue(alloy.isProse)
        window.makeFirstResponder(view.textView)
        (alloy.document as? AlloyEditorDocument)?.highlighter?.waitForParse()
        var generator = SystemRandomNumberGenerator()
        var perKey: [Double] = []
        var frame = 0, keys = 0
        view.onFrame = { [weak self] _ in
            guard let self else { return }
            frame += 1
            if keys % 30 == 0, frame % 2 == 1 {
                let offset = self.view.buffer.text.offset(ofLine: Int.random(in: 0..<3_900, using: &generator))
                self.view.setSelections([Selection(caret: offset)])
                self.make.editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
                keys += 1
                return
            }
            guard frame % 2 == 0, keys < 330 else { return }
            let start = CACurrentMediaTime()
            self.view.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            self.view.render()
            perKey.append((CACurrentMediaTime() - start) * 1000 - (self.view.drawableWaitMilliseconds.last ?? 0))
            keys += 1
        }
        waitUntil(40) { keys >= 330 }
        view.onFrame = nil
        XCTAssertGreaterThan(perKey.count, 250)
        Budgets.check("editor.live.keystroke", percentile(perKey, 0.99), detail: String(format: "p50 %.2f ms", percentile(perKey, 0.5)))
    }

    func testReHighlightAfterAnEdit() throws {
        _ = open(try swiftFile())
        let document = try XCTUnwrap(alloy.document as? AlloyEditorDocument)
        let highlighter = try XCTUnwrap(document.highlighter)
        highlighter.waitForParse()
        var line: [Double] = [], reparse: [Double] = []
        for i in 0..<20 {
            let target = 1_000 + i * 4_000
            view.setSelections([Selection(caret: view.buffer.text.offset(ofLine: target))])
            view.textView.insertText("let q = 1; ", replacementRange: NSRange(location: NSNotFound, length: 0))
            let start = now()
            _ = highlighter.spans(forLine: target)
            line.append(now() - start)
            let parseStart = now()
            highlighter.waitForParse()
            reparse.append(now() - parseStart)
        }
        Budgets.check("editor.recolor", percentile(line, 0.99), detail: String(format: "the reparse behind it, off the main thread: median %.0f ms", percentile(reparse, 0.5)))
    }

    /// Five seconds of steady scrolling, a new stretch of the file every frame, beside the same
    /// five seconds drawing nothing but the background: misses the control has too are the
    /// system's (other apps, the compositor), not the editor's.
    func testScrollingDropsNoFrames() throws {
        _ = open(try swiftFile())
        (alloy.document as? AlloyEditorDocument)?.highlighter?.waitForParse()
        // Settle first: what launch and opening start in the background (the test host's own
        // startup, git) shows up as misses that aren't scrolling's.
        waitUntil(3) { false }
        func scroll(controlOnly: Bool, seconds: TimeInterval) -> (presented: Int, missed: Int, cpu: [Double]) {
            TextRenderer.clearOnly = controlOnly
            defer { TextRenderer.clearOnly = false }
            view.onFrame = { [weak self] _ in self?.view.scrollY += 45 }
            waitUntil(0.3) { false }
            view.resetFrameCounters()
            waitUntil(seconds) { false }
            view.onFrame = nil
            waitUntil(0.2) { false }
            let (presented, missed) = view.presentedFrameCounts()
            return (presented, missed, view.frameMilliseconds)
        }
        // Interleaved, a round of each at a time, so both see the same load on the machine
        // (back to back, a burst of other work landed on one and read as the editor's).
        var control: (presented: Int, missed: Int, cpu: [Double]) = (0, 0, [])
        var real = control
        for _ in 0..<8 {
            let c = scroll(controlOnly: true, seconds: 1), r = scroll(controlOnly: false, seconds: 1)
            control = (control.presented + c.presented, control.missed + c.missed, control.cpu + c.cpu)
            real = (real.presented + r.presented, real.missed + r.missed, real.cpu + r.cpu)
        }
        let hz = Int((1 / view.displayInterval).rounded())
        XCTAssertGreaterThan(real.presented, 0)
        let frameMS = view.displayInterval * 1000
        Budgets.check("editor.scroll.cpu", percentile(real.cpu, 0.99) / frameMS * 100,
                      detail: String(format: "p99 %.2f ms of a %.1f ms frame (%d Hz), median %.2f ms", percentile(real.cpu, 0.99), frameMS, hz, percentile(real.cpu, 0.5)))
        let rate = { (p: Int, m: Int) in Double(m) / Double(max(1, p + m)) * 100 }
        Budgets.check("editor.scroll.missed", max(0, rate(real.presented, real.missed) - rate(control.presented, control.missed)),
                      detail: "8 rounds of a second each, interleaved: \(real.missed) of \(real.presented + real.missed) missed, drawing nothing \(control.missed) of \(control.presented + control.missed)")
    }

    /// A fling through a colored 100,000-line file, at the display's pace: 900 points a frame
    /// (about 50 lines), for four seconds, reversing at the ends. The whole process's CPU,
    /// background work included, not only the main thread's share of a frame (2026-09-30, the
    /// owner: why doesn't CPU get memory's treatment?).
    func testFlingCPU() throws {
        _ = open(try swiftFile())
        (alloy.document as? AlloyEditorDocument)?.highlighter?.waitForParse()
        waitUntil(2) { false }
        var direction: CGFloat = 1
        view.onFrame = { [weak self] _ in
            guard let self else { return }
            let bottom = self.view.documentLayout.contentHeight - self.view.bounds.height
            if self.view.scrollY >= bottom - 900 { direction = -1 }
            if self.view.scrollY <= 900 { direction = 1 }
            self.view.scrollY += 900 * direction
        }
        if ProcessInfo.processInfo.environment["SIDE_FLING_NO_PREPARE"] == "1" { view.prepareStyles = nil }
        waitUntil(0.3) { false }
        view.resetFrameCounters()
        let cpu = Budgets.cpuSeconds(), wall = CACurrentMediaTime()
        waitUntil(4) { false }
        view.onFrame = nil
        let seconds = CACurrentMediaTime() - wall, spent = Budgets.cpuSeconds() - cpu
        let (presented, missed) = view.presentedFrameCounts()
        let share = spent / seconds * 100
        // CPU alone rewards dropping frames: a slower editor draws fewer and spends less. So the
        // frames are reported with it, and the CPU per frame drawn.
        let detail = String(format: "4 s at %d Hz, 900 pt a frame: %d frames presented, %d missed; %.0f%% of a core; frame p99 %.2f ms",
                            Int((1 / view.displayInterval).rounded()), presented, missed, share, percentile(view.frameMilliseconds, 0.99))
        Budgets.check("editor.fling.cpu", spent * 1000 / Double(max(1, presented)), detail: detail)
        Budgets.check("editor.fling.missed", Double(missed) / Double(max(1, presented + missed)) * 100, detail: detail)
    }

    /// A real file scrolled at trackpad speed, inside its own project (language server and
    /// all): SIDE_SCROLL_FILE names it, SIDE_SCROLL_ROOT its project. Skipped without them.
    func testScrollingARealFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SIDE_SCROLL_FILE"] else { throw XCTSkip("set SIDE_SCROLL_FILE") }
        // SIDE_SCROLL_WINDOW=WIDTHxHEIGHT, in points: a full-screen window has several times the text.
        if let size = env["SIDE_SCROLL_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            window.layoutIfNeeded()
        }
        if let projectRoot = env["SIDE_SCROLL_ROOT"] { make.loadProject(at: URL(fileURLWithPath: projectRoot)) }
        // SIDE_SCROLL_MINIMAP=1: with the minimap shown, as people have it (the tests' own
        // preferences start with it off).
        if env["SIDE_SCROLL_MINIMAP"] == "1", view.minimap.isHiddenOrHasHiddenAncestor { make.toggleMinimap(nil) }
        _ = open(URL(fileURLWithPath: path))
        (alloy.document as? AlloyEditorDocument)?.highlighter?.waitForParse()
        waitUntil(Double(env["SIDE_SCROLL_SETTLE"] ?? "10") ?? 10) { false }
        let step = CGFloat(Double(env["SIDE_SCROLL_STEP"] ?? "30") ?? 30)
        var direction: CGFloat = 1
        // SIDE_SCROLL_WHEEL=N: N trackpad scroll events a frame through the scroll view, as a
        // person's scrolling arrives, instead of setting the position.
        let wheel = Int(env["SIDE_SCROLL_WHEEL"] ?? "0") ?? 0
        view.onFrame = { [weak self] _ in
            guard let self else { return }
            let bottom = self.view.documentLayout.contentHeight - self.view.bounds.height
            if self.view.scrollY >= bottom - step { direction = -1 }
            if self.view.scrollY <= step { direction = 1 }
            guard wheel > 0 else { self.view.scrollY += step * direction; return }
            for _ in 0..<wheel {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-step * direction / CGFloat(wheel)), wheel2: 0, wheel3: 0) else { continue }
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                // Global display coordinates are top-down; the window's screen point isn't.
                let onScreen = self.window.convertPoint(toScreen: NSPoint(x: 400, y: 400))
                event.location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
                if let ns = NSEvent(cgEvent: event) { self.window.sendEvent(ns) }
            }
        }
        waitUntil(0.3) { false }
        view.resetFrameCounters()
        let cpu = Budgets.cpuSeconds(), wall = CACurrentMediaTime()
        // For a profiler: the process to sample, now that the scrolling has started.
        try? "\(getpid())".write(toFile: (env["SIDE_SCROLL_OUT"] ?? "/tmp/side-scroll.txt") + ".pid", atomically: true, encoding: .utf8)
        waitUntil(Double(env["SIDE_SCROLL_SECONDS"] ?? "4") ?? 4) { false }
        view.onFrame = nil
        let seconds = CACurrentMediaTime() - wall, spent = Budgets.cpuSeconds() - cpu
        let (presented, missed) = view.presentedFrameCounts()
        let line = String(format: "SCROLL %@: %.0f s at %d Hz, %.0f pt a frame: %d presented, %d missed; %.0f%% of a core; %.2f ms CPU a frame; p50 %.2f p99 %.2f ms; footprint %.0f MB",
                          (path as NSString).lastPathComponent, seconds, Int((1 / view.displayInterval).rounded()), step, presented, missed, spent / seconds * 100,
                          spent * 1000 / Double(max(1, presented)), percentile(view.frameMilliseconds, 0.5), percentile(view.frameMilliseconds, 0.99), footprintMB())
        print(line); fflush(stdout)
        try line.write(toFile: (env["SIDE_SCROLL_OUT"] ?? "/tmp/side-scroll.txt"), atomically: true, encoding: .utf8)
        // A picture of the gutter partway down, to check what it draws.
        if let snapshot = env["SIDE_SCROLL_SNAPSHOT"] {
            view.scrollY = 1003
            waitUntil(0.5) { false }
            let scale = window.backingScaleFactor
            for (part, path) in [(view.gutter as NSView, snapshot), (view.minimap as NSView, snapshot + ".minimap.png")] where part.bounds.width > 0 {
                part.layer?.sublayers?.forEach { $0.displayIfNeeded() }
                let size = CGSize(width: part.bounds.width * scale, height: part.bounds.height * scale)
                guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.scaleBy(x: scale, y: scale)
                if part.layer?.isGeometryFlipped == true || part.isFlipped { context.translateBy(x: 0, y: part.bounds.height); context.scaleBy(x: 1, y: -1) }
                part.layer?.render(in: context)
                if let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
            let firstLine = view.documentLayout.line(atY: view.scrollY).line + 1
            try "first visible line \(firstLine), scrollY \(view.scrollY), minimap shown \(!view.minimap.isHiddenOrHasHiddenAncestor) \(view.minimap.bounds.size)".write(toFile: snapshot + ".txt", atomically: true, encoding: .utf8)
        }
    }

    func testMemory() throws {
        let log = try logFile()
        let size = Double((try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0) / 1_048_576
        // The window's drawables and the glyph atlas come with the first frame, whatever the
        // file: open a small one first so the difference is the file's.
        let small = root.appendingPathComponent("small.log")
        try String(repeating: "2026-09-24T12:00:00.000Z INFO  warm up\n", count: 200).write(to: small, atomically: true, encoding: .utf8)
        let empty = footprintMB()
        _ = open(small)
        waitUntil(1) { false }
        let before = footprintMB()
        _ = open(log)
        waitUntil(1) { false }
        let after = footprintMB()
        Budgets.check("editor.memory.log", after - before, detail: String(format: "%.1fx the file; the window's first frame (drawables, atlas) +%.0f MB, once", (after - before) / size, before - empty),
                      limit: size * 3 + 32)
    }

    /// Folding and the minimap in the 100k-line file: finding the regions (off the main thread
    /// in the app, timed here directly), folding everything, and the minimap's cost a frame.
    func testFoldingAndTheMinimap() throws {
        _ = open(try swiftFile())
        let start = now()
        let regions = Folding.ranges(in: view.buffer.text)
        let found = now() - start
        Budgets.check("editor.foldRegions", found, detail: "\(regions.count) regions")
        // The editor finds its own, off the main thread, a moment after opening.
        Budgets.settle(10) { !view.foldRegions.isEmpty }
        XCTAssertEqual(view.foldRegions.count, regions.count)
        let foldStart = now()
        view.foldAll(nil)
        view.render()
        let folded = now() - foldStart - (view.drawableWaitMilliseconds.last ?? 0)
        view.unfoldAll()
        Budgets.check("editor.foldAll", folded, detail: "\(view.documentLayout.lineCount) lines, drawn after")

        make.toggleMinimap(nil)
        defer { make.toggleMinimap(nil) }
        window.layoutIfNeeded()
        let minimap = view.minimap
        XCTAssertGreaterThan(minimap.bounds.width, 0, "shown")
        var draws: [Double] = []
        for step in 0..<200 {
            view.scrollY = CGFloat(step) * 900
            let drawStart = now()
            minimap.display()
            draws.append(now() - drawStart)
        }
        Budgets.check("editor.minimap", percentile(draws, 0.99), detail: String(format: "median %.2f ms", percentile(draws, 0.5)))
    }

    /// An agent's approved edit reaches the open tab as a whole-file replacement
    /// (`applyApprovedEdit`); 60 a second, each drawn.
    func testAgentEdits() throws {
        for (name, lines) in [("a 2,000-line file", 2_000), ("the 100k-line file", 100_000)] {
            let url = root.appendingPathComponent("Edit\(lines).swift")
            var text = try String(contentsOf: try swiftFile(), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = open(url)
            var times: [Double] = []
            for i in 0..<60 {
                text = "// edit \(i)\n" + text
                let start = now()
                _ = make.applyApprovedEdit(url: url, newContent: text)
                view.render()
                // Less any wait for a free drawable: sixty frames back to back outrun the display.
                times.append(now() - start - (view.drawableWaitMilliseconds.last ?? 0))
                RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            }
            let total = times.reduce(0, +)
            Budgets.check("editor.agentEdits", percentile(times, 0.99), detail: String(format: "%@: %.1f ms each on average", name, total / 60))
        }
    }
}
