import XCTest
@testable import Side
@testable import Heron

/// Harness RFC step 3 (D9): an outside agent reads and writes through Side, runs commands in
/// Run tabs of its own, and every turn that changed files ends in a checkpoint that doesn't
/// claim the user's own saves (audit F4).
@MainActor
final class ACPFileTerminalTests: XCTestCase {
    private var root: URL!
    private var live: [String: String] = [:]
    private var terminals: TerminalSessionManager!
    private var broker: ACPTerminalBroker!
    private var store: AgentSessionStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acp3-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in ["a.txt": "alpha\n", "b.txt": "bravo\n", "c.txt": "charlie\n", "d.txt": "delta\n"] {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        git(["init", "-q", "-b", "main"]); git(["config", "user.email", "t@t"]); git(["config", "user.name", "T"])
        git(["add", "."]); git(["commit", "-q", "-m", "base"])
        terminals = TerminalSessionManager(projectRoot: root) { [root] _ in root! }
        broker = ACPTerminalBroker(terminals: terminals)
        store = AgentSessionStore(stateDirectory: root.appendingPathComponent(".git/side-test", isDirectory: true))
        UserSaveLog.shared.removeAll()
        // Last-known agent settings are app-wide per agent id; tests start without any.
        UserDefaults.standard.removeObject(forKey: "SideACPKnownOptions.mock")
    }

