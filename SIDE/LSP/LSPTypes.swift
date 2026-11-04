import Foundation
import SideAgents

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
    /// snippets (Alloy's tab stops), `resolve` for documentation and
    /// edits, markdown or plain documentation, diagnostics, definition, UTF-16 positions
    /// (Alloy's own unit), and the workspace requests Side answers.
    static var clientCapabilities: LSPValue {
        [
            "general": ["positionEncodings": ["utf-16"]],
            "textDocument": [
                "synchronization": ["didSave": true, "dynamicRegistration": false],
                "completion": [
                    "completionItem": [
                        "snippetSupport": true,
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
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "references": ["dynamicRegistration": false],
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true, "symbolKind": ["valueSet": .array((1...26).map { .int($0) })]],
                "rangeFormatting": ["dynamicRegistration": false],
                "rename": ["prepareSupport": true],
                "codeAction": [
                    "codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports", "source.fixAll"]]],
                    "isPreferredSupport": true,
                    "disabledSupport": true,
                    "dataSupport": true,
                    "resolveSupport": ["properties": ["edit"]],
                ],
                "signatureHelp": [
                    "signatureInformation": [
                        "documentationFormat": ["markdown", "plaintext"],
                        "parameterInformation": ["labelOffsetSupport": true],
                        "activeParameterSupport": true,
                    ],
                    "contextSupport": true,
                ],
                "publishDiagnostics": ["relatedInformation": false],
            ],
            "workspace": [
                "configuration": true,
                "workspaceFolders": false,
                "applyEdit": true,
                "workspaceEdit": ["documentChanges": true],
                "executeCommand": ["dynamicRegistration": false],
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
    var hovers = false
    var findsReferences = false
    var documentSymbols = false
    var formatsRanges = false
    var renames = false
    var preparesRename = false
    var codeActions = false
    var resolvesCodeActions = false
    /// The characters that open signature help, and those that update it while it's up.
    var signatureHelp: (triggers: Set<String>, retriggers: Set<String>)?

    init() {}

    static func == (a: Self, b: Self) -> Bool {
        a.syncKind == b.syncKind && a.completionTriggers == b.completionTriggers && a.completionResolves == b.completionResolves
            && a.formats == b.formats && a.hovers == b.hovers && a.findsReferences == b.findsReferences && a.documentSymbols == b.documentSymbols && a.formatsRanges == b.formatsRanges
            && a.renames == b.renames && a.preparesRename == b.preparesRename && a.codeActions == b.codeActions && a.resolvesCodeActions == b.resolvesCodeActions
            && a.signatureHelp?.triggers == b.signatureHelp?.triggers && a.signatureHelp?.retriggers == b.signatureHelp?.retriggers
    }

    init(initializeResult result: LSPResult?) {
        guard let capabilities = result?.object?["capabilities"] as? [String: Any] else { return }
        if let kind = capabilities["textDocumentSync"] as? Int {
            syncKind = kind
        } else if let sync = capabilities["textDocumentSync"] as? [String: Any] {
            syncKind = sync["change"] as? Int ?? 0
        }
        formats = capabilities["documentFormattingProvider"] is [String: Any] || capabilities["documentFormattingProvider"] as? Bool == true
        hovers = capabilities["hoverProvider"] is [String: Any] || capabilities["hoverProvider"] as? Bool == true
        findsReferences = capabilities["referencesProvider"] is [String: Any] || capabilities["referencesProvider"] as? Bool == true
        documentSymbols = capabilities["documentSymbolProvider"] is [String: Any] || capabilities["documentSymbolProvider"] as? Bool == true
        formatsRanges = capabilities["documentRangeFormattingProvider"] is [String: Any] || capabilities["documentRangeFormattingProvider"] as? Bool == true
        renames = capabilities["renameProvider"] is [String: Any] || capabilities["renameProvider"] as? Bool == true
        preparesRename = (capabilities["renameProvider"] as? [String: Any])?["prepareProvider"] as? Bool == true
        codeActions = capabilities["codeActionProvider"] is [String: Any] || capabilities["codeActionProvider"] as? Bool == true
        resolvesCodeActions = (capabilities["codeActionProvider"] as? [String: Any])?["resolveProvider"] as? Bool == true
        if let signature = capabilities["signatureHelpProvider"] as? [String: Any] {
            signatureHelp = (Set(signature["triggerCharacters"] as? [String] ?? []), Set(signature["retriggerCharacters"] as? [String] ?? []))
        }
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
    /// The server's own object, sent back as it came when asking for its fixes.
    var raw: LSPValue? = nil

    enum CodingKeys: String, CodingKey { case range, severity, message, source }
}

struct PublishDiagnosticsParams: Decodable {
    let uri: String
    var diagnostics: [LSPDiagnostic]
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

/// Documentation as a server sends it (MarkupContent, a MarkedString, or a list of them), as
/// Markdown.
enum LSPMarkup {
    static func markdown(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let object as [String: Any]:
            if let language = object["language"] as? String, let code = object["value"] as? String {
                return code.isEmpty ? nil : "```\(language)\n\(code)\n```"
            }
            return (object["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case let array as [Any]:
            let parts = array.compactMap { markdown($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        default: return nil
        }
    }
}

/// A hover's contents, as Markdown.
struct LSPHover: Sendable {
    let markdown: String

    init?(_ result: LSPResult?) {
        guard let markdown = LSPMarkup.markdown(result?.object?["contents"]) else { return nil }
        self.markdown = markdown
    }
}

/// The signatures that fit the call being typed, and which parameter the caret is on.
struct LSPSignatureHelp: Sendable, Equatable {
    struct Parameter: Sendable, Equatable {
        /// Where it is in its signature's label (UTF-16).
        var range: Range<Int>?
        var documentation: String?
    }
    struct Signature: Sendable, Equatable {
        var label: String
        var documentation: String?
        var parameters: [Parameter]
        var activeParameter: Int?
    }
    var signatures: [Signature]
    var activeSignature: Int
    var activeParameter: Int

    init(signatures: [Signature], activeSignature: Int, activeParameter: Int) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }

    init?(_ result: LSPResult?) {
        guard let object = result?.object, let list = object["signatures"] as? [[String: Any]], !list.isEmpty else { return nil }
        signatures = list.compactMap { signature in
            guard let label = signature["label"] as? String else { return nil }
            let parameters = (signature["parameters"] as? [[String: Any]] ?? []).map { parameter -> Parameter in
                var range: Range<Int>?
                if let offsets = parameter["label"] as? [Int], offsets.count == 2, offsets[0] >= 0, offsets[0] <= offsets[1] {
                    range = offsets[0]..<offsets[1]
                } else if let text = parameter["label"] as? String {
                    let found = (label as NSString).range(of: text)
                    if found.location != NSNotFound { range = found.location..<NSMaxRange(found) }
                }
                return Parameter(range: range, documentation: LSPMarkup.markdown(parameter["documentation"]))
            }
            return Signature(label: label, documentation: LSPMarkup.markdown(signature["documentation"]),
                             parameters: parameters, activeParameter: signature["activeParameter"] as? Int)
        }
        guard !signatures.isEmpty else { return nil }
        activeSignature = min(max(0, object["activeSignature"] as? Int ?? 0), signatures.count - 1)
        activeParameter = object["activeParameter"] as? Int ?? 0
    }

    var current: Signature { signatures[activeSignature] }
    /// The parameter the caret is on: the signature's own say first, then the reply's.
    var currentParameter: Int { current.activeParameter ?? activeParameter }
}

/// Changes to files a server asks for (a rename, a fix): per file, edits in that file's text
/// as it is now. Creating, renaming and deleting files aren't applied; they're counted.
struct LSPWorkspaceEdit: Sendable {
    var files: [(uri: String, edits: [LSPTextEdit])]
    var unsupported: Int
    /// The document version each file's edits were computed against, when the server said
    /// (`documentChanges`): an open file at another version has changed since (EDT-6).
    var versions: [String: Int] = [:]

    init(files: [(uri: String, edits: [LSPTextEdit])], unsupported: Int = 0) {
        self.files = files
        self.unsupported = unsupported
    }

    init?(_ value: Any?) {
        guard let object = value as? [String: Any] else { return nil }
        var files: [(String, [LSPTextEdit])] = []
        var unsupported = 0
        var versions: [String: Int] = [:]
        if let changes = object["documentChanges"] as? [[String: Any]] {
            for change in changes {
                if let document = change["textDocument"] as? [String: Any], let uri = document["uri"] as? String,
                   let edits = change["edits"] as? [Any] {
                    files.append((uri, edits.compactMap { LSPTextEdit($0) }))
                    if let version = document["version"] as? Int { versions[uri] = version }
                } else {
                    unsupported += 1
                }
            }
        } else if let changes = object["changes"] as? [String: [Any]] {
            for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) { files.append((uri, edits.compactMap { LSPTextEdit($0) })) }
        }
        self.files = files.filter { !$0.1.isEmpty }
        self.unsupported = unsupported
        self.versions = versions
    }

    var editCount: Int { files.reduce(0) { $0 + $1.edits.count } }
}

/// A fix or refactoring a server offers at the caret.
struct LSPCodeAction: Sendable {
    let title: String
    var kind: String?
    var isPreferred = false
    var disabledReason: String?
    var edit: LSPWorkspaceEdit?
    /// A command the server runs itself (it may send back `workspace/applyEdit`).
    var command: (name: String, arguments: LSPValue)?
    let raw: LSPValue

    init?(_ value: Any) {
        guard let object = value as? [String: Any], let title = object["title"] as? String else { return nil }
        self.title = title
        raw = LSPValue(any: object)
        if let name = object["command"] as? String {
            // A bare Command.
            command = (name, LSPValue(any: object["arguments"]))
            return
        }
        kind = object["kind"] as? String
        isPreferred = object["isPreferred"] as? Bool ?? false
        disabledReason = (object["disabled"] as? [String: Any])?["reason"] as? String
        edit = LSPWorkspaceEdit(object["edit"])
        if let command = object["command"] as? [String: Any], let name = command["command"] as? String {
            self.command = (name, LSPValue(any: command["arguments"]))
        }
    }

    var isQuickFix: Bool { kind?.hasPrefix("quickfix") ?? false }
}
