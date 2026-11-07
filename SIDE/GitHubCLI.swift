import Foundation
import SideAgents

/// The GitHub CLI (`gh`), when it's installed and signed in: opening a pull request directly and
/// finding the one a branch already has. Without it, Review opens GitHub's own "new pull
/// request" page with the title and body filled in, and the user finishes there. Side never
/// holds a GitHub token; `gh` uses the user's own login.
enum GitHubCLI {
    struct PullRequest: Equatable {
        let number: Int
        let url: URL
        let state: String
    }

    /// Resolved through the login shell, so call off the main thread.
    static func executable() -> URL? { LanguageServerRegistry.resolveExecutable(named: "gh") }

    /// The pull request `branch` already has, open or not. Nil when there's none (or no `gh`).
    static func pullRequest(branch: String, cwd: String) -> PullRequest? {
        guard let result = run(["pr", "view", branch, "--json", "number,url,state"], cwd: cwd), result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let number = json["number"] as? Int, let url = (json["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return PullRequest(number: number, url: url, state: (json["state"] as? String ?? "").lowercased())
    }

    /// A branch's pull request as Branches shows it (SIDE_RFC_GIT_TRACKS.md, phase 3).
    struct BranchPullRequest: Equatable, Sendable {
        let number: Int
        let url: URL
        /// "open", "merged" or "closed".
        let state: String
        let isDraft: Bool
        let head: String
        let base: String

        var isOpen: Bool { state == "open" }
        /// "PR #42", "draft PR #42", "PR #42 merged"
        var label: String {
            if isOpen { return isDraft ? "draft PR #\(number)" : "PR #\(number)" }
            return "PR #\(number) \(state)"
        }
    }

    /// Every branch's pull request in one call, the newest per branch: open, merged or closed.
    /// Nil when `gh` isn't there or can't answer (not signed in, no GitHub remote). Off the main
    /// thread.
    static func pullRequestsByBranch(cwd: String) -> [String: BranchPullRequest]? {
        guard let result = run(["pr", "list", "--state", "all", "--limit", "200", "--json", "number,url,state,isDraft,headRefName,baseRefName"], cwd: cwd),
              result.status == 0 else { return nil }
        return parsePullRequests(result.output)
    }

    /// `gh pr list --json …`'s answer, newest first as gh lists it: the first one seen for a
    /// branch is the one it has.
    static func parsePullRequests(_ json: String) -> [String: BranchPullRequest]? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
        var byBranch: [String: BranchPullRequest] = [:]
        for entry in list {
            guard let number = entry["number"] as? Int, let url = (entry["url"] as? String).flatMap(URL.init(string:)),
                  let head = entry["headRefName"] as? String, let base = entry["baseRefName"] as? String, byBranch[head] == nil else { continue }
            byBranch[head] = BranchPullRequest(number: number, url: url, state: (entry["state"] as? String ?? "").lowercased(),
                                               isDraft: entry["isDraft"] as? Bool ?? false, head: head, base: base)
        }
        return byBranch
    }

    struct Failure: Error { let message: String }

    /// Opens a pull request; returns its URL, or what went wrong.
    static func create(base: String, branch: String, title: String, body: String, cwd: String) -> Result<URL, Failure> {
        guard let result = run(["pr", "create", "--base", base, "--head", branch, "--title", title, "--body", body], cwd: cwd) else {
            return .failure(Failure(message: "gh isn't installed."))
        }
        let lines = result.output.split(separator: "\n").map(String.init)
        if result.status == 0, let url = lines.reversed().compactMap({ URL(string: $0.trimmingCharacters(in: .whitespaces)) }).first(where: { $0.scheme == "https" }) {
            return .success(url)
        }
        let text = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.localizedCaseInsensitiveContains("auth login") || text.localizedCaseInsensitiveContains("not logged") {
            return .failure(Failure(message: "gh isn't signed in. Run \u{201C}gh auth login\u{201D} in a terminal, then try again."))
        }
        return .failure(Failure(message: text.split(separator: "\n").last.map(String.init) ?? text))
    }

    private static func run(_ arguments: [String], cwd: String) -> (status: Int32, output: String, error: String)? {
        guard let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = LanguageServerRegistry.environmentForSpawning(keeping: ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"])
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        // Read both pipes before waiting (ProcessHygiene): a full pipe blocks the child.
        let errorBox = DataBox()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            errorBox.data = err.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        reading.wait()
        process.waitUntilExit()
        let error = String(decoding: errorBox.data, as: UTF8.self)
        return (process.terminationStatus, output, error)
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
