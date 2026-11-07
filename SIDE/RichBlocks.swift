import AppKit
import WebKit

/// Rich blocks (SIDE_DESIGN_SESSIONS_2026-11-06.md, session 2): an agent's block in a known
/// form draws as the thing itself, with a toggle back to its source. First: Mermaid diagrams,
/// tables (`csv`, `tsv`, Markdown tables) and pictures (`svg`, and images in the project).
/// Charts and HTML come later.
///
/// Each is drawn when its message is, which is when it scrolls into view (blocks far from the
/// viewport are let go), and is a picture of the text: the transcript and its record stay text.
enum RichBlocks {
    struct Block: Equatable {
        enum Kind: Equatable { case mermaid, table, svg, image }
        let kind: Kind
        /// The text as the agent wrote it, fences included: what Source shows and Copy gives.
        let source: String
        /// A table's rows, header first.
        var rows: [[String]] = []
        /// An image's file.
        var url: URL?
    }

    enum Segment: Equatable {
        case text(String)
        case block(Block)
    }

    /// Cheap enough to ask of every finished message.
    static func mayContainBlocks(_ text: String) -> Bool {
        text.contains("```") || text.contains("|") || text.contains("![")
    }

    /// The message cut into text and blocks, in order. Text that holds no block comes back as
    /// one `.text`. `image` resolves a path the agent wrote to an image file that exists.
    static func segments(_ text: String, image: (String) -> URL? = { _ in nil }) -> [Segment] {
        guard mayContainBlocks(text) else { return [.text(text)] }
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.text(joined.trimmingCharacters(in: .newlines))) }
            prose = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A fence: a known language becomes a block; any other stays text, fences and all.
            if trimmed.hasPrefix("```") {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                guard let end = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
                    prose.append(contentsOf: lines[index...])
                    break
                }
                let body = lines[(index + 1)..<end].joined(separator: "\n")
                let source = lines[index...end].joined(separator: "\n")
                if let block = fencedBlock(language: language, body: body, source: source) {
                    flushProse()
                    segments.append(.block(block))
                } else {
                    prose.append(contentsOf: lines[index...end])
                }
                index = end + 1
                continue
            }
            // A Markdown table: a header row, then a |---| row.
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                var end = index + 2
                while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
                let tableLines = Array(lines[index..<end])
                let rows = ([tableLines[0]] + tableLines.dropFirst(2)).map(markdownCells)
                flushProse()
                segments.append(.block(Block(kind: .table, source: tableLines.joined(separator: "\n"), rows: rows)))
                index = end
                continue
            }
            // An image on a line of its own: ![alt](path) to a file in the project.
            if let path = imagePath(trimmed), let url = image(path) {
                flushProse()
                segments.append(.block(Block(kind: .image, source: line, url: url)))
                index += 1
                continue
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        return segments.isEmpty ? [.text(text)] : segments
    }

    private static func fencedBlock(language: String, body: String, source: String) -> Block? {
        switch language {
        case "mermaid":
            return Block(kind: .mermaid, source: source)
        case "csv", "tsv":
            let rows = language == "csv" ? csvRows(body) : body.split(separator: "\n", omittingEmptySubsequences: true).map { $0.components(separatedBy: "\t") }
            guard rows.count >= 2 else { return nil }
            return Block(kind: .table, source: source, rows: rows)
        case "svg":
            guard body.contains("<svg") else { return nil }
            return Block(kind: .svg, source: source)
        default:
            return nil
        }
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// `| a | b |` → ["a", "b"]. An escaped `\|` stays in its cell.
    static func markdownCells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(cell); cell = ""; continue }
            cell.append(character)
        }
        cells.append(cell)
        // The row's own outer pipes leave an empty cell at each end.
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// RFC 4180's: quoted fields may hold commas, newlines and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if quoted {
                if character == "\"" {
                    if characters.first == "\"" { field.append("\""); characters.removeFirst() } else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if character != "\r" {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// The path in `![alt](path)`, when that's all the line holds.
    static func imagePath(_ line: String) -> String? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let open = line.range(of: "](") else { return nil }
        let path = String(line[open.upperBound..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains("://") else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff", "pdf"].contains(ext) ? path : nil
    }
}

// MARK: - Views

/// A finished message holding blocks: its prose as bubbles, its blocks as cards between them.
final class RichMessageView: NSStackView {
    init(segments: [RichBlocks.Segment], bubble: (String) -> NSView, maxWidth: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = DS.Spacing.s
        translatesAutoresizingMaskIntoConstraints = false
        for segment in segments {
            switch segment {
            case .text(let text):
                let view = bubble(text)
                addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            case .block(let block):
                let card = RichBlockView(block: block, maxWidth: maxWidth)
                addArrangedSubview(card)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The message's text, for Copy and VoiceOver.
    var blockViews: [RichBlockView] { arrangedSubviews.compactMap { $0 as? RichBlockView } }
}

/// One block on the raised tone: what it is, Source to see the text, and the thing itself.
final class RichBlockView: NSView {
    let block: RichBlocks.Block
    private let body = NSView()
    private let sourceButton = NSButton(title: "", target: nil, action: nil)
    private var showingSource = false
    private var rendered: NSView?
    private let maxWidth: CGFloat
    /// What drawing it said, when it couldn't (a diagram that doesn't parse).
    private(set) var problem: String?

    init(block: RichBlocks.Block, maxWidth: CGFloat) {
        self.block = block
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.surface
        layer?.cornerCurve = .continuous
        bindLayerBackground(DS.Color.raised)

        let title = NSTextField(labelWithString: Self.title(of: block))
        title.font = DS.Text.caption(.semibold)
        title.textColor = .secondaryLabelColor
        sourceButton.isBordered = false
        sourceButton.target = self
        sourceButton.action = #selector(toggleSource)
        setSourceTitle()
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, spacer, sourceButton])
        header.orientation = .horizontal
        header.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: DS.Spacing.s),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DS.Spacing.s),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.m),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Spacing.m),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.m),
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        ])
        let fill = widthAnchor.constraint(equalToConstant: maxWidth)
        fill.priority = .defaultHigh
        fill.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title(of: block))
        show(makeRendered())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func title(of block: RichBlocks.Block) -> String {
        switch block.kind {
        case .mermaid: return "Diagram"
        case .table:
            let count = max(0, block.rows.count - 1)
            return "Table \u{00B7} \(count) row\(count == 1 ? "" : "s")"
        case .svg: return "Picture"
        case .image: return block.url?.lastPathComponent ?? "Image"
        }
    }

    var isShowingSourceForTesting: Bool { showingSource }

    @objc func toggleSource() {
        showingSource.toggle()
        setSourceTitle()
        show(showingSource ? makeSource() : (rendered ?? makeRendered()))
    }

    private func setSourceTitle() {
        sourceButton.attributedTitle = NSAttributedString(string: showingSource ? "Show Result" : "Source",
                                                          attributes: [.font: DS.Text.caption(.medium), .foregroundColor: DS.Color.accent])
        sourceButton.setAccessibilityLabel(showingSource ? "Show the result" : "Show the source")
    }

    private func show(_ view: NSView) {
        body.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
    }

    private func makeRendered() -> NSView {
        let view: NSView
        switch block.kind {
        case .mermaid:
            let diagram = MermaidView(source: Self.fenceBody(block.source), width: maxWidth - DS.Spacing.m * 2)
            diagram.onProblem = { [weak self] message in
                guard let self else { return }
                self.problem = message
                self.rendered = self.makeProblem(message)
                if !self.showingSource { self.show(self.rendered!) }
            }
            view = diagram
        case .table:
            view = TableBlockView(rows: block.rows)
        case .svg:
            view = Self.picture(NSImage(data: Data(Self.fenceBody(block.source).utf8))) ?? makeProblem("The picture couldn\u{2019}t be drawn.")
        case .image:
            view = Self.picture(block.url.flatMap { NSImage(contentsOf: $0) }) ?? makeProblem("The image couldn\u{2019}t be read.")
        }
        rendered = view
        return view
    }

    private static func picture(_ image: NSImage?) -> NSView? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignLeft
        let height = min(image.size.height, 420)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func makeProblem(_ message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = DS.Text.caption()
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSource() -> NSView {
        let label = NSTextField(wrappingLabelWithString: block.source)
        label.font = DS.Text.code(11)
        label.textColor = .labelColor
        label.isSelectable = true
        return label
    }

    /// A fence's inside.
    static func fenceBody(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// A table: its header, its rows, sorted by a click on a column's title.
final class TableBlockView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let header: [String]
    private var rows: [[String]]
    private let table = NSTableView()
    private static let visibleRows = 12

    init(rows all: [[String]]) {
        header = all.first ?? []
        let width = header.count
        rows = all.dropFirst().map { row in row.count >= width ? Array(row.prefix(width)) : row + Array(repeating: "", count: width - row.count) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (index, title) in header.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            column.title = title
            column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            let widest = ([title] + rows.map { $0[index] }).map { ($0 as NSString).size(withAttributes: [.font: DS.Text.caption()]).width }.max() ?? 60
            column.width = min(max(widest + 16, 48), 280)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let shown = CGFloat(min(rows.count, Self.visibleRows))
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: (shown + 1) * (table.rowHeight + table.intercellSpacing.height) + 8),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var rowsForTesting: [[String]] { rows }
    func sortForTesting(column: Int, ascending: Bool) {
        table.sortDescriptors = [NSSortDescriptor(key: "\(column)", ascending: ascending)]
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let label = NSTextField(labelWithString: rows[row][column])
        label.font = DS.Text.caption()
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        return label
    }

    /// Numbers sort as numbers, everything else as text a person would order it.
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let column = Int(key) else { return }
        rows = Self.sorted(rows, column: column, ascending: descriptor.ascending)
        tableView.reloadData()
    }

    static func sorted(_ rows: [[String]], column: Int, ascending: Bool) -> [[String]] {
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " %$"))) }
        return rows.sorted { a, b in
            let x = a[column], y = b[column]
            let ordered: Bool
            if let p = number(x), let q = number(y) { ordered = p < q } else { ordered = x.localizedStandardCompare(y) == .orderedAscending }
            return ascending ? ordered : !ordered && x != y
        }
    }
}

