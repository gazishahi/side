import AppKit
import Heron

/// Make's spreadsheets: CSV and TSV files, and Excel workbooks (read-only), shown in a sheet
/// view rather than as text.
enum CSVParser {
    /// The delimiter a file uses: a tab for `.tsv`/`.tab`, or for a file whose first line has
    /// tabs and no commas; a semicolon for one with only semicolons (Excel in many locales);
    /// otherwise a comma.
    static func delimiter(forExtension ext: String, text: String) -> Character {
        if ["tsv", "tab"].contains(ext.lowercased()) { return "\t" }
        let first = text.prefix { $0 != "\n" }
        if first.contains("\t"), !first.contains(",") { return "\t" }
        if first.contains(";"), !first.contains(",") { return ";" }
        return ","
    }

    /// Handles quoted fields, delimiters/newlines inside quotes, and escaped `""` quotes —
    /// a naive `components(separatedBy: ",")` breaks on any of those.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var insideQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if insideQuotes {
                if char == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    insideQuotes = false
                    i += 1
                    continue
                }
                field.append(char)
                i += 1
            } else {
                switch char {
                case "\"":
                    insideQuotes = true
                    i += 1
                case delimiter:
                    currentRow.append(field)
                    field = ""
                    i += 1
                case "\n":
                    currentRow.append(field)
                    rows.append(currentRow)
                    currentRow = []
                    field = ""
                    i += 1
                case "\r":
                    i += 1
                default:
                    field.append(char)
                    i += 1
                }
            }
        }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            rows.append(currentRow)
        }
        return rows
    }
}

/// One sheet: a name and its rows, the first being the header.
struct Sheet: Equatable {
    var name: String
    var rows: [[String]]
}

// MARK: - Excel workbooks

/// Reads an .xlsx workbook's values, sheet by sheet: unzipped with the system's `ditto`, then
/// its XML read (shared strings, inline strings, numbers, booleans, and dates where a cell's
/// format is a date format). Formulas show their last computed value. Read-only.
enum XLSXReader {
    enum Failure: Error { case unreadable }

    static func read(_ url: URL) throws -> [Sheet] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("side-xlsx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.environment = SpawnEnvironment.current()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw Failure.unreadable }
        let xl = folder.appendingPathComponent("xl")
        let shared = (try? Data(contentsOf: xl.appendingPathComponent("sharedStrings.xml"))).map(SharedStrings.parse) ?? []
        let dateStyles = (try? Data(contentsOf: xl.appendingPathComponent("styles.xml"))).map(DateStyles.parse) ?? []
        guard let workbook = try? Data(contentsOf: xl.appendingPathComponent("workbook.xml")) else { throw Failure.unreadable }
        let targets = (try? Data(contentsOf: xl.appendingPathComponent("_rels/workbook.xml.rels"))).map(Relationships.parse) ?? [:]
        var sheets: [Sheet] = []
        for (index, entry) in Workbook.parse(workbook).enumerated() {
            let target = targets[entry.relationship] ?? "worksheets/sheet\(index + 1).xml"
            let path = target.hasPrefix("/") ? folder.appendingPathComponent(String(target.dropFirst())) : xl.appendingPathComponent(target)
            guard let data = try? Data(contentsOf: path) else { continue }
            sheets.append(Sheet(name: entry.name, rows: Worksheet.parse(data, shared: shared, dateStyles: dateStyles)))
        }
        return sheets
    }

    /// Element text gathered by name, for the small XML documents a workbook has.
    private class Reader: NSObject, XMLParserDelegate {
        var text = ""
        func parse(_ data: Data) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    }

