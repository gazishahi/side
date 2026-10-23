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

/// One sheet: a name and its rows. From a workbook it also has each cell's style, the number
/// behind each shown value ("15.3%" is 0.153, for sorting and sums), and the widths it sets.
struct Sheet: Equatable {
    var name: String
    var rows: [[String]]
    /// The first row titles the columns. Always for CSV; a workbook's when it reads as one.
    var headerRow = true
    /// Per cell, an index into `styles`; empty when nothing is styled (a CSV).
    var styleIndex: [[Int]] = []
    var styles: [CellStyle] = [CellStyle()]
    /// Per cell, the number shown, where it is one; empty for a CSV.
    var numbers: [[Double?]] = []
    /// Column widths in points, where the workbook sets them.
    var columnWidths: [Int: CGFloat] = [:]

    init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }
}

/// How a workbook draws a cell. Colours are 0xRRGGBB as the workbook has them; the sheet view
/// fits them to light or dark.
struct CellStyle: Hashable {
    enum Alignment: Hashable { case left, center, right }
    var bold = false, italic = false, underline = false, strikethrough = false
    var color: UInt32?
    var fill: UInt32?
    var alignment: Alignment?
}

// MARK: - Excel workbooks

/// Reads an .xlsx workbook sheet by sheet: unzipped with the system's `ditto`, then its XML
/// read: values (shared and inline strings, numbers, booleans), each shown through its number
/// format (dates, percentages, currency, decimals), and the look of each cell (bold, italic,
/// underline, colour, fill, alignment) and column widths. Formulas show their last computed
/// value; merged cells show their value in the first cell. Read-only.
enum XLSXReader {
    enum Failure: Error { case unreadable }

    static func read(_ url: URL, locale: Locale = .current) throws -> [Sheet] {
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
        let theme = (try? Data(contentsOf: xl.appendingPathComponent("theme/theme1.xml"))).map(ThemeColors.parse) ?? []
        let styles = (try? Data(contentsOf: xl.appendingPathComponent("styles.xml"))).map { Styles.parse($0, theme: theme) } ?? Styles.Result()
        guard let workbook = try? Data(contentsOf: xl.appendingPathComponent("workbook.xml")) else { throw Failure.unreadable }
        let targets = (try? Data(contentsOf: xl.appendingPathComponent("_rels/workbook.xml.rels"))).map(Relationships.parse) ?? [:]
        let formatter = NumberFormatCode(locale: locale)
        var sheets: [Sheet] = []
        for (index, entry) in Workbook.parse(workbook).enumerated() {
            let target = targets[entry.relationship] ?? "worksheets/sheet\(index + 1).xml"
            let path = target.hasPrefix("/") ? folder.appendingPathComponent(String(target.dropFirst())) : xl.appendingPathComponent(target)
            guard let data = try? Data(contentsOf: path) else { continue }
            sheets.append(Worksheet.parse(data, name: entry.name, shared: shared, styles: styles, formatter: formatter))
        }
        return sheets
    }

    /// An element's name without its namespace prefix ("x:row" is "row").
    fileprivate static func local(_ name: String) -> Substring { name.split(separator: ":").last ?? Substring(name) }

    /// Element text gathered by name, for the small XML documents a workbook has.
    fileprivate class Reader: NSObject, XMLParserDelegate {
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
            let name = XLSXReader.local(name)
            if name == "si" { inItem = true; text = "" }
            if name == "t" { inText = true }
            if name == "rPh" { inText = false }  // phonetic guides aren't the value
        }
        override func parser(_ parser: XMLParser, foundCharacters string: String) { if inItem, inText { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let name = XLSXReader.local(name)
            if name == "t" { inText = false }
            if name == "si" { strings.append(text); inItem = false }
        }
    }

    /// The theme's colours in the order cells name them: lt1, dk1, lt2, dk2, the six accents,
    /// then the two link colours. (The file lists dk1 before lt1.)
    private final class ThemeColors: Reader {
        var colors: [UInt32] = []
        private var inScheme = false
        static func parse(_ data: Data) -> [UInt32] {
            let reader = ThemeColors()
            reader.parse(data)
            var colors = reader.colors
            if colors.count >= 4 { colors.swapAt(0, 1); colors.swapAt(2, 3) }
            return colors
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = XLSXReader.local(name)
            if name == "clrScheme" { inScheme = true }
            guard inScheme else { return }
            if name == "srgbClr", let value = attributes["val"].flatMap({ UInt32($0, radix: 16) }) { colors.append(value) }
            if name == "sysClr" { colors.append(attributes["lastClr"].flatMap { UInt32($0, radix: 16) } ?? 0) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if XLSXReader.local(name) == "clrScheme" { inScheme = false }
        }
    }

