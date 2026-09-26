import Foundation
import Heron

// MARK: - Outgoing (Encodable) — only the fields the servers we target require.

struct LSPPosition: Codable, Sendable, Equatable {
    let line: Int
    let character: Int
}

struct LSPRange: Codable, Sendable, Equatable {
    let start: LSPPosition
    let end: LSPPosition
}

struct TextDocumentIdentifier: Encodable {
    let uri: String
}

struct VersionedTextDocumentIdentifier: Encodable {
    let uri: String
    let version: Int
}

struct TextDocumentItem: Encodable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

struct DidOpenTextDocumentParams: Encodable {
    let textDocument: TextDocumentItem
}

/// One change to a document: `range` in the text as it was just before (LSP positions,
/// UTF-16), or the whole text when `range` is nil (a server that asked for full sync).
struct TextDocumentContentChangeEvent: Encodable, Sendable, Equatable {
    var range: LSPRange?
    let text: String
}

struct DidChangeTextDocumentParams: Encodable {
    let textDocument: VersionedTextDocumentIdentifier
    let contentChanges: [TextDocumentContentChangeEvent]
}

struct DidCloseTextDocumentParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

struct DefinitionParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: LSPPosition
}

struct CompletionParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: LSPPosition
    let context: CompletionContext
}

/// Why completion was asked for: 1 typed or invoked (⌃Space), 2 a trigger character, 3 to
/// re-ask about an incomplete list.
struct CompletionContext: Encodable, Sendable {
    let triggerKind: Int
    var triggerCharacter: String?
}

struct DidSaveTextDocumentParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

struct CancelParams: Encodable {
    let id: Int
}

struct InitializeParams<Options: Encodable>: Encodable {
    let processId: Int?
    let rootUri: String?
    let capabilities: LSPValue
    let initializationOptions: Options?
    let clientInfo: LSPValue = ["name": "Side"]

    init(processId: Int?, rootUri: String?, initializationOptions: Options? = nil) {
        self.processId = processId
        self.rootUri = rootUri
        self.capabilities = Self.clientCapabilities
        self.initializationOptions = initializationOptions
    }

    /// What Side reads, so a server sends it: incremental sync with saves, completion with
    /// snippets off until Alloy has placeholders (step 2), `resolve` for documentation and
    /// edits, markdown or plain documentation, diagnostics, definition, UTF-16 positions
    /// (Alloy's own unit), and the workspace requests Side answers.
    static var clientCapabilities: LSPValue {
        [
            "general": ["positionEncodings": ["utf-16"]],
            "textDocument": [
                "synchronization": ["didSave": true, "dynamicRegistration": false],
                "completion": [
                    "completionItem": [
                        "snippetSupport": false,
                        "insertReplaceSupport": true,
                        "labelDetailsSupport": true,
                        "documentationFormat": ["markdown", "plaintext"],
                        "resolveSupport": ["properties": ["documentation", "detail", "additionalTextEdits"]],
                    ],
                    "completionItemKind": ["valueSet": .array((1...25).map { .int($0) })],
                    "contextSupport": true,
                ],
                "definition": ["linkSupport": true],
                "formatting": ["dynamicRegistration": false],
                "publishDiagnostics": ["relatedInformation": false],
            ],
            "workspace": [
                "configuration": true,
                "workspaceFolders": false,
                "applyEdit": false,
            ],
            "window": ["workDoneProgress": true],
        ]
    }
}

/// What a server said it does, from its `initialize` reply: the part Side acts on.
struct LSPServerCapabilities: Sendable, Equatable {
    /// 0 none, 1 whole text, 2 incremental.
    var syncKind = 1
    var completionTriggers: Set<String> = []
    var completionResolves = false
    var formats = false

    init() {}

    init(initializeResult result: LSPResult?) {
        guard let capabilities = result?.object?["capabilities"] as? [String: Any] else { return }
        if let kind = capabilities["textDocumentSync"] as? Int {
            syncKind = kind
        } else if let sync = capabilities["textDocumentSync"] as? [String: Any] {
            syncKind = sync["change"] as? Int ?? 0
        }
        formats = capabilities["documentFormattingProvider"] is [String: Any] || capabilities["documentFormattingProvider"] as? Bool == true
        if let completion = capabilities["completionProvider"] as? [String: Any] {
            completionTriggers = Set(completion["triggerCharacters"] as? [String] ?? [])
            completionResolves = completion["resolveProvider"] as? Bool ?? false
        }
    }
}

/// typescript-language-server ignores a global npm "typescript" install unless explicitly
/// pointed at it this way — see LanguageServerRegistry.tsserverPathOverride.
struct TSServerPathOption: Encodable {
    let path: String
}

struct TSServerInitializationOptions: Encodable {
    let tsserver: TSServerPathOption
}

// MARK: - Incoming (Decodable)

enum LSPDiagnosticSeverity: Int, Decodable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

struct LSPDiagnostic: Decodable {
    let range: LSPRange
    let severity: LSPDiagnosticSeverity?
    let message: String
    let source: String?
}

struct PublishDiagnosticsParams: Decodable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}

struct LSPLocation: Decodable {
    let uri: String
    let range: LSPRange
}

