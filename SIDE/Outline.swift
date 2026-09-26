import AlloyCore
import AlloySyntax
import AppKit

/// One entry of a file's outline (Go to Symbol, ⇧⌘O): from its language server's
/// `documentSymbol`, or from the syntax tree where there's none (SIDE_RFC_IDE_ESSENTIALS.md, L3).
struct OutlineSymbol: Sendable, Equatable {
    let name: String
    /// The server's detail (a signature, a type), or nothing.
    let detail: String?
    let kind: SyntaxSymbol.Kind
    /// Where its name is (what Go to Symbol selects), and the line it's on (zero-based).
    let nameRange: NSRange
    let line: Int
    /// How deep it's nested, and what it's in.
    let depth: Int
    let container: String?
}

/// A server's document symbols, read off the main thread before there's a rope to count in.
struct LSPDocumentSymbol: Sendable {
    let name: String
    let detail: String?
    let kind: Int
    let selection: LSPRange
    let container: String?
    let children: [LSPDocumentSymbol]

    /// DocumentSymbol[] (nested) or SymbolInformation[] (flat, with a container name).
    static func list(_ result: LSPResult?) -> [LSPDocumentSymbol]? {
        guard let array = result?.array else { return nil }
        return array.compactMap(parse)
    }

    private static func parse(_ value: Any) -> LSPDocumentSymbol? {
        guard let object = value as? [String: Any], let name = object["name"] as? String, let kind = object["kind"] as? Int else { return nil }
        if let selection = LSPRange(object["selectionRange"]) ?? LSPRange(object["range"]) {
            let children = (object["children"] as? [Any] ?? []).compactMap(parse)
            return LSPDocumentSymbol(name: name, detail: (object["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }, kind: kind,
                                     selection: selection, container: nil, children: children)
        }
        guard let location = object["location"] as? [String: Any], let range = LSPRange(location["range"]) else { return nil }
        return LSPDocumentSymbol(name: name, detail: nil, kind: kind, selection: range, container: object["containerName"] as? String, children: [])
    }
}

enum Outline {
    /// The server's symbols as an outline, in document order, counted in `rope`.
    static func from(_ symbols: [LSPDocumentSymbol], rope: Rope) -> [OutlineSymbol] {
        var out: [OutlineSymbol] = []
        func add(_ list: [LSPDocumentSymbol], depth: Int, container: String?) {
            let ordered = list.sorted { ($0.selection.start.line, $0.selection.start.character) < ($1.selection.start.line, $1.selection.start.character) }
            for symbol in ordered {
                let a = rope.offset(line: symbol.selection.start.line, column: symbol.selection.start.character)
                let b = rope.offset(line: symbol.selection.end.line, column: symbol.selection.end.character)
                out.append(OutlineSymbol(name: symbol.name, detail: symbol.detail, kind: kind(lsp: symbol.kind), nameRange: NSRange(location: a, length: max(0, b - a)),
                                         line: symbol.selection.start.line, depth: depth, container: symbol.container ?? container))
                add(symbol.children, depth: depth + 1, container: symbol.name)
            }
        }
        add(symbols, depth: 0, container: nil)
        return out
    }

    /// The syntax tree's symbols as an outline.
    static func from(_ symbols: [SyntaxSymbol], rope: Rope) -> [OutlineSymbol] {
        var out: [OutlineSymbol] = []
        func add(_ list: [SyntaxSymbol], depth: Int, container: String?) {
            for symbol in list {
                out.append(OutlineSymbol(name: symbol.name, detail: nil, kind: symbol.kind,
                                         nameRange: NSRange(location: symbol.nameRange.lowerBound, length: symbol.nameRange.count),
                                         line: rope.line(containing: symbol.nameRange.lowerBound), depth: depth, container: container))
                add(symbol.children, depth: depth + 1, container: symbol.name)
            }
        }
        add(symbols, depth: 0, container: nil)
        return out
    }

    /// LSP's SymbolKind as the outline's.
    static func kind(lsp: Int) -> SyntaxSymbol.Kind {
        switch lsp {
        case 1, 2, 3, 4: return .module
        case 5: return .class
        case 6: return .method
        case 7, 8: return .property
        case 9: return .constructor
        case 10: return .enum
        case 11: return .interface
        case 12, 25: return .function
        case 13: return .variable
        case 14, 22: return .constant
        case 15, 16, 17, 18, 19, 20, 21: return .key
        case 23: return .struct
        case 26: return .type
        default: return .variable
        }
    }

    /// The letter-in-a-square Xcode's navigators use, by kind.
    static func icon(_ kind: SyntaxSymbol.Kind) -> NSImage? {
        let name: String
        switch kind {
        case .class: name = "c.square"
        case .struct: name = "s.square"
        case .enum: name = "e.square"
        case .interface, .protocol: name = "p.square"
        case .extension: name = "x.square"
        case .function, .method, .constructor: name = "f.square"
        case .property, .variable: name = "v.square"
        case .constant: name = "k.square"
        case .module: name = "m.square"
        case .type: name = "t.square"
        case .heading: name = "number"
        case .key: name = "key"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: kind.rawValue)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }

    static func color(_ kind: SyntaxSymbol.Kind) -> NSColor {
        switch kind {
        case .class, .struct, .enum, .interface, .protocol, .extension, .type: return .systemPurple
        case .function, .method, .constructor: return .systemBlue
        case .property, .variable: return .systemTeal
        case .constant: return .systemOrange
        case .module: return .systemBrown
        case .heading, .key: return .secondaryLabelColor
        }
    }
}