    override func tearDown() async throws {
        terminals.teardownAll()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ args: [String]) -> String {
        let result = GitPaths.runGit(args, cwd: root.path)
        XCTAssertTrue(result.success, "git \(args): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var remembered: [String: String] = [:]

    private func harness(autonomy: AgentAutonomy = .manual) throws -> ACPHarness {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path), "needs python3 for the mock agent")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mock-acp3-\(UUID().uuidString).py")
        try Self.mockAgent.write(to: script, atomically: true, encoding: .utf8)
        let agent = ACPAgent(id: "mock", displayName: "Mock", binary: "mock", installHint: "")
        let root = self.root!
        let bridge = WorkspaceBridge(liveBufferProvider: { [unowned self] url in self.live[url.lastPathComponent] },
                                     applyEditIntoOpenTab: { _, _ in false }, onRevealFileRequested: { _ in },
                                     runShellCommand: { _, _, done in done("") }, interruptShellCommand: {})
        var mode = AgentMode.default
        mode.autonomy = autonomy
        return ACPHarness(trackKey: "t", agent: agent,
                          launchProvider: { ACPLaunch(executable: python, arguments: [script.path], environment: ProcessInfo.processInfo.environment) },
                          rootProvider: { root }, bridgeProvider: { bridge }, modeProvider: { mode },
                          sessionStore: store, terminalHost: { [unowned self] in self.broker },
                          preferredOptions: { [unowned self] in self.remembered },
                          onOptionChanged: { [unowned self] id, value in self.remembered[id] = value })
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Step 4: the session opens before any message, its settings show, a choice is sent to
    /// the agent and remembered, and a remembered choice is re-applied to the next session.
    func testAgentSettingsOpenEarlyChangeAndAreRemembered() throws {
        let h = try harness()
        defer { h.teardown() }
        h.prepareSession()
        XCTAssertTrue(waitFor { h.agentOptions.map(\.id) == ["model", "mode"] }, "the session opened without a message")
        XCTAssertEqual(h.phase, .idle)
        XCTAssertEqual(h.agentOptions.map(\.id), ["model", "mode"])
        XCTAssertEqual(h.agentOptions.first?.currentChoice?.name, "Big")
        XCTAssertFalse(h.agentOptions[1].actsWithoutAsking)

        h.setAgentOption(id: "mode", value: "auto")
        XCTAssertEqual(remembered, ["mode": "auto"])
        XCTAssertTrue(waitFor { h.agentOptions[1].current == "auto" })
        XCTAssertTrue(h.agentOptions[1].actsWithoutAsking, "Auto is a mode where edits land directly")

        // A fresh conversation is a fresh session: the remembered choice goes with it.
        remembered = ["model": "small"]
        h.startNewConversation()
        h.prepareSession()
        XCTAssertTrue(waitFor { h.agentOptions.first?.current == "small" }, "\(h.agentOptions)")
    }

    /// Opening a session ahead of time for an agent that isn't there is a note, not a failed run.
    func testPreparingAMissingAgentIsANoteNotAFailure() {
        let agent = ACPAgent(id: "mock", displayName: "Mock", binary: "mock", installHint: "install mock")
        let h = ACPHarness(trackKey: "t", agent: agent, launchProvider: { nil }, rootProvider: { FileManager.default.temporaryDirectory })
        h.prepareSession()
        XCTAssertTrue(waitFor { !h.entries.isEmpty })
        guard case .meta(let note)? = h.entries.last?.kind else { return XCTFail("\(h.entries.map(\.kind))") }
        XCTAssertTrue(note.contains("install mock"), note)
        XCTAssertEqual(h.phase, .idle)
    }

    /// Agents that predate `configOptions` describe modes and models separately.
    func testLegacyModesAndModelsBecomeOptions() {
        let result: [String: Any] = [
            "modes": ["currentModeId": "code", "availableModes": [["id": "code", "name": "Code"], ["id": "yolo", "name": "Yolo", "_meta": ["kind": "full_access"]]]],
            "models": ["currentModelId": "m1", "availableModels": [["modelId": "m1", "name": "Model One"]]],
        ]
        let (options, _) = ACPHarness.options(from: result)
        XCTAssertEqual(options.map(\.id), ["model", "mode"])
        XCTAssertEqual(options[0].currentChoice?.name, "Model One")
        var mode = options[1]
        mode.current = "yolo"
        XCTAssertTrue(mode.actsWithoutAsking)
    }

    /// Runs one scenario; `whileAsked` runs when the harness is waiting on the user.
    /// Everything the agent said, joined — consecutive message chunks merge into one line.
    private func run(_ harness: ACPHarness, _ scenario: String, whileAsked: ((ACPHarness) -> Void)? = nil) -> String {
        let done = expectation(description: "turn finished")
        done.assertForOverFulfill = false
        var handled = false
        harness.addObserver { _ in
            if harness.phase == .awaitingApproval, !handled {
                handled = true
                DispatchQueue.main.async { whileAsked?(harness) }
            }
            if harness.phase == .finishedTurn || harness.phase == .blocked(.failed) { done.fulfill() }
        }
        harness.send("\(scenario) \(root.path)")
        wait(for: [done], timeout: 30)
        return harness.entries.compactMap { if case .assistantText(let text) = $0.kind { return text } else { return nil } }.joined(separator: "|")
    }

    private func waitForCheckpoint(_ harness: ACPHarness) -> Checkpoint? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let checkpoint = store.checkpoints(forTrackKey: "t").last { return checkpoint }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    func testReadsAreContainedAndSeeUnsavedBuffers() throws {
        live["a.txt"] = "unsaved alpha"
        let h = try harness()
        defer { h.teardown() }
        let said = run(h, "read")
        XCTAssertTrue(said.contains("R1:unsaved alphaR2"), said)
        XCTAssertTrue(said.contains("R2:bravoR3"), "one line via line/limit: \(said)")
        XCTAssertTrue(said.contains("R3:ERR Refused: that path is outside"), said)
        XCTAssertTrue(said.contains("R4:ERR Refused: Side's own state"), said)
    }

    /// D9: allowed on the agent's own card → no second card. The turn's checkpoint holds the
    /// agent's writes (through Side and direct) and not the file the user saved meanwhile.
    func testAGrantedWriteAppliesOnceAndTheCheckpointLeavesTheUsersSaveOut() throws {
        let h = try harness()
        defer { h.teardown() }
        let said = run(h, "granted") { [root] harness in
            // The user saves their own file while the agent waits.
            try? "delta, mine\n".write(to: root!.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
            UserSaveLog.shared.record(root!.appendingPathComponent("d.txt"))
            guard let card = harness.entries.first(where: { if case .permissionRequest = $0.kind { return true }; return false }) else { return }
            harness.answerPermission(proposalId: card.id, optionId: "yes")
        }
        XCTAssertTrue(said.contains("W:ok"), said)
        XCTAssertFalse(h.entries.contains { if case .proposal = $0.kind { return true }; return false }, "no second card")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "alpha, agent\n")

        let checkpoint = try XCTUnwrap(waitForCheckpoint(h))
        let committed = Set(git(["show", "--name-only", "--format=", checkpoint.gitCommitSHA ?? "HEAD"]).split(separator: "\n").map(String.init))
        XCTAssertEqual(committed, ["a.txt", "e.txt"], "agent's writes in; the user's save out")
        XCTAssertEqual(git(["status", "--porcelain", "d.txt"]), "M d.txt", "the user's save is still theirs, uncommitted")
        XCTAssertEqual(checkpoint.provenance.providerId, "acp:mock")
    }

    /// D9: an unannounced write under Manual is a card; Apply writes it.
    func testAnUnannouncedWriteIsACardUnderManual() throws {
        let h = try harness(autonomy: .manual)
        defer { h.teardown() }
        let said = run(h, "unannounced") { harness in
            guard let card = harness.entries.first(where: { if case .proposal = $0.kind { return true }; return false }) else { return XCTFail("no card") }
            harness.resolve(proposalId: card.id, decision: .apply)
        }
        XCTAssertTrue(said.contains("W:ok"), said)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "bravo, agent\n")
    }

