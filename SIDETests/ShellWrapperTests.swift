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

    /// Multi-line commands, heredocs, trailing backslash continuations and unterminated quotes
    /// all leave the shell waiting for more input.
    func testShapesThatLeaveTheShellWaitingAreRefused() {
        let refused: [(command: String, shape: String)] = [
            ("echo one\necho two", "multi-line"),
            ("echo one\r\necho two", "multi-line with CRLF"),
            ("cat <<EOF\nhello\nEOF", "heredoc"),
            ("cat <<'EOF' > f.txt", "heredoc"),
            ("echo one \\", "trailing backslash continuation"),
            ("echo \"unterminated", "unterminated double quote"),
            ("echo 'unterminated", "unterminated single quote"),
            ("git commit -m \"wip", "unterminated double quote"),
        ]
        for c in refused {
            XCTAssertTrue(refuses(c.command), "\(c.shape) was not refused: \(c.command.debugDescription)")
        }
    }

    /// Balanced quoting — including quotes nested inside the other kind, and escaped quotes —
    /// must still be allowed, or ordinary commands would be refused. A trailing comment used to
    /// swallow the appended sentinel entirely; the sentinel now goes on its own line, so those
    /// are runnable rather than refused too.
    func testOrdinaryShapesAreAllowed() {
        let allowed: [(command: String, why: String)] = [
            ("echo \"hello world\"", "balanced double quotes"),
            ("echo 'hello world'", "balanced single quotes"),
            ("echo \"it's fine\"", "a single quote inside double quotes is literal"),
            ("echo 'say \"hi\"'", "double quotes inside single quotes are literal"),
            ("echo \\\"escaped\\\"", "escaped quotes aren't quote delimiters"),
            ("git commit -m \"real message\"", "balanced double quotes"),
            ("ls -la # list everything", "trailing comment"),
            ("make build #", "trailing empty comment"),
            ("ls", "ordinary"),
            ("npm test", "ordinary"),
            ("git status", "ordinary"),
            ("swift build && swift test", "ordinary"),
            ("echo a; echo b", "ordinary"),
        ]
        for c in allowed {
            XCTAssertFalse(refuses(c.command), "\(c.why) was refused: \(c.command.debugDescription)")
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
    /// CRLF is a single Swift Character, so hand-splitting on "\n" silently fails to split it —
    /// the bug that made the marker survive twice. Output without a mark is left alone.
    func testThePromptEOLMarkIsStrippedAndEverythingElseSurvives() {
        let cases: [(raw: String, cleaned: String, shape: String)] = [
            // Captured verbatim from a live session: output, CRLF, then the inverse-video `%`
            // padded with spaces and reset with CRs.
            ("greeter.ts   index.js     mathUtils.ts\r\n\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m                    \r \r",
             "greeter.ts   index.js     mathUtils.ts", "mark after CRLF"),
            ("one\r\ntwo\r\nthree\r\n\u{1B}[7m%\u{1B}[0m   \r \r", "one\ntwo\nthree", "multi-line output"),
            ("plain output\r\n", "plain output", "no mark"),
        ]
        for c in cases {
            let cleaned = TerminalViewController.strippingPromptEOLMark(TerminalViewController.stripANSI(c.raw))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(cleaned, c.cleaned, c.shape)
        }
    }

    /// OSC sequences (zsh sets the window title every prompt) used to survive stripping and glue
    /// separate lines together; two-character escapes and private-mode CSIs go the same way.
    func testStripsOSCCSIBELAndTwoCharacterEscapes() {
        let raw = "\u{1B}]0;title\u{07}hello\u{1B}[0m\u{07} world\u{1B}]1;tab\u{07}"
        XCTAssertEqual(TerminalViewController.stripANSI(raw), "hello world")
        XCTAssertEqual(TerminalViewController.stripANSI("a\u{1B}>b\u{1B}[?2004lc"), "abc")
    }
}
