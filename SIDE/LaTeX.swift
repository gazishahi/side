import AppKit
import Heron
import PDFKit

/// Building a LaTeX document: which file is the document, latexmk to build it, its log read for
/// problems, and SyncTeX between the source and the PDF. Pure parts here; `LaTeXSession` runs them.
enum LaTeX {
    /// The sources Build and Show in PDF act on.
    static let sourceExtensions: Set<String> = ["tex", "ltx"]

    /// The document a source belongs to: a `% !TEX root = main.tex` comment in its first lines,
    /// the file itself when it has a `\documentclass`, or the one file beside it that has one.
    static func rootDocument(for file: URL, text: String?) -> URL {
        let text = text ?? (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let root = magic("root", in: text) { return resolve(root, in: file.deletingLastPathComponent()) }
        if declaresDocument(text) { return file }
        // Named from the source's own folder, so a document has one URL however it's reached.
        let folder = file.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { folder.appendingPathComponent($0) }
            .filter { sourceExtensions.contains($0.pathExtension.lowercased()) && $0.lastPathComponent != file.lastPathComponent }
            .filter { declaresDocument((try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
        return siblings.count == 1 ? siblings[0] : file
    }

    /// A path as TeX or a comment names it: absolute, or from the folder it was named in.
    /// (`URL(fileURLWithPath:relativeTo:)` takes a folder without a final slash for a file and
    /// resolves from its parent.)
    static func resolve(_ path: String, in folder: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)).standardizedFileURL
    }

    /// A `% !TEX key = value` comment among the first 20 lines.
    static func magic(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("%") else { continue }
            let body = trimmed.drop { $0 == "%" || $0 == " " }
            guard body.lowercased().hasPrefix("!tex") else { continue }
            let rest = body.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == key.lowercased(), !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    static func declaresDocument(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.prefix { $0 != "%" }
            return code.contains("\\documentclass")
        }
    }

    // MARK: Tools

    struct Tools: Equatable {
        var latexmk: URL
        var synctex: URL?
    }

    /// Where TeX lives: the PATH Side's processes get, then MacTeX's and Homebrew's folders.
    static func tools(environment: [String: String]) -> Tools? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin"]
        func find(_ name: String) -> URL? {
            folders.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        guard let latexmk = find("latexmk") else { return nil }
        return Tools(latexmk: latexmk, synctex: find("synctex"))
    }

    /// latexmk's arguments: a PDF with SyncTeX, never stopping to ask, errors as file:line, and
    /// the engine a `% !TEX program` comment names.
    static func arguments(root: URL, text: String?) -> [String] {
        let engine: String
        switch magic("program", in: text ?? "")?.lowercased() {
        case "xelatex"?: engine = "-xelatex"
        case "lualatex"?: engine = "-lualatex"
        default: engine = "-pdf"
        }
        return [engine, "-synctex=1", "-interaction=nonstopmode", "-file-line-error", root.lastPathComponent]
    }

    /// TeX wraps its log at 79 columns, which splits messages; these keep each on one line.
    static let unwrappedLog = ["max_print_line": "100000", "error_line": "254", "half_error_line": "238"]

    // MARK: The log

    struct Problem: Equatable {
        var file: URL
        var line: Int
        var message: String
        var isError: Bool
    }

    /// Errors as `file:line: message` (latexmk runs TeX with -file-line-error), and the
    /// warnings that name an input line (undefined references and citations), which belong to
    /// the document. Box warnings are left out: they're layout, not mistakes.
    static func problems(in log: String, directory: URL, root: URL) -> [Problem] {
        var found: [Problem] = []
        var seen = Set<String>()
        func add(_ problem: Problem) {
            let key = "\(problem.file.path):\(problem.line):\(problem.message)"
            if seen.insert(key).inserted { found.append(problem) }
        }
        let error = try! NSRegularExpression(pattern: #"^(.+?\.(?:tex|ltx|sty|cls|bib|bbl|aux)):(\d+): (.+)$"#)
        let warning = try! NSRegularExpression(pattern: #"^(?:LaTeX|Package \S+|Class \S+) Warning: (.+?) on input line (\d+)\.?$"#)
        for line in log.split(separator: "\n").map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = error.firstMatch(in: line, range: range) {
                let path = (line as NSString).substring(with: match.range(at: 1))
                let number = Int((line as NSString).substring(with: match.range(at: 2))) ?? 1
                let file = resolve(path, in: directory)
                add(Problem(file: file, line: number, message: (line as NSString).substring(with: match.range(at: 3)), isError: true))
            } else if let match = warning.firstMatch(in: line, range: range) {
                let number = Int((line as NSString).substring(with: match.range(at: 2))) ?? 1
                add(Problem(file: root, line: number, message: (line as NSString).substring(with: match.range(at: 1)), isError: false))
            }
        }
        return found
    }

    /// Where the PDF went: what TeX says it wrote, or beside the document.
    static func outputPDF(in log: String, directory: URL, root: URL) -> URL {
        let written = try! NSRegularExpression(pattern: #"Output written on (.+?\.pdf) \("#)
        let matches = written.matches(in: log, range: NSRange(log.startIndex..., in: log))
        if let last = matches.last {
            return resolve((log as NSString).substring(with: last.range(at: 1)), in: directory)
        }
        return root.deletingPathExtension().appendingPathExtension("pdf")
    }

    // MARK: SyncTeX

    /// Where a source line is in the PDF: its page (from 1) and the box around it, in PDF
    /// coordinates (origin at the page's bottom left), from `synctex view`.
    static func forwardResult(_ output: String, pageHeight: (Int) -> CGFloat) -> (page: Int, box: CGRect)? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            if values[key] == nil { values[key] = String(line[line.index(after: colon)...]) }
            if key == "H", values["Page"] != nil { break }  // the first record is enough
        }
        guard let page = values["Page"].flatMap(Int.init), let h = values["h"].flatMap(Double.init), let v = values["v"].flatMap(Double.init) else { return nil }
        let width = values["W"].flatMap(Double.init) ?? 0, height = values["H"].flatMap(Double.init) ?? 0
        let top = pageHeight(page) - CGFloat(v)
        return (page, CGRect(x: h, y: Double(top), width: max(width, 20), height: max(height, 10)))
    }

    /// Which source line a point in the PDF came from, from `synctex edit`.
    static func inverseResult(_ output: String) -> (file: URL, line: Int)? {
        var input: String?, line: Int?
        for row in output.split(separator: "\n") {
            if row.hasPrefix("Input:"), input == nil { input = String(row.dropFirst("Input:".count)) }
            if row.hasPrefix("Line:"), line == nil { line = Int(row.dropFirst("Line:".count)) }
        }
        guard let input, let line, line > 0 else { return nil }
        return (URL(fileURLWithPath: input).standardizedFileURL, line)
    }

    /// Runs a tool and returns what it printed (both streams), off the main thread.
    nonisolated static func run(_ tool: URL, _ arguments: [String], in directory: URL, environment: [String: String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - A session: building, the preview, and the way between them

/// Make's LaTeX: Build runs latexmk for the document a source belongs to and shows the PDF in a
/// window beside the editor, which refreshes on every build (and every save, once it's open);
/// problems go to Make's list; Show in PDF and ⌘-clicking the PDF go between source and output.
@MainActor
final class LaTeXSession {
    /// Make's part: save the sources about to be built, then go on.
    var saveSources: (@escaping () -> Void) -> Void = { $0() }
    /// The build's problems, by file (an empty list clears a file's).
    var reportProblems: ([URL: [LSPDiagnostic]]) -> Void = { _ in }
    /// Opens a source at a line (from one), from a ⌘-click in the PDF.
    var revealSource: (URL, Int) -> Void = { _, _ in }
    var projectRoot: () -> URL? = { nil }
    var window: () -> NSWindow? = { nil }
    /// The environment tools run in (tests swap in stand-in tools).
    var environment: () -> [String: String] = { SpawnEnvironment.current() }

    private(set) var previews: [URL: LaTeXPreviewController] = [:]
    private var building: Set<URL> = []
    private var buildAgain: Set<URL> = []
    private var reported: Set<URL> = []
    /// Told when a build ends (tests).
    var onBuildFinished: ((URL, Bool) -> Void)?

    static func isSource(_ url: URL) -> Bool { LaTeX.sourceExtensions.contains(url.pathExtension.lowercased()) }

    func preview(forRoot root: URL) -> LaTeXPreviewController? { previews[root.standardizedFileURL] }

    /// Build: the document this source belongs to.
    func build(source: URL, text: String?) {
        let root = LaTeX.rootDocument(for: source, text: text).standardizedFileURL
        guard mayBuild(root) else { return }
        guard let tools = LaTeX.tools(environment: environment()) else {
            alert("Building LaTeX needs TeX", "Side builds with latexmk, which comes with a TeX distribution. Install MacTeX from tug.org/mactex, or with Homebrew: brew install --cask mactex-no-gui. Then build again.")
            return
        }
        let preview = previews[root] ?? openPreview(for: root)
        preview.showWindow(nil)
        guard !building.contains(root) else { buildAgain.insert(root); return }
        building.insert(root)
        preview.status = .building
        saveSources { [weak self] in self?.runBuild(root: root, tools: tools) }
    }

    /// A save: with the document's preview open, build again.
    func sourceSaved(_ url: URL, text: String?) {
        guard Self.isSource(url) || ["bib", "sty", "cls"].contains(url.pathExtension.lowercased()) else { return }
        let root = Self.isSource(url) ? LaTeX.rootDocument(for: url, text: text).standardizedFileURL : nil
        let open = root.flatMap { previews[$0] } ?? previews.values.first { $0.root.deletingLastPathComponent().path == url.deletingLastPathComponent().path }
        guard let preview = open, preview.window?.isVisible == true else { return }
        build(source: preview.root, text: nil)
    }

    /// Show in PDF: the place in the PDF this line made.
    func showInPDF(source: URL, text: String?, line: Int, column: Int) {
        let root = LaTeX.rootDocument(for: source, text: text).standardizedFileURL
        guard let preview = previews[root], let document = preview.pdfView.document,
              let synctex = LaTeX.tools(environment: environment())?.synctex else {
            build(source: source, text: text)
            return
        }
        preview.showWindow(nil)
        let pdf = preview.pdfURL
        let environment = environment()
        let heights = (0..<document.pageCount).map { document.page(at: $0)?.bounds(for: .mediaBox).height ?? 792 }
        Task.detached {
            let result = LaTeX.run(synctex, ["view", "-i", "\(line):\(max(0, column)):\(source.path)", "-o", pdf.path], in: pdf.deletingLastPathComponent(), environment: environment)
            let place = LaTeX.forwardResult(result.output) { page in heights.indices.contains(page - 1) ? heights[page - 1] : 792 }
            await MainActor.run { if let place { preview.reveal(page: place.page - 1, box: place.box) } }
        }
    }

    private func mayBuild(_ root: URL) -> Bool {
        let folders = [projectRoot(), root.deletingLastPathComponent()].compactMap { $0 }
        guard let untrusted = folders.first(where: { ProjectTrust.hasLaTeXProjectCode($0) }) else { return true }
        let trustRoot = projectRoot() ?? untrusted
        if ProjectTrust.isTrusted(trustRoot) { return true }
        alert("Trust this project to build it", "It has a latexmkrc, a Perl script latexmk runs on every build. Trust the project (the banner above the editor) once you know what it does.")
        return false
    }

    private func openPreview(for root: URL) -> LaTeXPreviewController {
        let preview = LaTeXPreviewController(root: root)
        preview.onInverseSearch = { [weak self, weak preview] page, point in
            guard let self, let preview else { return }
            self.inverseSearch(preview: preview, page: page, point: point)
        }
        preview.placeBeside(window())
        previews[root] = preview
        return preview
    }

    private func inverseSearch(preview: LaTeXPreviewController, page: Int, point: CGPoint) {
        guard let synctex = LaTeX.tools(environment: environment())?.synctex else { return }
        let pdf = preview.pdfURL, environment = environment()
        Task.detached {
            let result = LaTeX.run(synctex, ["edit", "-o", "\(page + 1):\(point.x):\(point.y):\(pdf.path)"], in: pdf.deletingLastPathComponent(), environment: environment)
            let place = LaTeX.inverseResult(result.output)
            await MainActor.run { [weak self] in
                guard let self, let place else { return }
                self.revealSource(place.file, place.line)
                self.window()?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func runBuild(root: URL, tools: Tools) {
        let directory = root.deletingLastPathComponent()
        let arguments = LaTeX.arguments(root: root, text: try? String(contentsOf: root, encoding: .utf8))
        let environment = environment().merging(LaTeX.unwrappedLog) { _, new in new }
        Task.detached {
            let result = LaTeX.run(tools.latexmk, arguments, in: directory, environment: environment)
            let problems = LaTeX.problems(in: result.output, directory: directory, root: root)
            let pdf = LaTeX.outputPDF(in: result.output, directory: directory, root: root)
            await MainActor.run { [weak self] in self?.finish(root: root, status: result.status, log: result.output, problems: problems, pdf: pdf) }
        }
    }
    private typealias Tools = LaTeX.Tools

    private func finish(root: URL, status: Int32, log: String, problems: [LaTeX.Problem], pdf: URL) {
        building.remove(root)
        var byFile: [URL: [LSPDiagnostic]] = [:]
        for problem in problems {
            let position = LSPPosition(line: max(0, problem.line - 1), character: 0)
            byFile[problem.file, default: []].append(LSPDiagnostic(range: LSPRange(start: position, end: LSPPosition(line: position.line, character: 10_000)),
                                                                   severity: problem.isError ? .error : .warning, message: problem.message, source: "LaTeX"))
        }
        // Files the last build reported and this one didn't: cleared.
        for file in reported where byFile[file] == nil { byFile[file] = [] }
        reported = Set(byFile.filter { !$0.value.isEmpty }.keys)
        reportProblems(byFile)
        let errors = problems.filter(\.isError).count
        let preview = previews[root]
        preview?.pdfURL = pdf
        if FileManager.default.fileExists(atPath: pdf.path) { preview?.load(pdf) }
        preview?.status = status == 0 ? .built(warnings: problems.count - errors) : .failed(errors: errors, log: log)
        onBuildFinished?(root, status == 0)
        if buildAgain.remove(root) != nil { build(source: root, text: nil) }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = window() { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

// MARK: - The preview window

/// A document's PDF beside the editor: it refreshes in place after each build, says how the
/// build went, shows where a source line landed, and goes back to the source on ⌘-click.
@MainActor
final class LaTeXPreviewController: NSWindowController {
    enum Status: Equatable {
        case building
        case built(warnings: Int)
        case failed(errors: Int, log: String)
    }

    let root: URL
    var pdfURL: URL
    let pdfView = SyncPDFView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private var lastLog = ""
    var onInverseSearch: ((Int, CGPoint) -> Void)?

    var status: Status = .building { didSet { updateStatus() } }

    init(root: URL) {
        self.root = root
        pdfURL = root.deletingPathExtension().appendingPathExtension("pdf")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = pdfURL.lastPathComponent
        window.representedURL = pdfURL
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        let content = NSView()
        window.contentView = content
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = DS.Color.canvas
        pdfView.onCommandClick = { [weak self] page, point in self?.onInverseSearch?(page, point) }
        let bar = NSStackView(views: [spinner, statusLabel, NSView(), logButton])
        bar.orientation = .horizontal
        bar.spacing = DS.Spacing.s
        bar.edgeInsets = NSEdgeInsets(top: 0, left: DS.Spacing.m, bottom: 0, right: DS.Spacing.m)
        spinner.style = .spinning
        spinner.controlSize = .small
        statusLabel.font = DS.Text.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        logButton.bezelStyle = .accessoryBarAction
        logButton.font = DS.Text.caption()
        logButton.target = self
        logButton.action = #selector(showLog)
        for view in [pdfView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 28),
            pdfView.topAnchor.constraint(equalTo: bar.bottomAnchor), pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor), pdfView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    var statusText: String { statusLabel.stringValue }

    /// Beside Side's window, on the side with room, as tall as it.
    func placeBeside(_ main: NSWindow?) {
        guard let window, let main, let screen = main.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(640, max(420, visible.width * 0.35))
        var frame = NSRect(x: main.frame.maxX + 8, y: main.frame.minY, width: width, height: main.frame.height)
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, main.frame.minX - width - 8) }
        if frame.minX < visible.minX || frame.maxX > visible.maxX { frame.origin.x = visible.maxX - width }
        window.setFrame(frame.intersection(visible).isEmpty ? frame : frame.intersection(visible), display: false)
    }

    /// The new PDF, at the same page and place as the old one.
    func load(_ url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        let destination = pdfView.currentDestination
        let pageIndex = destination.flatMap { dest in dest.page.flatMap { pdfView.document?.index(for: $0) } }
        let point = destination?.point
        let scale = pdfView.scaleFactor
        let hadDocument = pdfView.document != nil
        pdfView.document = document
        window?.title = url.lastPathComponent
        window?.representedURL = url
        guard hadDocument, let pageIndex, let point, let page = document.page(at: min(pageIndex, document.pageCount - 1)) else { return }
        if !pdfView.autoScales { pdfView.scaleFactor = scale }
        pdfView.go(to: PDFDestination(page: page, at: point))
    }

    /// Where a source line landed: scrolled to, and marked for a moment.
    func reveal(page index: Int, box: CGRect) {
        guard let page = pdfView.document?.page(at: index) else { return }
        pdfView.go(to: box.insetBy(dx: 0, dy: -80), on: page)
        let mark = PDFAnnotation(bounds: box.insetBy(dx: -3, dy: -2), forType: .highlight, withProperties: nil)
        mark.color = NSColor.findHighlightColor.withAlphaComponent(0.55)
        page.addAnnotation(mark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak page] in page?.removeAnnotation(mark) }
    }

    private func updateStatus() {
        switch status {
        case .building:
            spinner.startAnimation(nil)
            spinner.isHidden = false
            statusLabel.stringValue = "Building\u{2026}"
            logButton.isHidden = true
        case .built(let warnings):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusLabel.stringValue = warnings == 0 ? "Built" : "Built, \(warnings) warning\(warnings == 1 ? "" : "s")"
            logButton.isHidden = true
        case .failed(let errors, let log):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            lastLog = log
            statusLabel.stringValue = errors == 0 ? "Build failed" : "Build failed, \(errors) error\(errors == 1 ? "" : "s") in Problems"
            logButton.isHidden = false
        }
    }

    @objc private func showLog() {
        let text = NSTextView()
        text.string = String(lastLog.suffix(200_000))
        text.font = DS.Text.code(11)
        text.isEditable = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.frame = scroll.bounds
        text.autoresizingMask = [.width]
        let alert = NSAlert()
        alert.messageText = "latexmk's output"
        alert.accessoryView = scroll
        if let window { alert.beginSheetModal(for: window) }
    }
}

/// The preview's PDF view: ⌘-click asks where that came from in the source.
final class SyncPDFView: PDFView {
    /// The page (from 0) and the point, from the page's top left in PDF points, as SyncTeX takes it.
    var onCommandClick: ((Int, CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: true) else { return }
        let point = convert(location, to: page)
        let height = page.bounds(for: .mediaBox).height
        onCommandClick?(document.index(for: page), CGPoint(x: point.x, y: height - point.y))
    }
}