/// A Mermaid diagram, drawn by the Mermaid that ships with Side in a web view that can't load
/// anything or go anywhere: no network, links don't navigate, Mermaid's strict security level.
final class MermaidView: NSView, WKNavigationDelegate {
    var onProblem: ((String) -> Void)?
    private var webView: WKWebView?
    private let source: String
    private let width: CGFloat
    private lazy var height = heightAnchor.constraint(equalToConstant: 60)
    private(set) var drawnSize: CGSize?

    init(source: String, width: CGFloat) {
        self.source = source
        self.width = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
        MermaidRuntime.shared.configuration { [weak self] configuration in
            guard let self, let configuration else { self?.onProblem?("Diagrams can\u{2019}t be drawn: Side\u{2019}s copy of Mermaid is missing."); return }
            self.start(configuration)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func start(_ configuration: WKWebViewConfiguration) {
        let handler = MermaidMessages(view: self)
        configuration.userContentController.removeScriptMessageHandler(forName: "side")
        configuration.userContentController.add(handler, name: "side")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 60), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setAccessibilityElement(false)
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.webView = webView
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.loadHTMLString(MermaidRuntime.page(source: source, dark: dark), baseURL: nil)
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if let problem = message["error"] as? String {
            webView?.removeFromSuperview()
            webView = nil
            onProblem?("This diagram didn\u{2019}t parse: \(problem)")
            return
        }
        guard let w = (message["w"] as? NSNumber)?.doubleValue, let h = (message["h"] as? NSNumber)?.doubleValue, h > 0 else { return }
        drawnSize = CGSize(width: w, height: h)
        height.constant = ceil(h)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Diagram")
    }

    /// The page itself and nothing else: a link in a diagram doesn't navigate.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    deinit {
        MainActor.assumeIsolated {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "side")
        }
    }
}

