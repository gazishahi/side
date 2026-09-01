import Foundation

/// One message bound for a language server, in the order the editor produced it.
enum LSPOutboundOp: Sendable {
    case didOpen(uri: String, languageId: String, text: String, version: Int)
    case didChange(uri: String, text: String, version: Int)
    case didClose(uri: String)
    /// Requests carry their reply; `nil` means the server never answered (not running, or an error).
    case completion(uri: String, position: LSPPosition, reply: @Sendable (Data?) -> Void)
    case definition(uri: String, position: LSPPosition, reply: @Sendable (Data?) -> Void)

    /// The document this op is about, for deciding what a replay supersedes.
    var uri: String {
        switch self {
        case .didOpen(let uri, _, _, _), .didChange(let uri, _, _), .didClose(let uri),
             .completion(let uri, _, _), .definition(let uri, _, _):
            return uri
        }
    }

    /// True for a notification whose entire content is superseded by a later `didOpen` carrying
    /// the document's current text.
    var isDocumentSync: Bool {
        switch self {
        case .didOpen, .didChange, .didClose: return true
        case .completion, .definition: return false
        }
    }

    /// Answers a request that will never reach a server.
    func fail() {
        switch self {
        case .completion(_, _, let reply), .definition(_, _, let reply): reply(nil)
        case .didOpen, .didChange, .didClose: break
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
                await self.send(op)
            }
        }
    }
}