/// Some servers respond to textDocument/definition with LocationLink instead of Location.
struct LSPLocationLink: Decodable {
    let targetUri: String
    let targetRange: LSPRange
}

struct LSPTextEdit: Sendable, Equatable {
    let range: LSPRange
    let newText: String

    init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    init?(_ object: Any?) {
        guard let object = object as? [String: Any], let range = LSPRange(object["range"]),
              let text = object["newText"] as? String else { return nil }
        self.init(range: range, newText: text)
    }
}

extension LSPPosition {
    init?(_ object: Any?) {
        guard let object = object as? [String: Any], let line = object["line"] as? Int,
              let character = object["character"] as? Int else { return nil }
        self.init(line: line, character: character)
    }
}

extension LSPRange {
    init?(_ object: Any?) {
        guard let object = object as? [String: Any], let start = LSPPosition(object["start"]),
              let end = LSPPosition(object["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

/// One completion item, read straight from the parsed reply (no second decode). The server's
/// own object is kept, since `completionItem/resolve` sends it back as it came.
struct LSPCompletionItem: Sendable {
    let label: String
    /// `labelDetails`: a signature after the label, a module or type after that.
    var labelDetail: String?
    var labelDescription: String?
    var kind: Int?
    var detail: String?
    var documentation: String?
    var sortText: String?
    var filterText: String?
    var insertText: String?
    /// A replacement the server chose. For an insert-or-replace edit, `range` is the replace
    /// range and `insertRange` the part before the caret.
    var textEdit: LSPTextEdit?
    var insertRange: LSPRange?
    var additionalTextEdits: [LSPTextEdit] = []
    /// 2 is a snippet (not asked for until step 2, but some servers send them anyway).
    var insertTextFormat: Int?
    var preselect = false
    let raw: LSPValue

    init(label: String, kind: Int? = nil, detail: String? = nil, sortText: String? = nil, filterText: String? = nil, insertText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.sortText = sortText
        self.filterText = filterText
        self.insertText = insertText
        raw = ["label": .string(label)]
    }

    init?(_ object: Any) {
        guard let object = object as? [String: Any], let label = object["label"] as? String else { return nil }
        self.label = label
        raw = LSPValue(any: object)
        merge(object)
    }

    /// Fields a `resolve` reply filled in; what it leaves out stays.
    mutating func merge(_ object: [String: Any]) {
        if let details = object["labelDetails"] as? [String: Any] {
            labelDetail = details["detail"] as? String ?? labelDetail
            labelDescription = details["description"] as? String ?? labelDescription
        }
        kind = object["kind"] as? Int ?? kind
        detail = object["detail"] as? String ?? detail
        if let doc = object["documentation"] as? String { documentation = doc }
        else if let doc = object["documentation"] as? [String: Any], let value = doc["value"] as? String { documentation = value }
        sortText = object["sortText"] as? String ?? sortText
        filterText = object["filterText"] as? String ?? filterText
        insertText = object["insertText"] as? String ?? insertText
        insertTextFormat = object["insertTextFormat"] as? Int ?? insertTextFormat
        preselect = object["preselect"] as? Bool ?? preselect
        if let edit = object["textEdit"] as? [String: Any] {
            if let replace = LSPRange(edit["replace"]), let text = edit["newText"] as? String {
                textEdit = LSPTextEdit(range: replace, newText: text)
                insertRange = LSPRange(edit["insert"])
            } else if let plain = LSPTextEdit(edit) {
                textEdit = plain
            }
        }
        if let extra = object["additionalTextEdits"] as? [Any] {
            additionalTextEdits = extra.compactMap { LSPTextEdit($0) }
        }
    }

    /// What the list matches typing against.
    var matchText: String { filterText ?? label }
}

/// A completion reply: a bare CompletionItem[] or a CompletionList.
struct LSPCompletionList: Sendable {
    var items: [LSPCompletionItem]
    /// The server didn't send everything: typing more should ask again, not filter.
    var isIncomplete: Bool

    init(items: [LSPCompletionItem], isIncomplete: Bool) {
        self.items = items
        self.isIncomplete = isIncomplete
    }

    init(_ result: LSPResult?) {
        if let array = result?.array {
            self.init(items: array.compactMap(LSPCompletionItem.init), isIncomplete: false)
        } else if let object = result?.object, let array = object["items"] as? [Any] {
            // `itemDefaults` (LSP 3.17): an edit range and format shared by every item.
            var items = array.compactMap(LSPCompletionItem.init)
            if let defaults = object["itemDefaults"] as? [String: Any], let range = defaults["editRange"] {
                let replace = LSPRange(range) ?? LSPRange((range as? [String: Any])?["replace"])
                let insert = LSPRange((range as? [String: Any])?["insert"])
                if let replace {
                    for index in items.indices where items[index].textEdit == nil {
                        items[index].textEdit = LSPTextEdit(range: replace, newText: items[index].insertText ?? items[index].label)
                        items[index].insertRange = insert
                    }
                }
            }
            self.init(items: items, isIncomplete: object["isIncomplete"] as? Bool ?? false)
        } else {
            self.init(items: [], isIncomplete: false)
        }
    }
}