    private final class SharedStrings: Reader {
        var strings: [String] = []
        private var inItem = false, inText = false
        static func parse(_ data: Data) -> [String] { let reader = SharedStrings(); reader.parse(data); return reader.strings }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { inItem = true; text = "" }
            if name == "t" { inText = true }
            if name == "rPh" { inText = false }  // phonetic guides aren't the value
        }
        override func parser(_ parser: XMLParser, foundCharacters string: String) { if inItem, inText { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(text); inItem = false }
        }
    }

    /// Which cell styles (by index) show a date: built-in date formats, or custom ones with day,
    /// month or year codes.
    private final class DateStyles: Reader {
        var custom: [Int: String] = [:]
        var styles: [Int] = []  // numFmtId per cellXfs entry
        private var inXfs = false
        static func parse(_ data: Data) -> [Bool] {
            let reader = DateStyles()
            reader.parse(data)
            return reader.styles.map { id in
                if (14...22).contains(id) || (45...47).contains(id) { return true }
                guard let code = reader.custom[id]?.lowercased() else { return false }
                let stripped = code.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                return stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && !stripped.contains("h") && !stripped.contains("s"))
            }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { custom[id] = code }
            if name == "cellXfs" { inXfs = true }
            if name == "xf", inXfs { styles.append(attributes["numFmtId"].flatMap(Int.init) ?? 0) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inXfs = false }
        }
    }

    private final class Workbook: Reader {
        var sheets: [(name: String, relationship: String)] = []
        static func parse(_ data: Data) -> [(name: String, relationship: String)] { let reader = Workbook(); reader.parse(data); return reader.sheets }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "sheet" else { return }
            sheets.append((attributes["name"] ?? "Sheet \(sheets.count + 1)", attributes["r:id"] ?? ""))
        }
    }

    private final class Relationships: Reader {
        var targets: [String: String] = [:]
        static func parse(_ data: Data) -> [String: String] { let reader = Relationships(); reader.parse(data); return reader.targets }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }
    }

    private final class Worksheet: Reader {
        let shared: [String]
        let dateStyles: [Bool]
        var cells: [Int: [Int: String]] = [:]
        private var row = 0, column = 0, type = "", style = 0
        private var inValue = false
        init(shared: [String], dateStyles: [Bool]) { self.shared = shared; self.dateStyles = dateStyles }

        static func parse(_ data: Data, shared: [String], dateStyles: [Bool]) -> [[String]] {
            let reader = Worksheet(shared: shared, dateStyles: dateStyles)
            reader.parse(data)
            guard let lastRow = reader.cells.keys.max() else { return [] }
            let width = (reader.cells.values.flatMap(\.keys).max() ?? 0) + 1
            return (0...lastRow).map { r in (0..<width).map { reader.cells[r]?[$0] ?? "" } }
        }

        /// "B3" → (row 2, column 1).
        static func position(_ reference: String) -> (row: Int, column: Int)? {
            var column = 0
            var digits = ""
            for character in reference {
                if let ascii = character.asciiValue, character.isLetter { column = column * 26 + Int(ascii - 64) } else { digits.append(character) }
            }
            guard let row = Int(digits), column > 0 else { return nil }
            return (row - 1, column - 1)
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row": if let r = attributes["r"].flatMap(Int.init) { row = r - 1 }; column = -1
            case "c":
                column += 1
                if let reference = attributes["r"], let position = Self.position(reference) { row = position.row; column = position.column }
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                text = ""
            case "v", "t": inValue = true
            default: break
            }
        }
        override func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                let value: String
                switch type {
                case "s": value = Int(text).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "b": value = text == "1" ? "TRUE" : "FALSE"
                case "n" where style < dateStyles.count && dateStyles[style]:
                    value = Double(text).map(Self.date) ?? text
                default: value = text
                }
                if !value.isEmpty { cells[row, default: [:]][column] = value }
            default: break
            }
        }

        /// An Excel serial date (days since 1899-12-30), as ISO 8601; with a time if it has one.
        static func date(_ serial: Double) -> String {
            let base = Date(timeIntervalSince1970: -2_209_161_600)  // 1899-12-30
            let date = base.addingTimeInterval(serial * 86_400)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }
}

// MARK: - The sheet view