    /// Each cell format (cellXfs): its number format code and its look.
    fileprivate final class Styles: Reader {
        struct Result {
            var formats: [String] = []
            var looks: [CellStyle] = []
        }
        private let theme: [UInt32]
        private var custom: [Int: String] = [:]
        private var fonts: [CellStyle] = []
        private var fills: [UInt32?] = []
        private var xfs: [(format: Int, font: Int, fill: Int, alignment: CellStyle.Alignment?)] = []
        private var section = ""
        private var font = CellStyle()
        private var fill: UInt32?
        private var solid = false

        init(theme: [UInt32]) { self.theme = theme }

        static func parse(_ data: Data, theme: [UInt32]) -> Result {
            let reader = Styles(theme: theme)
            reader.parse(data)
            return Result(
                formats: reader.xfs.map { reader.custom[$0.format] ?? NumberFormatCode.builtIn($0.format) },
                looks: reader.xfs.map { xf in
                    var look = reader.fonts.indices.contains(xf.font) ? reader.fonts[xf.font] : CellStyle()
                    look.fill = reader.fills.indices.contains(xf.fill) ? reader.fills[xf.fill] : nil
                    look.alignment = xf.alignment
                    return look
                })
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = String(XLSXReader.local(name))
            func on(_ key: String) -> Bool { !["0", "false"].contains(attributes[key] ?? "1") }
            switch (section, name) {
            case (_, "fonts"), (_, "fills"), (_, "cellXfs"), (_, "cellStyleXfs"), (_, "dxfs"): section = name
            case (_, "numFmt"):
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { custom[id] = code }
            case ("fonts", "font"): font = CellStyle()
            case ("fonts", "b"): font.bold = on("val")
            case ("fonts", "i"): font.italic = on("val")
            case ("fonts", "strike"): font.strikethrough = on("val")
            case ("fonts", "u"): font.underline = attributes["val"] != "none"
            case ("fonts", "color"): font.color = Self.color(attributes, theme: theme)
            case ("fills", "fill"): fill = nil; solid = false
            case ("fills", "patternFill"): solid = attributes["patternType"] == "solid"
            case ("fills", "fgColor"): if solid { fill = Self.color(attributes, theme: theme) }
            case ("cellXfs", "xf"):
                xfs.append((attributes["numFmtId"].flatMap(Int.init) ?? 0, attributes["fontId"].flatMap(Int.init) ?? 0,
                            attributes["fillId"].flatMap(Int.init) ?? 0, nil))
            case ("cellXfs", "alignment"):
                guard !xfs.isEmpty else { break }
                switch attributes["horizontal"] {
                case "left": xfs[xfs.count - 1].alignment = .left
                case "center", "centerContinuous": xfs[xfs.count - 1].alignment = .center
                case "right": xfs[xfs.count - 1].alignment = .right
                default: break
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let name = String(XLSXReader.local(name))
            if name == section { section = ""; return }
            if section == "fonts", name == "font" { fonts.append(font) }
            if section == "fills", name == "fill" { fills.append(fill) }
        }

        /// A colour as a cell names it: ARGB, a theme colour (lightened or darkened by its
        /// tint), or one of the legacy indexed colours. Automatic is nil.
        static func color(_ attributes: [String: String], theme: [UInt32]) -> UInt32? {
            if attributes["auto"] == "1" { return nil }
            var base: UInt32?
            if let rgb = attributes["rgb"] { base = UInt32(rgb.suffix(6), radix: 16) }
            else if let index = attributes["theme"].flatMap(Int.init), theme.indices.contains(index) { base = theme[index] }
            else if let index = attributes["indexed"].flatMap(Int.init), legacy.indices.contains(index) { base = legacy[index] }
            guard let color = base else { return nil }
            guard let tint = attributes["tint"].flatMap(Double.init), tint != 0 else { return color }
            return SheetColor.tinted(color, by: tint)
        }

        /// Excel's legacy palette, for `indexed` colours (64 and up are the system's own).
        static let legacy: [UInt32] = [
            0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
            0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
            0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
            0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
            0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
            0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
            0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
            0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
        ]
    }

    private final class Workbook: Reader {
        var sheets: [(name: String, relationship: String)] = []
        static func parse(_ data: Data) -> [(name: String, relationship: String)] { let reader = Workbook(); reader.parse(data); return reader.sheets }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard XLSXReader.local(name) == "sheet" else { return }
            sheets.append((attributes["name"] ?? "Sheet \(sheets.count + 1)", attributes["r:id"] ?? ""))
        }
    }

    private final class Relationships: Reader {
        var targets: [String: String] = [:]
        static func parse(_ data: Data) -> [String: String] { let reader = Relationships(); reader.parse(data); return reader.targets }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if XLSXReader.local(name) == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }
    }

    private final class Worksheet: Reader {
        struct Cell { var value: String; var format: Int; var number: Double? }
        let shared: [String]
        let styles: Styles.Result
        let formatter: NumberFormatCode
        var cells: [Int: [Int: Cell]] = [:]
        var widths: [Int: CGFloat] = [:]
        private var row = 0, column = 0, type = "", format = 0
        private var inValue = false
        init(shared: [String], styles: Styles.Result, formatter: NumberFormatCode) { self.shared = shared; self.styles = styles; self.formatter = formatter }

        static func parse(_ data: Data, name: String, shared: [String], styles: Styles.Result, formatter: NumberFormatCode) -> Sheet {
            let reader = Worksheet(shared: shared, styles: styles, formatter: formatter)
            reader.parse(data)
            var sheet = Sheet(name: name, rows: [])
            sheet.columnWidths = reader.widths
            guard let lastRow = reader.cells.keys.max() else { return sheet }
            let width = (reader.cells.values.flatMap(\.keys).max() ?? 0) + 1
            var palette = [CellStyle()]
            var paletteIndex: [Int: Int] = [:]
            func look(_ format: Int) -> Int {
                if let known = paletteIndex[format] { return known }
                let style = styles.looks.indices.contains(format) ? styles.looks[format] : CellStyle()
                let index = palette.firstIndex(of: style) ?? { palette.append(style); return palette.count - 1 }()
                paletteIndex[format] = index
                return index
            }
            var rows: [[String]] = [], looks: [[Int]] = [], numbers: [[Double?]] = []
            rows.reserveCapacity(lastRow + 1)
            for r in 0...lastRow {
                let line = reader.cells[r]
                rows.append((0..<width).map { line?[$0]?.value ?? "" })
                looks.append((0..<width).map { line?[$0].map { look($0.format) } ?? 0 })
                numbers.append((0..<width).map { line?[$0]?.number })
            }
            sheet.rows = rows
            sheet.headerRow = Self.looksLikeHeader(rows: rows, numbers: numbers)
            if palette.count > 1 { sheet.styleIndex = looks; sheet.styles = palette }
            if numbers.contains(where: { $0.contains { $0 != nil } }) { sheet.numbers = numbers }
            return sheet
        }

        /// A first row of labels over rows of data: most of its cells filled, none a number,
        /// and something under it. A report's title row over blank rows isn't one.
        static func looksLikeHeader(rows: [[String]], numbers: [[Double?]]) -> Bool {
            guard rows.count > 1, let first = rows.first, !first.isEmpty else { return false }
            let filled = first.filter { !$0.isEmpty }.count
            return filled * 2 >= first.count && !numbers[0].contains { $0 != nil } && rows[1].contains { !$0.isEmpty }
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
            switch XLSXReader.local(name) {
            case "row": if let r = attributes["r"].flatMap(Int.init) { row = r - 1 }; column = -1
            case "c":
                column += 1
                if let reference = attributes["r"], let position = Self.position(reference) { row = position.row; column = position.column }
                type = attributes["t"] ?? "n"
                format = attributes["s"].flatMap(Int.init) ?? 0
                text = ""
            case "v", "t": inValue = true
            case "col":
                // Width in characters of the default font's digit; about 7 points each, plus padding.
                guard let low = attributes["min"].flatMap(Int.init), let high = attributes["max"].flatMap(Int.init),
                      let width = attributes["width"].flatMap(Double.init), low >= 1, high >= low, high - low < 512 else { break }
                for column in low...high { widths[column - 1] = CGFloat(width * 7 + 5) }
            default: break
            }
        }
        override func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch XLSXReader.local(name) {
            case "v", "t": inValue = false
            case "c":
                var cell = Cell(value: "", format: format, number: nil)
                switch type {
                case "s": cell.value = Int(text).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "b": cell.value = text == "1" ? "TRUE" : "FALSE"
                case "str", "inlineStr", "e", "d": cell.value = text
                default:
                    if let number = Double(text) {
                        cell.number = number
                        cell.value = formatter.display(number, code: styles.formats.indices.contains(format) ? styles.formats[format] : "General")
                    } else {
                        cell.value = text
                    }
                }
                if !cell.value.isEmpty || format != 0 { cells[row, default: [:]][column] = cell }
            default: break
            }
        }
    }
}

