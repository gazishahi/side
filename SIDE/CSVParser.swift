import Foundation

enum CSVParser {
    /// Handles quoted fields, commas/newlines inside quotes, and escaped `""` quotes —
    /// a naive `components(separatedBy: ",")` breaks on any of those.
    static func parse(_ text: String) -> [[String]] {
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
                case ",":
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
