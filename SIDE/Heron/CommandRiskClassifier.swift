import Foundation

/// How risky a proposed shell command looks, from a quick pattern match against its text —
/// deliberately not a security boundary (a determined or obfuscated command can still slip
/// past this), just enough to stop a genuinely destructive command from ever benefiting from a
/// track's `autoRunCommands` opt-out the same way `ls` does. Every command still goes through
/// the same approval card either way; `.destructive` only removes the auto-run shortcut and
/// adds a visible warning for the human actually clicking Run.
enum CommandRiskLevel: Equatable {
    case normal
    case destructive(reason: String)
}

enum CommandRiskClassifier {
    /// Matched as a regular expression against the whole command string, case-insensitively
    /// unless `caseSensitive` is set. The first match wins and its reason is what the human
    /// sees — order roughly follows how commonly each pattern shows up in real destructive
    /// commands, not severity.
    private static let patterns: [(regex: String, reason: String, caseSensitive: Bool)] = [
        (#"rm\s+(-\w*r\w*f\w*|-\w*f\w*r\w*)\b"#, "Recursively deletes files (rm -rf)", false),
        (#"git\s+push\s+.*(--force(?!-with-lease)\b|(?<!\S)-f\b)"#, "Force-pushes, which can overwrite remote history", false),
        (#"git\s+reset\s+--hard\b"#, "Discards uncommitted changes (git reset --hard)", false),
        (#"git\s+clean\s+.*-\w*[fd]"#, "Deletes untracked files (git clean)", false),
        // Case-sensitive on purpose: `-D` force-deletes even an unmerged branch, `-d` refuses to
        // — case-insensitive matching here would flag the safe, everyday flag as destructive.
        (#"git\s+branch\s+-D\b"#, "Force-deletes a branch, even if unmerged", true),
        (#"git\s+push\s+.*--delete\b"#, "Deletes a remote branch", false),
        (#"\bsudo\b"#, "Runs with elevated privileges", false),
        (#"\bchmod\s+.*-R\s+777\b"#, "Makes files world-writable, recursively", false),
        (#"\bchown\s+.*-R\b"#, "Recursively changes file ownership", false),
        (#"\bdd\s+if="#, "Low-level disk copy — can overwrite an entire disk", false),
        (#"\bkill(all)?\s+-9\b"#, "Force-kills a process, skipping its own cleanup", false),
        (#"curl\s+.*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, "Pipes a downloaded script directly into a shell", false),
        (#"\bdrop\s+(table|database)\b"#, "Drops a database or table", false),
        (#"\btruncate\s+table\b"#, "Empties a database table", false),
    ]

    static func classify(_ command: String) -> CommandRiskLevel {
        for (pattern, reason, caseSensitive) in patterns {
            var options: String.CompareOptions = [.regularExpression]
            if !caseSensitive { options.insert(.caseInsensitive) }
            if command.range(of: pattern, options: options) != nil {
                return .destructive(reason: reason)
            }
        }
        return .normal
    }
}
