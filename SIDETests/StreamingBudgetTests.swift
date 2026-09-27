import XCTest
@testable import Side

/// SIDE_RFC_HERON_EFFICIENCY.md, step 4 (D6): Think's side of a streaming message. The runner's
/// side is Heron's `StreamingEfficiencyTests`. Opt-in with the other budgets.
@MainActor
final class StreamingBudgetTests: XCTestCase {
    override func setUp() async throws { try Budgets.skipUnlessEnabled() }

    /// Seconds to stream `characters` into an on-screen bubble in 10-character appends, one
    /// flush per append: the worst case, a flush for every delta.
    private func stream(characters: Int) -> TimeInterval {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.close() }
        let bubble = TextBlockView(style: .received, body: "", maxBubbleWidth: 620)
        window.contentView?.addSubview(bubble)
        window.orderFront(nil)
        // Paragraphs of about 400 characters, as a reply has.
        let words = String(repeating: "the store keeps a cache keyed by path and refresh walks it; ", count: 7) + "\n\n"
        var text = ""
        text.reserveCapacity(characters)
        let start = DispatchTime.now().uptimeNanoseconds
        while text.utf8.count < characters {
            let offset = (text.utf8.count / 10 * 10) % words.count
            let start = words.index(words.startIndex, offsetBy: offset)
            text += words[start...].prefix(10)
            bubble.setBody(text, streaming: true)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let spent = TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertEqual(bubble.plainText.utf8.count, text.utf8.count)
        return spent
    }

    /// Think flushes at most every 35 ms, so what a stream costs it is its flushes: each should
    /// cost the same at the end of a long message as at the start (it grew with the message).
    func testAFlushCostsTheSameAtAnyLength() {
        _ = stream(characters: 5_000)  // warm up
        let half = stream(characters: 25_000)
        let whole = stream(characters: 50_000)
        let perFlush = whole / 5_000 * 1000
        Budgets.check("stream.think", perFlush,
                      detail: String(format: "50,000 characters in 5,000 flushes: %.0f ms; 25,000 took %.0f ms (%.2fx for twice the text)", whole * 1000, half * 1000, whole / half))
        XCTAssertLessThan(whole / half, 2.4, "linear in the message, not quadratic")
    }
}