// MARK: - Number formats

/// Shows a number the way a cell's Excel number format code asks: `0.00`, `#,##0`, `0%`,
/// `0.00E+00`, currency (`$#,##0.00`, `[$€-407]`), separate sections for negatives and zero,
/// and dates and times (`yyyy-mm-dd`, `mmm d`, `h:mm AM/PM`). What it doesn't model (fractions,
/// conditions) falls back to General. Separators follow the locale, as Excel's do.
final class NumberFormatCode {
    let locale: Locale
    private var numberFormatters: [String: NumberFormatter] = [:]
    private var dateFormatters: [String: DateFormatter] = [:]

    init(locale: Locale = .current) { self.locale = locale }

    /// Excel's built-in formats, by id. Its short date (14) is shown as ISO, which reads the
    /// same everywhere.
    static func builtIn(_ id: Int) -> String {
        switch id {
        case 1: return "0"
        case 2: return "0.00"
        case 3: return "#,##0"
        case 4: return "#,##0.00"
        case 5: return #"$#,##0_);($#,##0)"#
        case 6: return #"$#,##0_);[Red]($#,##0)"#
        case 7: return #"$#,##0.00_);($#,##0.00)"#
        case 8: return #"$#,##0.00_);[Red]($#,##0.00)"#
        case 9: return "0%"
        case 10: return "0.00%"
        case 11: return "0.00E+00"
        case 12, 13: return "General"
        case 14: return "yyyy-mm-dd"
        case 15: return "d-mmm-yy"
        case 16: return "d-mmm"
        case 17: return "mmm-yy"
        case 18: return "h:mm AM/PM"
        case 19: return "h:mm:ss AM/PM"
        case 20: return "hh:mm"
        case 21: return "hh:mm:ss"
        case 22: return "yyyy-mm-dd hh:mm"
        case 37: return "#,##0 ;(#,##0)"
        case 38: return "#,##0 ;[Red](#,##0)"
        case 39: return "#,##0.00;(#,##0.00)"
        case 40: return "#,##0.00;[Red](#,##0.00)"
        case 41: return #"_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)"#
        case 42: return #"_("$"* #,##0_);_("$"* \(#,##0\);_("$"* "-"_);_(@_)"#
        case 43: return #"_(* #,##0.00_);_(* \(#,##0.00\);_(* "-"??_);_(@_)"#
        case 44: return #"_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)"#
        case 45: return "mm:ss"
        case 46: return "[h]:mm:ss"
        case 47: return "mm:ss.0"
        case 48: return "##0.0E+0"
        case 49: return "@"
        default: return "General"
        }
    }

    func display(_ value: Double, code: String) -> String {
        let sections = Self.sections(code)
        var section = sections.first ?? "General"
        var number = value
        var signShown = false
        if value < 0, sections.count > 1 {
            section = sections[1]
            number = -value
            signShown = true
        } else if value == 0, sections.count > 2 {
            section = sections[2]
        }
        let trimmed = section.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if trimmed.lowercased().contains("general") || trimmed == "@" { return general(value) }
        if Self.isDate(section) { return date(number, section) }
        if Self.isFraction(section) { return general(value) }
        return numberText(number, section, negative: !signShown && number < 0)
    }

    /// Splits on `;` outside quotes and escapes.
    static func sections(_ code: String) -> [String] {
        var sections: [String] = [], current = "", quoted = false, escaped = false
        for character in code {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted { sections.append(current); current = ""; continue }
            current.append(character)
        }
        sections.append(current)
        return sections
    }

    /// The code with its quoted text, escapes and bracketed parts (colours, currencies) taken
    /// out, keeping elapsed-time brackets like `[h]`.
    static func bare(_ section: String) -> String {
        var out = "", quoted = false, bracket: String?, skip = false
        for character in section {
            if skip { skip = false; continue }
            if quoted { if character == "\"" { quoted = false }; continue }
            if var open = bracket {
                if character == "]" {
                    if open.lowercased().allSatisfy({ "hms".contains($0) }), !open.isEmpty { out += open }
                    bracket = nil
                } else { open.append(character); bracket = open }
                continue
            }
            switch character {
            case "\"": quoted = true
            case "\\", "_", "*": skip = true
            case "[": bracket = ""
            default: out.append(character)
            }
        }
        return out
    }

    static func isDate(_ section: String) -> Bool {
        let bare = bare(section).lowercased()
        if bare.contains("y") || bare.contains("d") || bare.contains("h") || bare.contains("s") { return true }
        return bare.contains("m") && !bare.contains("0") && !bare.contains("#")
    }

    static func isFraction(_ section: String) -> Bool { bare(section).contains("/") && bare(section).contains("?") }

    func general(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let key = abs(value) >= 1e11 || abs(value) < 1e-9 ? "general-scientific" : "general"
        let formatter = numberFormatters[key] ?? {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = key == "general" ? .decimal : .scientific
            formatter.usesGroupingSeparator = false
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = key == "general" ? 10 : 6
            numberFormatters[key] = formatter
            return formatter
        }()
        return formatter.string(from: value as NSNumber) ?? String(value)
    }

