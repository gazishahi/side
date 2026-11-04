import AlloyCore
import Foundation
import SideAgents

/// A request's handle: cancelling it before it's sent drops it from the queue; after, the
/// client tells the server (`$/cancelRequest`) and answers the caller with nil at once.
final class LSPRequestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var sentID: Int?

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    /// The JSON-RPC id it went out with, once it has.
    var id: Int? {
        get { lock.withLock { sentID } }
        set { lock.withLock { sentID = newValue } }
    }
}

/// One message bound for a language server, in the order the editor produced it.
enum LSPOutboundOp: Sendable {
    case didOpen(uri: String, languageId: String, text: String, version: Int)
    /// The edits since the last one, and the text after them for a server that syncs whole.
    case didChange(uri: String, changes: [TextDocumentContentChangeEvent], text: Rope, version: Int)
    case didSave(uri: String)
    case didClose(uri: String)
    /// Requests carry their reply, called on the client's actor with the parsed `result`;
    /// `nil` means no answer (not running, an error, or cancelled).
    case completion(uri: String, position: LSPPosition, context: CompletionContext, token: LSPRequestToken, reply: @Sendable (LSPResult?) -> Void)
    case resolve(item: LSPValue, uri: String, token: LSPRequestToken, reply: @Sendable (LSPResult?) -> Void)
    case definition(uri: String, position: LSPPosition, reply: @Sendable (LSPResult?) -> Void)
    case formatting(uri: String, tabSize: Int, insertSpaces: Bool, reply: @Sendable (LSPResult?) -> Void)
    case signatureHelp(uri: String, position: LSPPosition, context: LSPValue, token: LSPRequestToken, reply: @Sendable (LSPResult?) -> Void)
    case hover(uri: String, position: LSPPosition, token: LSPRequestToken, reply: @Sendable (LSPResult?) -> Void)
    /// References, prepareRename, rename, codeAction, codeAction/resolve and executeCommand:
    /// requests whose parameters are written out here.
    case request(method: String, uri: String, params: LSPValue, token: LSPRequestToken, reply: @Sendable (LSPResult?) -> Void)
    case cancel(LSPRequestToken, uri: String)

    /// The document this op is about, for deciding what a replay supersedes.
    var uri: String {
        switch self {
        case .didOpen(let uri, _, _, _), .didChange(let uri, _, _, _), .didSave(let uri), .didClose(let uri),
             .completion(let uri, _, _, _, _), .resolve(_, let uri, _, _), .definition(let uri, _, _), .formatting(let uri, _, _, _), .signatureHelp(let uri, _, _, _, _), .hover(let uri, _, _, _), .request(_, let uri, _, _, _), .cancel(_, let uri):
            return uri
        }
    }

    /// True for what a respawned server has no use for: document sync (a later `didOpen`
    /// carries the current text) and cancelling a request the old server had.
    var isDocumentSync: Bool {
        switch self {
        case .didOpen, .didChange, .didSave, .didClose, .cancel: return true
        case .completion, .resolve, .definition, .formatting, .signatureHelp, .hover, .request: return false
        }
    }

    /// A request its caller no longer wants.
    var isCancelled: Bool {
        switch self {
        case .completion(_, _, _, let token, _), .resolve(_, _, let token, _), .signatureHelp(_, _, _, let token, _), .hover(_, _, let token, _), .request(_, _, _, let token, _): return token.isCancelled
        default: return false
        }
    }

    /// Answers a request that will never reach a server.
    func fail() {
        switch self {
        case .completion(_, _, _, _, let reply), .resolve(_, _, _, let reply), .definition(_, _, let reply), .formatting(_, _, _, let reply),
             .signatureHelp(_, _, _, _, let reply), .hover(_, _, _, let reply), .request(_, _, _, _, let reply): reply(nil)
        case .didOpen, .didChange, .didSave, .didClose, .cancel: break
        }
    }
}

/// A FIFO of messages for one language server, sent one at a time, in order.
///
/// Before this, every `didChange` was its own unstructured `Task`, and two of them could reach
/// the server transposed — version 5 before version 4 — leaving the server's copy of the file
/// permanently behind the editor's, so diagnostics underlined the wrong lines and completions
/// answered old text. The "flush a didChange before asking for completions" fix was racy by
/// construction for the same reason: the flush and the request were two Tasks with no ordering
/// between them. Found by the 2026-09-01 audit.
///
/// `enqueue` is synchronous on the main actor, which is where the editor produces these in order;
/// one drain loop awaits each send to completion before starting the next. Requests are awaited
/// only to the *write*, never to the reply, so a slow completion doesn't stall the typing behind it.
///
/// Starts paused: a server takes a while to spawn, and until it is up there is nothing to send to.
/// `pause` is also how a crashed server's queue is frozen so `LSPManager` can rebuild it with a
/// `didOpen` replay in front — see `LSPManager.respawnOps`.
@MainActor
final class LSPOutboundQueue {
    private var pending: [LSPOutboundOp] = []
    private var isDraining = false
    private(set) var isPaused = true
    private var isClosed = false
    private let send: @Sendable (LSPOutboundOp) async -> Void

    init(send: @escaping @Sendable (LSPOutboundOp) async -> Void) {
        self.send = send
    }

    func enqueue(_ op: LSPOutboundOp) {
        guard !isClosed else { op.fail(); return }
        pending.append(op)
        drainIfNeeded()
    }

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        drainIfNeeded()
    }

    /// Everything not yet sent, removed from the queue. Only meaningful while paused.
    func takePending() -> [LSPOutboundOp] {
        let taken = pending
        pending.removeAll()
        return taken
    }

    /// Fails every waiting request and refuses new work. Used at teardown.
    func close() {
        isClosed = true
        for op in pending { op.fail() }
        pending.removeAll()
    }

    private func drainIfNeeded() {
        guard !isDraining, !isPaused, !isClosed else { return }
        isDraining = true
        Task { @MainActor [weak self] in
            defer { self?.isDraining = false }
            while let self, !self.isPaused, !self.isClosed, !self.pending.isEmpty {
                let op = self.pending.removeFirst()
                // Typing on past a completion's word cancels it; one still waiting here costs
                // the server nothing if it's never sent.
                if op.isCancelled { op.fail(); continue }
                await self.send(op)
            }
        }
    }
}
