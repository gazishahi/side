import XCTest
@testable import Side

/// An agent command is submitted to a real visible shell, then a second line echoes a sentinel
/// and `$?` so completion can be detected. Anything that leaves the shell waiting for
/// continuation eats that sentinel line, so the command runs and *nothing ever reports back* —
/// the call used to hang to its timeout and then claim it was "still running." These assert we
/// refuse up front instead.
final class ShellWrapperTests: XCTestCase {
    private func refuses(_ command: String) -> Bool {
        TerminalViewController.unwrappableReason(for: command) != nil
    }

    func testRefusesMultiLineCommands() {
        XCTAssertTrue(refuses("echo one\necho two"))
        XCTAssertTrue(refuses("echo one\r\necho two"))
    }

    func testRefusesHeredocs() {
        XCTAssertTrue(refuses("cat <<EOF\nhello\nEOF"))
        XCTAssertTrue(refuses("cat <<'EOF' > f.txt"))
    }

    func testRefusesTrailingBackslashContinuation() {
        XCTAssertTrue(refuses("echo one \\"))
    }

    func testRefusesUnterminatedQuotes() {
        XCTAssertTrue(refuses("echo \"unterminated"))
        XCTAssertTrue(refuses("echo 'unterminated"))
        XCTAssertTrue(refuses("git commit -m \"wip"))
    }

    /// Balanced quoting — including quotes nested inside the other kind, and escaped quotes —
    /// must still be allowed, or ordinary commands would be refused.
    func testAllowsBalancedAndNestedQuoting() {
        XCTAssertFalse(refuses("echo \"hello world\""))
        XCTAssertFalse(refuses("echo 'hello world'"))
        XCTAssertFalse(refuses("echo \"it's fine\""), "a single quote inside double quotes is literal")
        XCTAssertFalse(refuses("echo 'say \"hi\"'"), "double quotes inside single quotes are literal")
        XCTAssertFalse(refuses("echo \\\"escaped\\\""), "escaped quotes aren't quote delimiters")
        XCTAssertFalse(refuses("git commit -m \"real message\""))
    }

    /// A trailing comment used to swallow the appended sentinel entirely. The sentinel now goes
    /// on its own line, so these are runnable rather than refused.
    func testAllowsTrailingComments() {
        XCTAssertFalse(refuses("ls -la # list everything"))
        XCTAssertFalse(refuses("make build #"))
    }

    func testAllowsOrdinaryCommands() {
        for command in ["ls", "npm test", "git status", "swift build && swift test", "echo a; echo b"] {
            XCTAssertFalse(refuses(command), command)
        }
    }

    /// The refusal is what the model reads, so it has to say what to do instead.
    func testRefusalExplainsTheAlternative() {
        let reason = TerminalViewController.unwrappableReason(for: "cat <<EOF\nx\nEOF")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("write_file"), "should point at the tool that does this properly")
    }
}

/// With shell integration, output is delimited by the shell's own OSC 133 marks, so the only
/// post-processing left is removing zsh's end-of-line marker — which it emits *before* precmd,
/// i.e. inside the captured region. These are the exact byte shapes observed from a real zsh
/// with powerlevel10k.
final class TerminalOutputCleanupTests: XCTestCase {
    func testStripsPromptEOLMarkAfterCRLF() {
        // Captured verbatim from a live session: output, CRLF, then the inverse-video `%`
        // padded with spaces and reset with CRs.
        let raw = "greeter.ts   index.js     mathUtils.ts\r\n\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m                    \r \r"
        let cleaned = TerminalViewController.strippingPromptEOLMark(TerminalViewController.stripANSI(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cleaned, "greeter.ts   index.js     mathUtils.ts")
    }

    /// CRLF is a single Swift Character, so hand-splitting on "\n" silently fails to split it —
    /// the bug that made the marker survive twice.
    func testMultiLineOutputSurvivesIntact() {
        let raw = "one\r\ntwo\r\nthree\r\n\u{1B}[7m%\u{1B}[0m   \r \r"
        let cleaned = TerminalViewController.strippingPromptEOLMark(TerminalViewController.stripANSI(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cleaned, "one\ntwo\nthree")
    }

    func testOutputWithoutMarkIsUnchanged() {
        let raw = "plain output\r\n"
        let cleaned = TerminalViewController.strippingPromptEOLMark(TerminalViewController.stripANSI(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cleaned, "plain output")
    }

    /// OSC sequences (zsh sets the window title every prompt) used to survive stripping and glue
    /// separate lines together.
    func testStripsOSCAndCSIAndBEL() {
        let raw = "\u{1B}]0;title\u{07}hello\u{1B}[0m\u{07} world\u{1B}]1;tab\u{07}"
        XCTAssertEqual(TerminalViewController.stripANSI(raw), "hello world")
    }

    func testStripsTwoCharacterEscapes() {
        XCTAssertEqual(TerminalViewController.stripANSI("a\u{1B}>b\u{1B}[?2004lc"), "abc")
    }
}