    private func numberText(_ value: Double, _ section: String, negative: Bool) -> String {
        var prefix = "", suffix = "", pattern = "", percent = false
        var seen = false, finished = false
        let characters = Array(section)
        var i = 0
        func literal(_ text: String) { if seen { suffix += text } else { prefix += text } }
        while i < characters.count {
            let character = characters[i]
            switch character {
            case "\"":
                var text = ""
                i += 1
                while i < characters.count, characters[i] != "\"" { text.append(characters[i]); i += 1 }
                literal(text)
            case "\\":
                if i + 1 < characters.count { literal(String(characters[i + 1])); i += 1 }
            case "_", "*":
                i += 1  // padding and fill: nothing to show
            case "[":
                var text = ""
                i += 1
                while i < characters.count, characters[i] != "]" { text.append(characters[i]); i += 1 }
                if text.hasPrefix("$") { literal(String(text.dropFirst().prefix { $0 != "-" })) }
            case "%":
                percent = true
                literal("%")
            case "0", "#", "?":
                if finished { break }
                pattern.append(character)
                seen = true
            case ".":
                let next = i + 1 < characters.count ? characters[i + 1] : " "
                if !finished, seen || "0#?".contains(next) { pattern.append(character); seen = true } else { literal(".") }
            case ",":
                if seen, !finished { pattern.append(character) } else { literal(",") }
            case "E", "e":
                let next = i + 1 < characters.count ? characters[i + 1] : " "
                if seen, !finished, next == "+" || next == "-" {
                    pattern.append("E")
                    i += 1
                } else { literal(String(character)) }
            default:
                if seen { finished = true }
                literal(String(character))
            }
            i += 1
        }
        guard !pattern.isEmpty else { return (negative ? "-" : "") + prefix + suffix }
        var number = abs(value) * (percent ? 100 : 1)
        let parts = pattern.split(separator: "E", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = mantissa[0]
        let fraction = mantissa.count > 1 ? mantissa[1] : ""
        let scaling = integer.reversed().prefix { $0 == "," }.count
        number /= pow(1000, Double(scaling))
        let decimals = fraction.filter { "0#?".contains($0) }.count
        // Only optional digits (`#`, `?`) and nothing to show: a zero shows as nothing.
        if number == 0, !pattern.contains("0") { return prefix + suffix }
        let shown: String
        if parts.count > 1 {
            shown = String(format: "%.\(decimals)E", number)
        } else {
            let key = "\(decimals)|\(fraction.filter { $0 == "0" }.count)|\(integer.dropLast(scaling).contains(","))|\(integer.filter { $0 == "0" }.count)"
            let formatter = numberFormatters[key] ?? {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.roundingMode = .halfUp
                formatter.maximumFractionDigits = decimals
                formatter.minimumFractionDigits = fraction.filter { $0 == "0" }.count
                formatter.usesGroupingSeparator = integer.dropLast(scaling).contains(",")
                formatter.minimumIntegerDigits = integer.filter { $0 == "0" }.count
                numberFormatters[key] = formatter
                return formatter
            }()
            shown = formatter.string(from: number as NSNumber) ?? String(number)
        }
        let negativeShown = negative && shown.contains { "123456789".contains($0) }
        return (negativeShown ? "-" : "") + prefix + shown + suffix
    }

    private enum DateToken {
        case literal(String)
        case code(Character, Int)
        case ampm
        case fraction(Int)
        case elapsed(Character)
    }

    private func date(_ serial: Double, _ section: String) -> String {
        var tokens: [DateToken] = []
        let characters = Array(section)
        var i = 0
        while i < characters.count {
            let character = characters[i]
            let lower = Character(character.lowercased())
            if character == "\"" {
                var text = ""
                i += 1
                while i < characters.count, characters[i] != "\"" { text.append(characters[i]); i += 1 }
                tokens.append(.literal(text))
            } else if character == "\\" {
                if i + 1 < characters.count { tokens.append(.literal(String(characters[i + 1]))); i += 1 }
            } else if character == "_" || character == "*" {
                i += 1
            } else if character == "[" {
                var text = ""
                i += 1
                while i < characters.count, characters[i] != "]" { text.append(characters[i]); i += 1 }
                if let unit = text.lowercased().first, text.lowercased().allSatisfy({ $0 == unit }), "hms".contains(unit) { tokens.append(.elapsed(unit)) }
            } else if String(characters[i...].prefix(5)).uppercased() == "AM/PM" {
                tokens.append(.ampm)
                i += 4
            } else if String(characters[i...].prefix(3)).uppercased() == "A/P" {
                tokens.append(.ampm)
                i += 2
            } else if "ymdhs".contains(lower) {
                var count = 1
                while i + count < characters.count, Character(characters[i + count].lowercased()) == lower { count += 1 }
                tokens.append(.code(lower, count))
                i += count - 1
            } else if character == ".", i + 1 < characters.count, characters[i + 1] == "0", case .code("s", _)? = tokens.last {
                var count = 0
                while i + 1 + count < characters.count, characters[i + 1 + count] == "0" { count += 1 }
                tokens.append(.fraction(count))
                i += count
            } else {
                tokens.append(.literal(String(character)))
            }
            i += 1
        }
        let twelveHour = tokens.contains { if case .ampm = $0 { return true }; return false }
        func codeNear(_ index: Int, step: Int) -> Character? {
            var j = index + step
            while j >= 0, j < tokens.count {
                if case .code(let letter, _) = tokens[j] { return letter }
                if case .elapsed(let unit) = tokens[j] { return unit }
                j += step
            }
            return nil
        }
        func quote(_ text: String) -> String { text.isEmpty ? "" : "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let seconds = (serial * 86_400 * 1000).rounded() / 1000
        var pattern = ""
        for (index, token) in tokens.enumerated() {
            switch token {
            case .literal(let text): pattern += text.allSatisfy({ " -/:.,".contains($0) }) ? text : quote(text)
            case .ampm: pattern += "a"
            case .fraction(let count): pattern += "." + String(repeating: "S", count: count)
            case .elapsed(let unit):
                let total = unit == "h" ? seconds / 3600 : unit == "m" ? seconds / 60 : seconds
                pattern += quote(String(Int(total.rounded(.down))))
            case .code(let letter, let count):
                switch letter {
                case "y": pattern += count <= 2 ? "yy" : "yyyy"
                case "d": pattern += count == 1 ? "d" : count == 2 ? "dd" : count == 3 ? "EEE" : "EEEE"
                case "h": pattern += twelveHour ? (count == 1 ? "h" : "hh") : (count == 1 ? "H" : "HH")
                case "s": pattern += count == 1 ? "s" : "ss"
                default:  // m: minutes after an hour or before seconds, otherwise the month
                    if codeNear(index, step: -1) == "h" || codeNear(index, step: 1) == "s" {
                        pattern += count == 1 ? "m" : "mm"
                    } else {
                        pattern += ["M", "MM", "MMM", "MMMM", "MMMMM"][min(count, 5) - 1]
                    }
                }
            }
        }
        let formatter = dateFormatters[pattern] ?? {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = pattern
            if dateFormatters.count < 64 { dateFormatters[pattern] = formatter }
            return formatter
        }()
        let base = Date(timeIntervalSince1970: -2_209_161_600)  // 1899-12-30
        return formatter.string(from: base.addingTimeInterval(seconds))
    }
}

// MARK: - Colours from a workbook

/// A workbook's colours, fitted to the sheet's light or dark background.
enum SheetColor {
    struct RGB: Equatable {
        var r, g, b: CGFloat
        init(_ value: UInt32) {
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
        }
        init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
        var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        var luminance: CGFloat {
            func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        func blended(over background: RGB, alpha: CGFloat) -> RGB {
            RGB(r: r * alpha + background.r * (1 - alpha), g: g * alpha + background.g * (1 - alpha), b: b * alpha + background.b * (1 - alpha))
        }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> CGFloat {
        let (x, y) = (a.luminance, b.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The same hue at the opposite lightness: dark blue text becomes light blue on dark.
    static func flippedLightness(_ color: RGB) -> RGB {
        var (h, s, l) = hsl(color)
        l = 1 - l
        _ = h; _ = s
        return rgb(h: h, s: s, l: l)
    }

    /// Excel's tint: toward white when positive, toward black when negative, in HSL lightness.
    static func tinted(_ value: UInt32, by tint: Double) -> UInt32 {
        var (h, s, l) = hsl(RGB(value))
        l = tint < 0 ? l * (1 + CGFloat(tint)) : l * (1 - CGFloat(tint)) + CGFloat(tint)
        let out = rgb(h: h, s: s, l: l)
        func byte(_ c: CGFloat) -> UInt32 { UInt32((max(0, min(1, c)) * 255).rounded()) }
        return byte(out.r) << 16 | byte(out.g) << 8 | byte(out.b)
    }

    static func hsl(_ color: RGB) -> (CGFloat, CGFloat, CGFloat) {
        let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b)
        let l = (high + low) / 2
        guard high != low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: CGFloat
        if high == color.r { h = (color.g - color.b) / d + (color.g < color.b ? 6 : 0) }
        else if high == color.g { h = (color.b - color.r) / d + 2 }
        else { h = (color.r - color.g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    static func rgb(h: CGFloat, s: CGFloat, l: CGFloat) -> RGB {
        guard s > 0 else { return RGB(r: l, g: l, b: l) }
        func hue(_ p: CGFloat, _ q: CGFloat, _ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return RGB(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3))
    }

    /// A cell's fill and text colour over `background`. White fills are taken as no fill
    /// (sheets paint white to hide the grid); in dark mode a fill is a wash of its colour, so a
    /// pale header doesn't glare; and a text colour that wouldn't read on what's behind it keeps
    /// its hue at the opposite lightness. Nil text means the sheet's own label colour.
    static func fit(_ style: CellStyle, over background: RGB, dark: Bool) -> (fill: NSColor?, text: NSColor?) {
        var behind = background
        var fill: NSColor?
        if let value = style.fill, value != 0xFFFFFF {
            let alpha: CGFloat = dark ? 0.35 : 1
            behind = RGB(value).blended(over: background, alpha: alpha)
            fill = behind.color
        }
        guard var text = style.color.map(RGB.init) ?? (fill == nil ? nil : (behind.luminance < 0.18 ? RGB(0xFFFFFF) : RGB(0x000000))) else { return (fill, nil) }
        if fill == nil, style.color == 0x000000 { return (nil, nil) }
        if contrast(text, behind) < 3 { text = flippedLightness(text) }
        if contrast(text, behind) < 3 { text = behind.luminance < 0.18 ? RGB(0xFFFFFF) : RGB(0x000000) }
        return (fill, text.color)
    }
}

// MARK: - The sheet view

/// A cell where it's shown: its row in the current order and its column (0 is A).
struct CellRef: Hashable {
    var row: Int
    var column: Int
}

/// A sheet as a spreadsheet: column letters always above each column's title, row numbers
/// down the side, numbers right-aligned in even-width digits, a workbook's own look, sorting
/// by clicking a header. Cells select like a spreadsheet's (click, drag, ⇧-click, the arrow
/// keys; a row number selects its row), and the hovered or selected cell lights its row
/// number and column letter. ⌘C copies the selection as tab-separated cells; the footer
/// shows the size, the selection's reference and its sum, and a tab per sheet. Read-only.
@MainActor
final class SheetView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var number: Int
        var cells: [String]
        var styles: [Int]
        var values: [Double?]
    }

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
    private(set) var header: [String] = []
    private(set) var hasHeader = true
    /// Data rows in the order shown, each with its row number in the file.
    private(set) var rows: [Row] = []
    private var numeric: [Bool] = []
    private var palette: [CellStyle] = [CellStyle()]
    private var widths: [Int: CGFloat] = [:]

    /// The selection runs from the anchor (the active cell) to the focus.
    private(set) var anchor: CellRef?
    private(set) var focus: CellRef?
    private(set) var hovered: CellRef?
    private var selectingRows = false
    private var findMarks: Set<CellRef> = []
    private var findCurrent: CellRef?
    private var sortColumn: (index: Int, ascending: Bool)?

    static let rowNumberColumn = NSUserInterfaceItemIdentifier("sheet.row")
    private let headerView = SheetHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = headerView
        table.style = .fullWidth
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = DS.Color.hairline
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.rowHeight = 23
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.sheet = self
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        table.reloadData()  // a workbook's colours are fitted to the background
    }

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
        // The picker's segments sit close to the card's edge; the count alone gets the text's margin.
        footer.edgeInsets.left = sheetPicker.isHidden ? DS.Spacing.m : 4
        select(sheet: min(current, max(0, sheets.count - 1)))
    }

    /// New contents for the same file: the sheet shown, the sort and the scroll stay.
    func reload(_ sheets: [Sheet]) {
        let sort = sortColumn
        let origin = scrollView.contentView.bounds.origin
        show(sheets)
        if let sort { self.sort(by: sort.index, ascending: sort.ascending) }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func select(sheet index: Int) {
        anchor = nil; focus = nil; hovered = nil; findMarks = []; findCurrent = nil; sortColumn = nil
        guard sheets.indices.contains(index) else { header = []; rows = []; rebuild(); return }
        current = index
        sheetPicker.selectedSegment = index
        let sheet = sheets[index]
        let all = sheet.rows
        let width = all.map(\.count).max() ?? 0
        func padded<T>(_ values: [T], _ blank: T) -> [T] { values + Array(repeating: blank, count: max(0, width - values.count)) }
        hasHeader = sheet.headerRow && !all.isEmpty
        header = hasHeader ? padded(all[0], "") : Array(repeating: "", count: width)
        let first = hasHeader ? 1 : 0
        rows = (first..<max(first, all.count)).map { r in
            Row(number: r + 1, cells: padded(all[r], ""),
                styles: sheet.styleIndex.indices.contains(r) ? padded(sheet.styleIndex[r], 0) : [],
                values: sheet.numbers.indices.contains(r) ? padded(sheet.numbers[r], nil) : [])
        }
        palette = sheet.styles
        widths = sheet.columnWidths
        numeric = (0..<width).map { column in Self.isNumeric(rows.prefix(500).map { $0.cells[column] }, values: rows.prefix(500).map { $0.values.isEmpty ? nil : $0.values[column] }) }
        rebuild()
    }

    @objc private func sheetPicked() { select(sheet: sheetPicker.selectedSegment) }

    /// A number in a cell's text: grouping, currency signs and percent ignored, (12) negative.
    static func number(_ text: String) -> Double? {
        var text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") { negative = true; text = String(text.dropFirst().dropLast()) }
        text = text.filter { !"$€£¥₹,% \u{00A0}".contains($0) }
        guard let value = Double(text) else { return nil }
        return negative ? -value : value
    }

    /// A column of numbers: most of its filled cells are one.
    static func isNumeric(_ cells: [String], values: [Double?] = []) -> Bool {
        var filled = 0, numbers = 0
        for (index, cell) in cells.enumerated() where !cell.trimmingCharacters(in: .whitespaces).isEmpty {
            filled += 1
            if (values.indices.contains(index) ? values[index] : nil) != nil || number(cell) != nil { numbers += 1 }
        }
        return filled > 0 && Double(numbers) >= Double(filled) * 0.8
    }

    private func value(_ row: Row, _ column: Int) -> Double? {
        if !row.values.isEmpty, let value = row.values[column] { return value }
        return Self.number(row.cells[column])
    }

    private func rebuild() {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        if headerView.height != (hasHeader ? 40 : 26) {
            headerView.height = hasHeader ? 40 : 26
            table.tile()
            scrollView.tile()
        }
        let numberColumn = NSTableColumn(identifier: Self.rowNumberColumn)
        numberColumn.headerCell = SheetHeaderCell(letter: "", title: hasHeader ? "1" : "", corner: true)
        numberColumn.width = max(36, CGFloat(String(rows.last?.number ?? 1).count) * 8 + 18)
        numberColumn.resizingMask = []
        table.addTableColumn(numberColumn)
        let font = Self.cellFont
        let sample = rows.prefix(200)
        for (index, title) in header.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sheet.\(index)"))
            let cell = SheetHeaderCell(letter: Self.letter(index), title: title, corner: false)
            cell.alignment = numeric[index] ? .right : .left
            column.headerCell = cell
            column.title = title.isEmpty ? Self.letter(index) : title
            column.headerToolTip = title.isEmpty ? nil : "\(Self.letter(index)) \u{00B7} \(title)"
            if let width = widths[index] {
                column.width = min(480, max(36, width))
            } else {
                let widest = sample.map { ($0.cells[index] as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
                let titleWidth = (title as NSString).size(withAttributes: [.font: DS.Text.body(.medium)]).width
                column.width = min(320, max(64, max(widest, titleWidth) + 28))
            }
            table.addTableColumn(column)
        }
        table.reloadData()
        refreshMarks()
        updateSummary()
    }

    /// Spreadsheet column letters: A … Z, AA ….
    static func letter(_ index: Int) -> String {
        var index = index + 1
        var letters = ""
        while index > 0 { letters = String(UnicodeScalar(UInt8(65 + (index - 1) % 26))) + letters; index = (index - 1) / 26 }
        return letters
    }

    /// "B4": a cell's column letter and its row number in the file.
    func name(of cell: CellRef) -> String {
        Self.letter(cell.column) + (rows.indices.contains(cell.row) ? String(rows[cell.row].number) : "")
    }

    // MARK: Selection

    var selection: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let anchor, let focus else { return nil }
        return (min(anchor.row, focus.row)...max(anchor.row, focus.row), min(anchor.column, focus.column)...max(anchor.column, focus.column))
    }

    func select(_ from: CellRef, to: CellRef? = nil) {
        guard !rows.isEmpty, !header.isEmpty else { return }
        func clamped(_ cell: CellRef) -> CellRef { CellRef(row: min(max(0, cell.row), rows.count - 1), column: min(max(0, cell.column), header.count - 1)) }
        anchor = clamped(from)
        focus = clamped(to ?? from)
        selectionChanged()
        if let focus { scrollToVisible(focus) }
    }

    func selectAllCells() {
        guard !rows.isEmpty, !header.isEmpty else { return }
        anchor = CellRef(row: 0, column: 0)
        focus = CellRef(row: rows.count - 1, column: header.count - 1)
        selectionChanged()
    }

    func scrollToVisible(_ cell: CellRef) {
        table.scrollRowToVisible(cell.row)
        table.scrollColumnToVisible(cell.column + 1)
    }

    /// Where a point in the table falls: a row, and a column (-1 for the row numbers).
    private func hit(_ point: NSPoint) -> (row: Int, column: Int)? {
        let row = table.row(at: point), column = table.column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return (row, column - 1)
    }

    func mouseDown(at point: NSPoint, extend: Bool) {
        guard let hit = hit(point), !header.isEmpty else { return }
        let last = header.count - 1
        selectingRows = hit.column < 0
        if selectingRows {
            if extend, let anchor { self.anchor = CellRef(row: anchor.row, column: 0) } else { anchor = CellRef(row: hit.row, column: 0) }
            focus = CellRef(row: hit.row, column: last)
        } else {
            let cell = CellRef(row: hit.row, column: hit.column)
            if extend, anchor != nil { focus = cell } else { anchor = cell; focus = cell }
        }
        selectionChanged()
    }

    func drag(to point: NSPoint) {
        guard anchor != nil, let hit = hit(point) else { return }
        let cell = selectingRows ? CellRef(row: hit.row, column: header.count - 1) : CellRef(row: hit.row, column: max(0, hit.column))
        guard cell != focus else { return }
        focus = cell
        selectionChanged()
    }

    func hover(at point: NSPoint?) {
        let cell = point.flatMap(hit).flatMap { $0.column >= 0 ? CellRef(row: $0.row, column: $0.column) : nil }
        guard cell != hovered else { return }
        hovered = cell
        refreshMarks()
    }

    /// Arrows move the active cell (⇧ extends, ⌘ goes to the edge), Tab and Return step right
    /// and down, Page Up and Down move a screen, Escape collapses the selection.
    func handleKey(_ event: NSEvent) -> Bool {
        guard !rows.isEmpty, !header.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift), command = flags.contains(.command)
        let page = max(1, Int(scrollView.contentView.bounds.height / (table.rowHeight + table.intercellSpacing.height)) - 1)
        var step: (rows: Int, columns: Int)
        var extend = shift
        switch event.keyCode {
        case 123: step = (0, command ? -header.count : -1)
        case 124: step = (0, command ? header.count : 1)
        case 125: step = (command ? rows.count : 1, 0)
        case 126: step = (command ? -rows.count : -1, 0)
        case 116: step = (-page, 0)
        case 121: step = (page, 0)
        case 115: step = (-rows.count, 0)
        case 119: step = (rows.count, 0)
        case 48: step = (0, shift ? -1 : 1); extend = false
        case 36, 76: step = (shift ? -1 : 1, 0); extend = false
        case 53:
            guard let anchor else { return false }
            select(anchor)
            return true
        default: return false
        }
        guard let anchor, let focus else { select(CellRef(row: 0, column: 0)); return true }
        let from = extend ? focus : anchor
        let to = CellRef(row: from.row + step.rows, column: from.column + step.columns)
        if extend { select(anchor, to: to) } else { select(to) }
        return true
    }

    private func selectionChanged() {
        refreshMarks()
        updateSummary()
    }

    // MARK: Find

    /// Every cell's text in the order shown, row by row, for Find.
    func findableCells() -> [(cell: CellRef, text: String)] {
        var out: [(cell: CellRef, text: String)] = []
        out.reserveCapacity(rows.count * header.count)
        for (r, row) in rows.enumerated() {
            for (c, text) in row.cells.enumerated() { out.append((CellRef(row: r, column: c), text)) }
        }
        return out
    }

    func setFindMarks(_ cells: Set<CellRef>, current: CellRef?) {
        findMarks = cells
        findCurrent = current
        refreshMarks()
    }

    // MARK: Drawing the marks

    var summaryForTesting: String { summary.stringValue }
    /// What a cell is marked as; column -1 is its row number.
    func markForTesting(row: Int, column: Int) -> SheetCellView.Mark { mark(row: row, tableColumn: column + 1, litRows: litRows()) }
    func headerLitForTesting(_ column: Int) -> Bool { (table.tableColumns[column + 1].headerCell as? SheetHeaderCell)?.lit ?? false }

    private func litRows() -> IndexSet {
        var lit = IndexSet()
        if let selection { lit.insert(integersIn: selection.rows) }
        if let hovered { lit.insert(hovered.row) }
        return lit
    }

    private func litColumns() -> IndexSet {
        var lit = IndexSet()
        if let selection { lit.insert(integersIn: selection.columns) }
        if let hovered { lit.insert(hovered.column) }
        return lit
    }

    private func mark(row: Int, tableColumn: Int, litRows: IndexSet) -> SheetCellView.Mark {
        if tableColumn == 0 { return litRows.contains(row) ? .lit : .gutter }
        let cell = CellRef(row: row, column: tableColumn - 1)
        if cell == anchor { return .active }
        if cell == findCurrent { return .foundCurrent }
        if let selection, selection.rows.contains(row), selection.columns.contains(cell.column), anchor != focus { return .range }
        if findMarks.contains(cell) { return .found }
        if cell == hovered { return .hover }
        return .none
    }

    private func refreshMarks() {
        let rowsLit = litRows(), columnsLit = litColumns()
        table.enumerateAvailableRowViews { rowView, row in
            for column in 0..<rowView.numberOfColumns {
                (rowView.view(atColumn: column) as? SheetCellView)?.mark = self.mark(row: row, tableColumn: column, litRows: rowsLit)
            }
        }
        for (index, column) in table.tableColumns.enumerated() {
            guard let cell = column.headerCell as? SheetHeaderCell else { continue }
            cell.lit = index > 0 && columnsLit.contains(index - 1)
            cell.sort = sortColumn?.index == index - 1 ? sortColumn?.ascending : nil
        }
        table.headerView?.needsDisplay = true
    }

    private func updateSummary() {
        var text = "\(rows.count.formatted()) row\(rows.count == 1 ? "" : "s") \u{00B7} \(header.count) column\(header.count == 1 ? "" : "s")"
        if let selection, let anchor, let focus {
            let topLeft = CellRef(row: selection.rows.lowerBound, column: selection.columns.lowerBound)
            let bottomRight = CellRef(row: selection.rows.upperBound, column: selection.columns.upperBound)
            text = anchor == focus ? name(of: anchor) : "\(name(of: topLeft)):\(name(of: bottomRight)) \u{00B7} \((selection.rows.count * selection.columns.count).formatted()) cells"
            var sum = 0.0, count = 0
            if selection.rows.count * selection.columns.count <= 200_000 {
                for r in selection.rows { for c in selection.columns { if let v = value(rows[r], c) { sum += v; count += 1 } } }
            }
            if count > 1 {
                func shown(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...4))) }
                text += " \u{00B7} Sum \(shown(sum)) \u{00B7} Average \(shown(sum / Double(count)))"
            }
        }
        summary.stringValue = text
    }

    /// Even-width digits, so numbers line up down a column.
    static var cellFont: NSFont {
        let base = DS.Text.body()
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    private var background: SheetColor.RGB {
        var resolved = SheetColor.RGB(0xFFFFFF)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = (scrollView.drawsBackground ? scrollView.backgroundColor : table.backgroundColor).usingColorSpace(.sRGB) {
                resolved = SheetColor.RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
            }
        }
        return resolved
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let id = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? SheetCellView ?? {
            let cell = SheetCellView()
            cell.identifier = id
            return cell
        }()
        let field = cell.field
        let data = rows[row]
        let columnIndex = tableView.column(withIdentifier: id)
        if id == Self.rowNumberColumn {
            cell.fill = nil
            field.font = DS.Text.caption()
            field.alignment = .center
            field.textColor = .tertiaryLabelColor
            field.stringValue = String(data.number)
            field.toolTip = nil
        } else if let index = Int(id.rawValue.dropFirst("sheet.".count)) {
            let style = data.styles.isEmpty ? CellStyle() : (palette.indices.contains(data.styles[index]) ? palette[data.styles[index]] : CellStyle())
            let colors = style == CellStyle() ? (fill: nil, text: nil) : SheetColor.fit(style, over: background, dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            cell.fill = colors.fill
            var font = Self.cellFont
            if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            switch style.alignment {
            case .left?: paragraph.alignment = .left
            case .center?: paragraph.alignment = .center
            case .right?: paragraph.alignment = .right
            case nil: paragraph.alignment = numeric[index] ? .right : .left
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.text ?? NSColor.labelColor, .paragraphStyle: paragraph]
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            field.attributedStringValue = NSAttributedString(string: data.cells[index], attributes: attributes)
            field.toolTip = data.cells[index].count > 40 ? data.cells[index] : nil
        }
        cell.mark = mark(row: row, tableColumn: columnIndex, litRows: litRows())
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let index = Int(tableColumn.identifier.rawValue.dropFirst("sheet.".count)), tableColumn.identifier != Self.rowNumberColumn else { return }
        sort(by: index, ascending: sortColumn?.index == index ? !(sortColumn?.ascending ?? false) : true)
    }

    /// Sorts the rows by a column: numbers as numbers, blanks last, ties in file order.
    func sort(by index: Int, ascending: Bool) {
        guard header.indices.contains(index) else { return }
        sortColumn = (index, ascending)
        let asNumbers = numeric[index]
        rows.sort { a, b in
            let x = a.cells[index], y = b.cells[index]
            if x.isEmpty != y.isEmpty { return !x.isEmpty }  // blanks last, either way
            if asNumbers, let p = value(a, index), let q = value(b, index), p != q { return ascending ? p < q : p > q }
            let order = x.localizedStandardCompare(y)
            if order == .orderedSame { return a.number < b.number }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        anchor = nil; focus = nil; findMarks = []; findCurrent = nil
        table.reloadData()
        refreshMarks()
        updateSummary()
    }

    /// The selection as tab-separated text, the header first when every row is selected.
    func copySelection() {
        guard let selection else { return }
        func line(_ cells: some Sequence<String>) -> String { cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
        var lines = hasHeader && selection.rows.count == rows.count ? [line(header[selection.columns])] : []
        lines += selection.rows.map { line(rows[$0].cells[selection.columns]) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// A column's header: its letter, always, over its title; lit while a cell in the column is
/// hovered or selected; and its sort direction.
final class SheetHeaderCell: NSTableHeaderCell {
    let letter: String
    let heading: String
    let corner: Bool
    var lit = false
    var sort: Bool?

    init(letter: String, title: String, corner: Bool) {
        self.letter = letter
        self.heading = title
        self.corner = corner
        super.init(textCell: heading.isEmpty ? letter : title)
    }

    required init(coder: NSCoder) { fatalError() }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let past = (controlView as? NSTableHeaderView)?.tableView.map { $0.column(at: NSPoint(x: cellFrame.midX, y: 0)) < 0 } ?? false
        DS.Color.hairline.setFill()
        NSRect(x: cellFrame.minX, y: (NSGraphicsContext.current?.isFlipped ?? true) ? cellFrame.maxY - 1 : cellFrame.minY, width: cellFrame.width, height: 1).fill()
        // The header view fills the space past the last column with that column's cell; nothing
        // belongs there but the line under the header.
        if past { return }
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if lit {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            cellFrame.fill()
        }
        let inset = cellFrame.insetBy(dx: 8, dy: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = corner ? .center : alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let letterAttributes: [NSAttributedString.Key: Any] = [
            .font: DS.Text.caption(lit ? .bold : .medium), .foregroundColor: lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
        ]
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: corner ? DS.Text.caption() : DS.Text.body(.medium), .foregroundColor: corner ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        var textFrame = inset
        if let sort {
            let symbol = NSImage(systemSymbolName: sort ? "chevron.up" : "chevron.down", accessibilityDescription: sort ? "Sorted ascending" : "Sorted descending")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor])))
            if let symbol {
                let x = alignment == .right ? inset.minX : inset.maxX - symbol.size.width
                symbol.draw(in: NSRect(x: x, y: cellFrame.midY - symbol.size.height / 2 + (heading.isEmpty ? 0 : 7), width: symbol.size.width, height: symbol.size.height))
                if alignment == .right { textFrame.origin.x += symbol.size.width + 4 }
                textFrame.size.width -= symbol.size.width + 4
            }
        }
        let flipped = NSGraphicsContext.current?.isFlipped ?? controlView.isFlipped
        let lineHeight: CGFloat = 16
        if heading.isEmpty {
            (letter as NSString).draw(in: NSRect(x: textFrame.minX, y: cellFrame.midY - lineHeight / 2 + 1, width: textFrame.width, height: lineHeight), withAttributes: letterAttributes)
            return
        }
        let top = NSRect(x: textFrame.minX, y: flipped ? cellFrame.minY + 4 : cellFrame.maxY - 4 - lineHeight, width: textFrame.width, height: lineHeight)
        let bottom = NSRect(x: textFrame.minX, y: flipped ? cellFrame.maxY - 4 - lineHeight - 1 : cellFrame.minY + 5, width: textFrame.width, height: lineHeight + 1)
        (letter as NSString).draw(in: top, withAttributes: letterAttributes)
        (heading as NSString).draw(in: bottom, withAttributes: titleAttributes)
    }
}

/// The header, at the height its two lines need.
final class SheetHeaderView: NSTableHeaderView {
    var height: CGFloat = 40 { didSet { setFrameSize(NSSize(width: frame.width, height: height)) } }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(NSSize(width: newSize.width, height: height)) }
}

/// A cell: a workbook's fill if it has one, then what it's marked as (hovered, selected,
/// found), with the active cell outlined as a spreadsheet's is.
final class SheetCellView: NSTableCellView {
    enum Mark { case none, hover, range, active, found, foundCurrent, gutter, lit }

    let field = NSTextField(labelWithString: "")
    var fill: NSColor? { didSet { if fill != oldValue { needsDisplay = true } } }
    var mark: Mark = .none {
        didSet {
            guard mark != oldValue else { return }
            needsDisplay = true
            if mark == .lit || oldValue == .lit {
                field.textColor = mark == .lit ? .controlAccentColor : .tertiaryLabelColor
                field.font = DS.Text.caption(mark == .lit ? .semibold : .regular)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if let fill { fill.setFill(); bounds.fill() }
        let accent = NSColor.controlAccentColor
        switch mark {
        case .none: break
        case .gutter: DS.Color.scrimSoft.setFill(); bounds.fill()
        case .lit: accent.withAlphaComponent(0.16).setFill(); bounds.fill()
        case .hover: NSColor.labelColor.withAlphaComponent(0.06).setFill(); bounds.fill()
        case .range: accent.withAlphaComponent(0.14).setFill(); bounds.fill()
        case .found: NSColor.findHighlightColor.withAlphaComponent(0.3).setFill(); bounds.fill()
        case .foundCurrent: NSColor.findHighlightColor.withAlphaComponent(0.75).setFill(); bounds.fill()
        case .active:
            accent.withAlphaComponent(0.1).setFill()
            bounds.fill()
            accent.setStroke()
            let ring = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// The sheet's table: cells select rather than rows, hovering is tracked, and ⌘C copies.
final class SheetTableView: NSTableView {
    var onCopy: (() -> Void)?
    weak var sheet: SheetView?
    private var hoverArea: NSTrackingArea?

    @objc func copy(_ sender: Any?) { onCopy?() }
    override func selectAll(_ sender: Any?) { sheet?.selectAllCells() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { sheet?.hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { sheet?.hover(at: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sheet?.mouseDown(at: convert(event.locationInWindow, from: nil), extend: event.modifierFlags.contains(.shift))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            sheet?.drag(to: convert(next.locationInWindow, from: nil))
        }
    }

    override func keyDown(with event: NSEvent) {
        if sheet?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
