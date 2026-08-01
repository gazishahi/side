import Foundation

// MARK: - Outgoing (Encodable) — only the fields the servers we target require.

struct LSPPosition: Codable {
    let line: Int
    let character: Int
}

struct LSPRange: Codable {
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

struct TextDocumentContentChangeEvent: Encodable {
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
}

struct InitializeParams<Options: Encodable>: Encodable {
    let processId: Int?
    let rootUri: String?
    let capabilities: [String: String]
    let initializationOptions: Options?

    init(processId: Int?, rootUri: String?, initializationOptions: Options? = nil) {
        self.processId = processId
        self.rootUri = rootUri
        self.capabilities = [:]
        self.initializationOptions = initializationOptions
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

struct LSPCompletionItem: Decodable {
    let label: String
    let insertText: String?
    let detail: String?
}

/// Servers respond to textDocument/completion with either a bare CompletionItem[] or this
/// wrapper object — the caller tries both shapes.
struct LSPCompletionList: Decodable {
    let items: [LSPCompletionItem]
}