/// Messages from a diagram's page, held weakly: a script handler is retained by its controller.
private final class MermaidMessages: NSObject, WKScriptMessageHandler {
    weak var view: MermaidView?
    init(view: MermaidView) { self.view = view }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { view?.received(message.body) }
    }
}

/// Mermaid's script, read once from the app, and a rule list that blocks every load.
@MainActor
final class MermaidRuntime {
    static let shared = MermaidRuntime()
    private var script: String?
    private var rules: WKContentRuleList?
    private var compiling = false
    private var waiting: [(WKWebViewConfiguration?) -> Void] = []

    /// A fresh configuration per diagram (each has its own message handler), sharing the script
    /// and the rules.
    func configuration(_ completion: @escaping (WKWebViewConfiguration?) -> Void) {
        if script == nil {
            script = Bundle.main.url(forResource: "mermaid.min", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard script != nil else { return completion(nil) }
        if let rules { return completion(make(rules)) }
        waiting.append(completion)
        guard !compiling else { return }
        compiling = true
        // Every load but the page itself: images, styles, scripts, fonts, fetches, frames.
        let blockEverything = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","svg-document","media","popup","fetch","websocket","other"]},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "side.rich-blocks.offline", encodedContentRuleList: blockEverything) { [weak self] list, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.compiling = false
                self.rules = list
                let waiting = self.waiting
                self.waiting = []
                for completion in waiting { completion(list.map(self.make)) }
            }
        }
    }

    private func make(_ rules: WKContentRuleList) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(WKUserScript(source: script ?? "", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return configuration
    }

    /// The page: Mermaid at its strict security level, the diagram fitted to the width, and its
    /// drawn size (or what went wrong) posted back.
    static func page(source: String, dark: Bool) -> String {
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [source], options: [.fragmentsAllowed]), encoding: .utf8)) ?? "[\"\"]"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}#d{display:block}#d svg{max-width:100%;height:auto;display:block}</style>
        </head><body><div id="d"></div><script>
        (function(){
          const post = (m) => window.webkit.messageHandlers.side.postMessage(m);
          // Mermaid's message is a few lines with a ---^ pointer between them: the words only.
          const brief = (e) => String((e && e.message) || e).split('\\n').filter(l => !/^[-\\s^]*$/.test(l)).slice(0, 3).join(' ').slice(0, 240);
          try {
            mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'\(dark ? "dark" : "default")',
              fontFamily:'-apple-system, BlinkMacSystemFont, sans-serif', themeVariables:{background:'transparent'}});
            mermaid.render('side-diagram', \(quoted)[0]).then(function(r){
              const d = document.getElementById('d'); d.innerHTML = r.svg;
              const box = d.getBoundingClientRect(); post({w: box.width, h: box.height});
            }).catch(function(e){ post({error: brief(e)}); });
          } catch (e) { post({error: brief(e)}); }
        })();
        </script></body></html>
        """
    }
}

extension NSView {
    /// The first view of a type in this one's subtree, depth first.
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