    /// …and Full applies it without asking.
    func testAnUnannouncedWriteAppliesUnderFull() throws {
        let h = try harness(autonomy: .full)
        defer { h.teardown() }
        let said = run(h, "unannounced")
        XCTAssertTrue(said.contains("W:ok"), said)
        XCTAssertFalse(h.entries.contains { if case .proposal = $0.kind { return true }; return false })
    }

    func testAWriteWhoseBaseMovedIsRefused() throws {
        let h = try harness(autonomy: .full)
        defer { h.teardown() }
        let said = run(h, "stale")
        XCTAssertTrue(said.contains("W:ERR Refused: c.txt changed since you read it"), said)
        XCTAssertTrue(said.contains("N:ERR Refused: d.txt already exists and hasn't been read"), said)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("c.txt"), encoding: .utf8), "charlie, elsewhere\n")
    }

    /// Terminals are Run tabs of their own running the command directly; a cwd outside the
    /// worktree is refused; release closes the tab.
    func testTerminalsRunInTheirOwnTabs() throws {
        let h = try harness()
        defer { h.teardown() }
        let said = run(h, "term")
        XCTAssertTrue(said.contains("T:exit=0"), said)
        XCTAssertTrue(said.contains("T:out=hello-acp"), said)
        XCTAssertTrue(said.contains("T2:ERR Refused: / is outside"), said)
        XCTAssertTrue(terminals.sessions(forTrackKey: "t").isEmpty, "released tab is closed")
    }

    /// A turn that goes silent says so instead of looking busy forever.
    func testASilentTurnStallsVisibly() throws {
        let h = try harness()
        defer { h.teardown() }
        h.stallInterval = 1.5
        let stalled = expectation(description: "stalled")
        stalled.assertForOverFulfill = false
        h.addObserver { _ in if h.phase == .blocked(.stalled) { stalled.fulfill() } }
        h.send("silent \(root.path)")
        wait(for: [stalled], timeout: 20)
        guard case .failure(let message)? = h.entries.last(where: { if case .failure = $0.kind { return true }; return false })?.kind else { return XCTFail("no failure") }
        XCTAssertTrue(message.contains("No response from Mock"), message)
    }

    /// The session line says which model, effort, mode and account the agent runs as.
    func testSessionSettingsNameTheCurrentChoices() {
        let result: [String: Any] = ["configOptions": [
            ["id": "model", "currentValue": "opus[1m]", "options": [["value": "opus[1m]", "name": "Opus 5.5"], ["value": "sonnet", "name": "Sonnet 5"]]],
            ["id": "effort", "currentValue": "medium", "options": [["value": "medium", "name": "Medium"]]],
            ["id": "mode", "currentValue": "auto", "options": [["value": "auto", "name": "Auto"]]],
        ]]
        let settings = ACPHarness.settings(from: result)
        XCTAssertEqual(settings.map(\.id), ["model", "effort", "mode"])
        XCTAssertEqual(settings.map(\.value), ["Opus 5.5", "Medium", "Auto"])
        XCTAssertEqual(ACPAgent.agent(id: "claude-code")?.apiKeyVariables, ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
    }

    /// Opt-in (`TEST_RUNNER_SIDE_LIVE_ACP=1`): the real Claude Code adapter, launched the way the
    /// app launches it — API keys hidden, so it runs on the user's subscription — answers a
    /// prompt and names its model and account.
    func testLiveClaudeCodeAnswers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_LIVE_ACP"] == "1", "live agent test is opt-in")
        let adapter = URL(fileURLWithPath: "/opt/homebrew/bin/claude-agent-acp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: adapter.path), "claude-agent-acp not installed")
        let agent = try XCTUnwrap(ACPAgent.agent(id: "claude-code"))
        let environment = agent.launchEnvironment(from: LanguageServerRegistry.environmentForSpawning())
        let root = self.root!
        let h = ACPHarness(trackKey: "t", agent: agent, launchProvider: { ACPLaunch(executable: adapter, arguments: [], environment: environment) },
                           rootProvider: { root }, sessionStore: store, terminalHost: { [unowned self] in self.broker })
        defer { h.teardown() }
        let done = expectation(description: "answered")
        done.assertForOverFulfill = false
        h.addObserver { _ in if h.phase == .finishedTurn || h.phase == .blocked(.failed) || h.phase == .blocked(.stalled) { done.fulfill() } }
        h.send("Reply with exactly the word: ok")
        wait(for: [done], timeout: 120)
        XCTAssertEqual(h.phase, .finishedTurn, "\(h.entries.map(\.kind))")
        let said = h.entries.compactMap { if case .assistantText(let t) = $0.kind { return t } else { return nil } }.joined()
        XCTAssertTrue(said.lowercased().contains("ok"), said)
        XCTAssertTrue(h.agentOptions.contains { $0.category == .model && !$0.choices.isEmpty }, "\(h.agentOptions)")
        XCTAssertTrue(h.agentOptions.contains { $0.category == .effort }, "\(h.agentOptions)")
        XCTAssertNotNil(h.accountLabel)
    }

    /// Subscription: every key variable removed. API key: the stored key (else one already in
    /// the environment) in the first variable.
    func testSignInShapesTheAgentsEnvironment() {
        let agent = ACPAgent(id: "test-signin-\(UUID().uuidString)", displayName: "T", binary: "t", installHint: "",
                             apiKeyVariables: ["PRIMARY_KEY", "OTHER_KEY"])
        defer { agent.setAPIKey(nil); UserDefaults.standard.removeObject(forKey: "SideACPSignIn.\(agent.id)") }
        let base = ["PATH": "/bin", "OTHER_KEY": "from-env"]
        agent.signIn = .subscription
        XCTAssertEqual(agent.launchEnvironment(from: base), ["PATH": "/bin"])
        agent.signIn = .apiKey
        XCTAssertEqual(agent.launchEnvironment(from: base), ["PATH": "/bin", "PRIMARY_KEY": "from-env"], "no stored key: the environment's")
        agent.setAPIKey("stored")
        XCTAssertEqual(agent.launchEnvironment(from: base), ["PATH": "/bin", "PRIMARY_KEY": "stored"])
    }

    /// Codex's and Gemini's real method lists (read from their packages, 2026-09-23).
    func testTheRightSignInMethodIsChosen() {
        let codex: [[String: Any]] = [
            ["id": "api-key", "name": "API Key", "_meta": ["api-key": ["provider": "openai"]]],
            ["id": "chat-gpt", "name": "ChatGPT"], ["id": "chat-gpt-device-code", "name": "ChatGPT (device code)"], ["id": "gateway", "name": "Gateway"],
        ]
        let gemini: [[String: Any]] = [
            ["id": "oauth-personal", "name": "Log in with Google"], ["id": "gemini-api-key", "name": "Gemini API key", "_meta": ["api-key": ["provider": "google"]]],
            ["id": "vertex-ai", "name": "Vertex AI"], ["id": "gateway", "name": "AI API Gateway"],
        ]
        XCTAssertEqual(ACPHarness.signInMethod(codex, for: .subscription)?["id"] as? String, "chat-gpt")
        XCTAssertEqual(ACPHarness.signInMethod(codex, for: .apiKey)?["id"] as? String, "api-key")
        XCTAssertEqual(ACPHarness.signInMethod(gemini, for: .subscription)?["id"] as? String, "oauth-personal")
        XCTAssertEqual(ACPHarness.signInMethod(gemini, for: .apiKey)?["id"] as? String, "gemini-api-key")
        XCTAssertNil(ACPHarness.signInMethod([], for: .subscription), "Claude Code lists none")
    }

    /// An agent that lists sign-in methods is told the chosen one before a session opens.
    func testTheAgentIsSignedInBeforeTheSessionOpens() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path))
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("mock-auth-\(UUID().uuidString).py")
        try #"""
