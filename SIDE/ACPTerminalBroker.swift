import AppKit
import SideAgents

/// An outside agent's `terminal/*` requests, run as Run tabs of their own
/// (`SIDE_RFC_BYO_HARNESS.md` step 3a). Each terminal runs its command directly — never typed into
/// a shell the user is using, never queued behind Heron's commands — in a tab appended to the
/// track's list: visible, interruptible (non-negotiable 8), and closed when the agent releases it.
@MainActor
final class ACPTerminalBroker: ACPTerminalHost {
    private final class Record {
        let session: TerminalSession
        let owner: UUID
        let limit: Int
        var output = Data()
        var truncated = false
        var exit: ACPTerminalExit?
        var waiters: [(ACPTerminalExit) -> Void] = []
        init(session: TerminalSession, owner: UUID, limit: Int) {
            self.session = session
            self.owner = owner
            self.limit = limit
        }
    }

    private unowned let terminals: TerminalSessionManager
    private var records: [String: Record] = [:]

    init(terminals: TerminalSessionManager) {
        self.terminals = terminals
    }

    func createTerminal(trackKey: String, command: String, arguments: [String], environment: [String: String],
                        cwd: URL, outputByteLimit: Int, owner: UUID) throws -> String {
        let id = "term-" + UUID().uuidString.lowercased()
        let launch = TerminalViewController.CommandLaunch(command: command, arguments: arguments, environment: environment)
        let session = terminals.makeCommandSession(forTrackKey: trackKey, launch: launch, directory: cwd.path)
        let record = Record(session: session, owner: owner, limit: max(1_024, outputByteLimit))
        records[id] = record
        session.viewController.onCommandOutput = { [weak self] bytes in self?.append(bytes, to: id) }
        session.viewController.onProcessExit = { [weak self] code in self?.exited(id, code: code) }
        session.viewController.start()
        return id
    }

    func output(of terminalId: String) -> ACPTerminalOutput? {
        guard let record = records[terminalId] else { return nil }
        let text = TerminalViewController.stripANSI(String(decoding: record.output, as: UTF8.self))
        return ACPTerminalOutput(output: text, truncated: record.truncated, exit: record.exit)
    }

    func waitForExit(_ terminalId: String, completion: @escaping (ACPTerminalExit) -> Void) -> Bool {
        guard let record = records[terminalId] else { return false }
        if let exit = record.exit { completion(exit) } else { record.waiters.append(completion) }
        return true
    }

    func kill(_ terminalId: String) -> Bool {
        guard let record = records[terminalId] else { return false }
        if record.exit == nil { record.session.viewController.stopProcess() }
        return true
    }

    func release(_ terminalId: String) -> Bool {
        guard let record = records.removeValue(forKey: terminalId) else { return false }
        terminals.removeSession(record.session)
        return true
    }

    func endAll(owner: UUID, closeTabs: Bool) {
        for (id, record) in records where record.owner == owner {
            if closeTabs { _ = release(id) } else if record.exit == nil { record.session.viewController.stopProcess() }
        }
    }

    // MARK: -

    /// Bounded from the front, at a UTF-8 character boundary, as ACP's `outputByteLimit` asks.
    private func append(_ bytes: ArraySlice<UInt8>, to id: String) {
        guard let record = records[id] else { return }
        record.output.append(contentsOf: bytes)
        guard record.output.count > record.limit else { return }
        var cut = record.output.count - record.limit
        // Continuation bytes are 10xxxxxx; never start the kept output inside a character.
        while cut < record.output.count, record.output[record.output.startIndex + cut] & 0xC0 == 0x80 { cut += 1 }
        record.output.removeFirst(cut)
        record.truncated = true
    }

    private func exited(_ id: String, code: Int32?) {
        guard let record = records[id], record.exit == nil else { return }
        let exit = ACPTerminalExit(exitCode: code.map(Int.init), signal: code == nil ? "SIGTERM" : nil)
        record.exit = exit
        let waiters = record.waiters
        record.waiters.removeAll()
        for waiter in waiters { waiter(exit) }
    }
}
