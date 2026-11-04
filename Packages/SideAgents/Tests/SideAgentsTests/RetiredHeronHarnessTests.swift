import XCTest
@testable import SideAgents

/// SIDE_RFC_HERON_RETIREMENT.md, step 4: Heron's runner is gone, and a track's Heron
/// conversations are still there to read, as Heron showed them after a relaunch.
@MainActor
final class RetiredHeronHarnessTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testAHeronConversationIsReadAndNothingCanBeSent() throws {
        let store = AgentSessionStore(stateDirectory: root)
        store.appendTurn(AgentTurn(role: .user, content: [.text("Where is the cache?")]), trackKey: "t", providerId: "anthropic", modelId: "m")
        store.appendTurn(AgentTurn(role: .assistant, content: [.text("Reading it."), .toolUse(id: "u1", name: "read_file", input: .object(["path": .string("a.swift")]))]),
                         trackKey: "t", providerId: "anthropic", modelId: "m")
        store.appendTurn(AgentTurn(role: .user, content: [.toolResult(toolUseId: "u1", content: "one\ntwo", isError: false)]), trackKey: "t", providerId: "anthropic", modelId: "m")
        store.appendTurn(AgentTurn(role: .assistant, content: [.text("In Store.swift.")]), trackKey: "t", providerId: "anthropic", modelId: "m")

        let heron = RetiredHeronHarness(trackKey: "t", sessionStore: store)
        let lines: [String] = heron.entries.map {
            switch $0.kind {
            case .userText(let text): return "you: \(text)"
            case .assistantText(let text): return "heron: \(text)"
            case .toolCall(let name, let summary): return "tool: \(name)\(summary)"
            case .toolResult(let text, _): return "result: \(text)"
            default: return "other"
            }
        }
        XCTAssertEqual(lines, ["you: Where is the cache?", "heron: Reading it.", "tool: read_file (path: a.swift)", "result: \u{2713} 2 lines", "heron: In Store.swift."])
        XCTAssertNil(heron.harnessName, "it's Heron's")
        XCTAssertFalse(heron.isReadyToSend)
        heron.send("Anything?")
        XCTAssertEqual(heron.entries.count, 5, "nothing is sent")
        XCTAssertEqual(heron.phase, .idle)
    }

    func testAPastHeronConversationStillOpens() throws {
        let store = AgentSessionStore(stateDirectory: root)
        store.appendTurn(AgentTurn(role: .user, content: [.text("The first one")]), trackKey: "t", providerId: "anthropic", modelId: "m")
        XCTAssertTrue(store.archiveActiveConversation(forTrackKey: "t"))
        store.replaceTurns([], trackKey: "t", providerId: "anthropic", modelId: "m")
        store.appendTurn(AgentTurn(role: .user, content: [.text("The second one")]), trackKey: "t", providerId: "anthropic", modelId: "m")

        let heron = RetiredHeronHarness(trackKey: "t", sessionStore: store)
        let firstText: () -> String? = { if case .userText(let text)? = heron.entries.first?.kind { return text } else { return nil } }
        XCTAssertEqual(firstText(), "The second one")
        let archived = try XCTUnwrap(heron.archivedConversations.first)
        var reset = false
        heron.addObserver { if case .reset = $0 { reset = true } }
        XCTAssertTrue(heron.openArchivedConversation(id: archived.id))
        XCTAssertTrue(reset)
        XCTAssertEqual(firstText(), "The first one")
    }
}