import json, sys
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
authed = None
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method")
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "authMethods": [
        {"id": "key", "name": "Key", "_meta": {"api-key": {}}}, {"id": "login", "name": "Login"}]}})
    elif meth == "authenticate": authed = m["params"]["methodId"]; send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
    elif meth == "session/new":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s", "configOptions": [{"id": "who", "name": "Who", "type": "select", "currentValue": str(authed), "options": [{"value": str(authed), "name": str(authed)}]}]}})
"""#.write(to: script, atomically: true, encoding: .utf8)
        let agent = ACPAgent(id: "mock-auth", displayName: "Mock", binary: "mock", installHint: "")
        defer { UserDefaults.standard.removeObject(forKey: "SideACPKnownOptions.mock-auth") }
        for (choice, expected) in [(ACPAgent.SignIn.apiKey, "key"), (.subscription, "login")] {
            let h = ACPHarness(trackKey: "t", agent: agent,
                               launchProvider: { ACPLaunch(executable: python, arguments: [script.path], environment: ProcessInfo.processInfo.environment, signIn: choice) },
                               rootProvider: { FileManager.default.temporaryDirectory })
            h.prepareSession()
            // The pill may show last-known settings first; wait for this session's own answer.
            XCTAssertTrue(waitFor { h.agentOptions.first { $0.id == "who" }?.current == expected }, "\(choice): \(h.agentOptions)")
            h.teardown()
        }
    }

    func testCustomAgentsAreAddedAndRemoved() {
        let added = ACPAgent.addCustom(name: "OpenCode", command: "opencode", arguments: ["acp"], apiKeyVariable: " ")
        defer { ACPAgent.removeCustom(id: added.id) }
        XCTAssertTrue(added.isCustom)
        XCTAssertEqual(ACPAgent.agent(id: added.id)?.arguments, ["acp"])
        XCTAssertFalse(added.acceptsAPIKey, "a blank variable means no key")
        ACPAgent.removeCustom(id: added.id)
        XCTAssertNil(ACPAgent.agent(id: added.id))
    }

    /// Step 5: the conversation is Side's to keep. A relaunch shows it again, nothing twice, and
    /// the agent's own session is reopened (so it remembers) without its replay being drawn.
    func testTheConversationSurvivesARelaunchAndTheAgentsSessionIsReopened() throws {
        var h = try harness(autonomy: .full)
        _ = run(h, "unannounced")
        let before = h.entries.compactMap { entry -> String? in
            switch entry.kind {
            case .userText(let t), .assistantText(let t): return t
            default: return nil
            }
        }
        XCTAssertEqual(before.count, 2)
        XCTAssertNotNil(waitForCheckpoint(h))
        h.teardown()

        // "Relaunch": a new harness for the same track and agent.
        h = try harness(autonomy: .full)
        defer { h.teardown() }
        let after = h.entries.compactMap { entry -> String? in
            switch entry.kind {
            case .userText(let t), .assistantText(let t): return t
            default: return nil
            }
        }
        XCTAssertEqual(after, before, "the record brings the conversation back")
        XCTAssertTrue(h.entries.contains { if case .checkpoint = $0.kind { return true }; return false }, "with its checkpoint line")

        h.prepareSession()
        XCTAssertTrue(waitFor { h.agentOptions.first?.current == "small" }, "session/load reopened the agent's session: \(h.agentOptions)")
        let text = h.entries.compactMap { if case .assistantText(let t) = $0.kind { return t } else { return nil } }.joined()
        XCTAssertFalse(text.contains("REPLAYED"), "the agent's replay isn't drawn a second time")

        // A second turn appends; a third launch shows both turns once.
        _ = run(h, "unannounced")
        h.teardown()
        h = try harness(autonomy: .full)
        let users = h.entries.filter { if case .userText = $0.kind { return true }; return false }
        XCTAssertEqual(users.count, 2)
    }

    /// An agent that can't reopen the session starts a new one, and says the agent won't remember.
    func testAFailedReopenStartsANewSessionAndSaysSo() throws {
        let url = store.outsideLogURL(trackKey: "t", agentId: "mock")
        OutsideSessionLog.append([.init(kind: .header, conversationId: UUID(), agentId: "mock", agentSessionId: "gone"),
                                  .init(kind: .user, text: "earlier")], to: url)
        let h = try harness()
        defer { h.teardown() }
        XCTAssertEqual(h.entries.count, 1)
        h.prepareSession()
        XCTAssertTrue(waitFor { h.entries.contains { if case .meta(let t) = $0.kind { return t.contains("couldn't reopen") }; return false } })
        XCTAssertTrue(waitFor { h.agentOptions.first?.current == "big" }, "a new session opened")
    }

    /// Opt-in live: Claude Code remembers across a relaunch, through `session/load`.
    func testLiveClaudeCodeRemembersAcrossARelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDE_LIVE_ACP"] == "1", "live agent test is opt-in")
        let adapter = URL(fileURLWithPath: "/opt/homebrew/bin/claude-agent-acp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: adapter.path))
        let agent = try XCTUnwrap(ACPAgent.agent(id: "claude-code"))
        let environment = agent.launchEnvironment(from: LanguageServerRegistry.environmentForSpawning())
        let root = self.root!
        func make() -> ACPHarness {
            ACPHarness(trackKey: "t", agent: agent, launchProvider: { ACPLaunch(executable: adapter, arguments: [], environment: environment) },
                       rootProvider: { root }, sessionStore: store, terminalHost: { [unowned self] in self.broker })
        }
        func ask(_ h: ACPHarness, _ text: String) -> String {
            let done = expectation(description: text)
            done.assertForOverFulfill = false
            let token = h.addObserver { _ in if h.phase == .finishedTurn || h.phase == .blocked(.failed) || h.phase == .blocked(.stalled) { done.fulfill() } }
            h.send(text)
            wait(for: [done], timeout: 120)
            h.removeObserver(token)
            return h.entries.compactMap { if case .assistantText(let t) = $0.kind { return t } else { return nil } }.last ?? ""
        }
        let first = make()
        _ = ask(first, "Remember this word for later: pelican. Reply with just: ok")
        first.teardown()
        let second = make()
        defer { second.teardown() }
        let answer = ask(second, "What word did I ask you to remember? Reply with just the word.")
        XCTAssertTrue(answer.lowercased().contains("pelican"), answer)
    }

    /// A command tab is never where the agent's typed commands go.
    func testACommandTabIsNeverTheAgentsShell() {
        let launch = TerminalViewController.CommandLaunch(command: "/bin/sleep", arguments: ["5"], environment: [:])
        let command = terminals.makeCommandSession(forTrackKey: "t", launch: launch, directory: root.path)
        XCTAssertFalse(terminals.agentSession(forTrackKey: "t") === command)
    }

    /// Audit F4 for Heron: a file the user saves while a batch waits isn't the agent's.
    func testStagingLeavesAUserSaveOut() throws {
        let baseline = GitPaths.dirtyPaths(cwd: root.path)
        try "alpha, agent\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "delta, mine\n".write(to: root.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        let started = Date().addingTimeInterval(-1)
        UserSaveLog.shared.record(root.appendingPathComponent("d.txt"))
        let saved = UserSaveLog.shared.paths(savedSince: started, under: root.path)
        XCTAssertEqual(saved, ["d.txt"])
        let outcome = AgentRunner.stageAndCommit(root: root.path, baseline: baseline, knownChanged: ["a.txt"], userSaved: saved, message: "agent")
        guard case .committed(_, let paths)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(paths, ["a.txt"])
    }

    private static let mockAgent = #"""