/// A sheet as a spreadsheet: row numbers, a header, numbers right-aligned in even-width digits,
/// columns sized to their content, sorted by clicking a header, ⌘C copying the selected rows as
/// tab-separated text (which spreadsheets paste as cells), and a footer with the size and, for a
/// workbook, a tab per sheet. Read-only.
@MainActor
final class SheetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let table = SheetTableView()
    private let footer = NSStackView()
    /// The footer floats on a card, like the stage's other floating chrome, and the rows scroll under it.
    private let footerCard = NSBox()
    private let summary = NSTextField(labelWithString: "")
    private let sheetPicker = NSSegmentedControl()
    private var footerBottom: NSLayoutConstraint?

    private(set) var sheets: [Sheet] = []
    private(set) var current = 0
    private var header: [String] = []
    /// Data rows in the order shown, each with its original row number.
    private(set) var rows: [(number: Int, cells: [String])] = []
    private var numeric: [Bool] = []
    static let rowNumberColumn = NSUserInterfaceItemIdentifier("sheet.row")

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = NSTableHeaderView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = DS.Color.hairline
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.onCopy = { [weak self] in self?.copySelection() }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        summary.font = DS.Text.caption()
        summary.textColor = .secondaryLabelColor
        sheetPicker.segmentStyle = .rounded
        sheetPicker.controlSize = .small
        sheetPicker.target = self
        sheetPicker.action = #selector(sheetPicked)
        footer.orientation = .horizontal
        footer.spacing = DS.Spacing.m
        footer.addArrangedSubview(sheetPicker)
        footer.addArrangedSubview(summary)
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: DS.Spacing.m)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerCard.boxType = .custom
        footerCard.fillColor = DS.Color.overlay
        footerCard.borderWidth = 0
        footerCard.cornerRadius = DS.Radius.surface
        footerCard.contentViewMargins = .zero
        footerCard.translatesAutoresizingMaskIntoConstraints = false
        footerCard.addSubview(footer)
        addSubview(footerCard)
        let bottom = footerCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Spacing.m)
        footerBottom = bottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.topAnchor.constraint(equalTo: footerCard.topAnchor), footer.bottomAnchor.constraint(equalTo: footerCard.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: footerCard.leadingAnchor), footer.trailingAnchor.constraint(equalTo: footerCard.trailingAnchor),
            footerCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Spacing.l), bottom,
        ])
        setBottomInset(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where the footer sits above whatever covers the bottom of the stage; the last row scrolls
    /// clear of both.
    func setBottomInset(_ inset: CGFloat) {
        footerBottom?.constant = -(inset + DS.Spacing.m)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets.bottom = inset + DS.Spacing.m + 32 + DS.Spacing.s
    }

    func show(_ sheets: [Sheet]) {
        self.sheets = sheets
        sheetPicker.segmentCount = sheets.count
        for (index, sheet) in sheets.enumerated() { sheetPicker.setLabel(sheet.name, forSegment: index); sheetPicker.setWidth(0, forSegment: index) }
        sheetPicker.isHidden = sheets.count < 2
        select(sheet: min(current, max(0, sheets.count - 1)))
    }

    func select(sheet index: Int) {
        guard sheets.indices.contains(index) else { header = []; rows = []; rebuild(); return }
        current = index
        sheetPicker.selectedSegment = index
        let all = sheets[index].rows
        let width = all.map(\.count).max() ?? 0
        header = (all.first ?? []) + Array(repeating: "", count: max(0, width - (all.first?.count ?? 0)))
        rows = all.dropFirst().enumerated().map { ($0.offset + 1, $0.element + Array(repeating: "", count: max(0, width - $0.element.count))) }
        numeric = (0..<width).map { column in Self.isNumeric(rows.prefix(500).map { $0.cells[column] }) }
        rebuild()
    }

    @objc private func sheetPicked() { select(sheet: sheetPicker.selectedSegment) }

    /// A column of numbers: most of its filled cells read as one.
    static func isNumeric(_ cells: [String]) -> Bool {
        let filled = cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return false }
        let numbers = filled.filter { Double($0.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "%", with: "")) != nil }
        return Double(numbers.count) >= Double(filled.count) * 0.8
    }

    private func rebuild() {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        let numberColumn = NSTableColumn(identifier: Self.rowNumberColumn)
        numberColumn.title = ""
        numberColumn.width = max(36, CGFloat(String(rows.count).count) * 8 + 18)
        numberColumn.resizingMask = []
        table.addTableColumn(numberColumn)
        let font = Self.cellFont
        let sample = rows.prefix(200)
        for (index, title) in header.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sheet.\(index)"))
            column.title = title.isEmpty ? Self.letter(index) : title
            column.headerToolTip = Self.letter(index)
            column.headerCell.alignment = numeric[safe: index] == true ? .right : .left
            column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            let widest = sample.map { ($0.cells[index] as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let titleWidth = (column.title as NSString).size(withAttributes: [.font: DS.Text.body(.medium)]).width
            column.width = min(320, max(64, max(widest, titleWidth) + 24))
            table.addTableColumn(column)
        }
        table.sortDescriptors = []
        table.reloadData()
        updateSummary()
    }

    /// Spreadsheet column letters: A … Z, AA ….
    static func letter(_ index: Int) -> String {
        var index = index + 1
        var letters = ""
        while index > 0 { letters = String(UnicodeScalar(UInt8(65 + (index - 1) % 26))) + letters; index = (index - 1) / 26 }
        return letters
    }

    private func updateSummary() {
        let selected = table.selectedRowIndexes.count
        var text = "\(rows.count.formatted()) row\(rows.count == 1 ? "" : "s") \u{00B7} \(header.count) column\(header.count == 1 ? "" : "s")"
        if selected > 1 { text += " \u{00B7} \(selected) selected" }
        summary.stringValue = text
    }

    /// Even-width digits, so numbers line up down a column.
    static var cellFont: NSFont {
        let base = DS.Text.body()
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let id = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let field = cell.textField
        field?.font = Self.cellFont
        if id == Self.rowNumberColumn {
            field?.stringValue = String(rows[row].number)
            field?.alignment = .right
            field?.textColor = .tertiaryLabelColor
        } else if let index = Int(id.rawValue.dropFirst("sheet.".count)) {
            field?.stringValue = rows[row].cells[index]
            field?.alignment = numeric[safe: index] == true ? .right : .left
            field?.textColor = .labelColor
            field?.toolTip = rows[row].cells[index].count > 40 ? rows[row].cells[index] : nil
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let index = Int(key) else { return }
        let asNumbers = numeric[safe: index] == true
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "%", with: "")) }
        rows.sort { a, b in
            let x = a.cells[index], y = b.cells[index]
            if asNumbers, let p = number(x), let q = number(y), p != q { return descriptor.ascending ? p < q : p > q }
            if x.isEmpty != y.isEmpty { return !x.isEmpty }  // blanks last
            let order = x.localizedStandardCompare(y)
            if order == .orderedSame { return a.number < b.number }
            return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        tableView.reloadData()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSummary() }

    /// The selected rows as tab-separated text, the header first when every row is selected.
    func copySelection() {
        let selected = table.selectedRowIndexes
        guard !selected.isEmpty else { return }
        func line(_ cells: [String]) -> String { cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
        var lines = selected.count == rows.count ? [line(header)] : []
        lines += selected.map { line(rows[$0].cells) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// The sheet's table, answering ⌘C.
final class SheetTableView: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