import json, sys, os
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
def up(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": u}})
def say(t): up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
nid = [1000]
def call(method, params):
    nid[0] += 1; rid = nid[0]
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("id") == rid and "method" not in m: return m
    sys.exit(0)
state = {"model": "big", "mode": "ask"}
def options():
    return [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": state["model"],
             "options": [{"value": "big", "name": "Big"}, {"value": "small", "name": "Small"}]},
            {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": state["mode"],
             "options": [{"value": "ask", "name": "Ask first", "_meta": {"kind": "standard"}}, {"value": "auto", "name": "Auto", "description": "Decides itself", "_meta": {"kind": "auto_review"}}]}]
def res(m, key):
    return ("ERR " + m["error"]["message"]) if "error" in m else m["result"].get(key, "ok")
for line in sys.stdin:
    m = json.loads(line); meth = m.get("method"); p = m.get("params", {})
    if meth == "initialize": send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
    elif meth == "session/new": send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s", "configOptions": options()}})
    elif meth == "session/load":
        if p["sessionId"] == "s":
            # Replays history, as a real agent does; Side's record already shows it.
            up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAYED"}})
            state["model"] = "small"
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"configOptions": options()}})
        else:
            send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32002, "message": "no such session"}})
    elif meth == "session/set_config_option":
        state[p["configId"]] = p["value"]
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"configOptions": options()}})
    elif meth == "session/prompt":
        scenario, root = p["prompt"][0]["text"].split(" ", 1)
        f = lambda n: os.path.join(root, n)
        if scenario == "read":
            say("R1:" + res(call("fs/read_text_file", {"sessionId": "s", "path": f("a.txt")}), "content"))
            say("R2:" + res(call("fs/read_text_file", {"sessionId": "s", "path": f("b.txt"), "line": 1, "limit": 1}), "content"))
            say("R3:" + res(call("fs/read_text_file", {"sessionId": "s", "path": "/etc/hosts"}), "content"))
            say("R4:" + res(call("fs/read_text_file", {"sessionId": "s", "path": f(".git/side/x")}), "content"))
        elif scenario == "granted":
            up({"sessionUpdate": "tool_call", "toolCallId": "e1", "title": "Edit a.txt", "kind": "edit", "status": "pending",
                "locations": [{"path": f("a.txt")}], "content": [{"type": "diff", "path": f("a.txt"), "oldText": "alpha\n", "newText": "alpha, agent\n"}]})
            call("session/request_permission", {"sessionId": "s", "toolCall": {"toolCallId": "e1"},
                 "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]})
            w = call("fs/write_text_file", {"sessionId": "s", "path": f("a.txt"), "content": "alpha, agent\n"})
            say("W:" + ("ERR " + w["error"]["message"] if "error" in w else "ok"))
            up({"sessionUpdate": "tool_call_update", "toolCallId": "e1", "status": "completed"})
            # A direct write, bypassing Side — still checkpointed.
            open(f("e.txt"), "w").write("echo\n")
            up({"sessionUpdate": "tool_call", "toolCallId": "e2", "title": "Write e.txt", "kind": "edit", "status": "completed", "locations": [{"path": f("e.txt")}]})
        elif scenario == "unannounced":
            call("fs/read_text_file", {"sessionId": "s", "path": f("b.txt")})
            w = call("fs/write_text_file", {"sessionId": "s", "path": f("b.txt"), "content": "bravo, agent\n"})
            say("W:" + ("ERR " + w["error"]["message"] if "error" in w else "ok"))
        elif scenario == "stale":
            call("fs/read_text_file", {"sessionId": "s", "path": f("c.txt")})
            open(f("c.txt"), "w").write("charlie, elsewhere\n")
            w = call("fs/write_text_file", {"sessionId": "s", "path": f("c.txt"), "content": "charlie, agent\n"})
            say("W:" + ("ERR " + w["error"]["message"] if "error" in w else "ok"))
            n = call("fs/write_text_file", {"sessionId": "s", "path": f("d.txt"), "content": "never read\n"})
            say("N:" + ("ERR " + n["error"]["message"] if "error" in n else "ok"))
        elif scenario == "silent":
            continue  # never answers the prompt
        elif scenario == "term":
            t = call("terminal/create", {"sessionId": "s", "command": "/bin/echo", "args": ["hello-acp"], "cwd": root})
            tid = t["result"]["terminalId"]
            e = call("terminal/wait_for_exit", {"sessionId": "s", "terminalId": tid})
            say("T:exit=" + str(e["result"]["exitCode"]))
            o = call("terminal/output", {"sessionId": "s", "terminalId": tid})
            say("T:out=" + o["result"]["output"])
            call("terminal/release", {"sessionId": "s", "terminalId": tid})
            t2 = call("terminal/create", {"sessionId": "s", "command": "/bin/echo", "args": ["x"], "cwd": "/"})
            say("T2:" + ("ERR " + t2["error"]["message"] if "error" in t2 else "ok"))
        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
"""#
}
