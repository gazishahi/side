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
        /// GitLab's: a merge request, "MR !42".
        var isMergeRequest = false

        var isOpen: Bool { state == "open" }
        /// "PR #42" or "MR !42".
        var shortName: String { isMergeRequest ? "MR !\(number)" : "PR #\(number)" }
        /// "PR #42", "draft PR #42", "PR #7 merged"
        var label: String {
            if isOpen { return isDraft ? "draft \(shortName)" : shortName }
            return "\(shortName) \(state)"
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
        return run(executable, arguments, cwd: cwd)
    }

    fileprivate static func run(_ executable: URL, _ arguments: [String], cwd: String) -> (status: Int32, output: String, error: String)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // Each tool's own login: gh's and glab's tokens pass through, nothing of Side's.
        var environment = LanguageServerRegistry.environmentForSpawning(keeping: ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GITLAB_TOKEN", "GITLAB_HOST"])
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

/// Where a branch's pull request comes from (SIDE_RFC_GIT_TRACKS.md, phase 3, widened
/// 2026-11-07): the host's own tool when it's installed and signed in (`gh`, `glab`), else the
/// host's public API, which answers for a public repository with no sign-in. A private
/// repository without either has none, and bases follow the rest of the order. Side never reads
/// a token of its own, nor the one git keeps for pushing.
enum PullRequestSources {
    /// Every branch's newest pull request, and what answered ("gh", "GitHub"); nil when nothing
    /// could. Off the main thread: it runs a tool or asks the network.
    static func fetch(cwd: String) -> (found: [String: GitHubCLI.BranchPullRequest], source: String)? {
        guard let remote = Publishing.remote(cwd: cwd), let host = remote.web else { return nil }
        switch host {
        case .github(let owner, let repo):
            if GitHubCLI.executable() != nil, let found = GitHubCLI.pullRequestsByBranch(cwd: cwd) { return (found, "gh") }
            return fetchJSON("https://api.github.com/repos/\(owner)/\(repo)/pulls?state=all&per_page=100&sort=created&direction=desc")
                .flatMap(parseGitHubAPI).map { ($0, "GitHub") }
        case .gitlab(let hostName, let path):
            if let glab = LanguageServerRegistry.resolveExecutable(named: "glab"),
               let result = GitHubCLI.run(glab, ["mr", "list", "--all", "--per-page", "100", "--output", "json"], cwd: cwd), result.status == 0,
               let found = parseGitLab(result.output) {
                return (found, "glab")
            }
            let project = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
            return fetchJSON("https://\(hostName)/api/v4/projects/\(project)/merge_requests?state=all&per_page=100&order_by=created_at&sort=desc")
                .flatMap(parseGitLab).map { ($0, "GitLab") }
        }
    }

    /// GitHub's REST answer (`GET /repos/{owner}/{repo}/pulls`): branches of this repository only,
    /// not a fork's that happens to share a name. Told apart by the PR's own base repository, not
    /// the remote's name: a repository that moved (apple/swift-format is swiftlang's now) answers
    /// under its new one.
    static func parseGitHubAPI(_ json: String) -> [String: GitHubCLI.BranchPullRequest]? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
        var byBranch: [String: GitHubCLI.BranchPullRequest] = [:]
        for entry in list {
            guard let number = entry["number"] as? Int, let url = (entry["html_url"] as? String).flatMap(URL.init(string:)),
                  let head = entry["head"] as? [String: Any], let headRef = head["ref"] as? String,
                  let baseInfo = entry["base"] as? [String: Any], let base = baseInfo["ref"] as? String, byBranch[headRef] == nil else { continue }
            let headRepository = (head["repo"] as? [String: Any])?["full_name"] as? String
            let baseRepository = (baseInfo["repo"] as? [String: Any])?["full_name"] as? String
            guard headRepository != nil, headRepository == baseRepository else { continue }
            let state = entry["merged_at"] is String ? "merged" : (entry["state"] as? String ?? "")
            byBranch[headRef] = GitHubCLI.BranchPullRequest(number: number, url: url, state: state, isDraft: entry["draft"] as? Bool ?? false,
                                                            head: headRef, base: base)
        }
        return byBranch
    }

    /// GitLab's merge requests, from its API or `glab mr list --output json` (the same fields).
    static func parseGitLab(_ json: String) -> [String: GitHubCLI.BranchPullRequest]? {
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
        var byBranch: [String: GitHubCLI.BranchPullRequest] = [:]
        for entry in list {
            guard let number = entry["iid"] as? Int, let url = (entry["web_url"] as? String).flatMap(URL.init(string:)),
                  let head = entry["source_branch"] as? String, let base = entry["target_branch"] as? String, byBranch[head] == nil else { continue }
            let raw = entry["state"] as? String ?? ""
            let draft = entry["draft"] as? Bool ?? entry["work_in_progress"] as? Bool ?? false
            byBranch[head] = GitHubCLI.BranchPullRequest(number: number, url: url, state: raw == "opened" ? "open" : raw, isDraft: draft,
                                                         head: head, base: base, isMergeRequest: true)
        }
        return byBranch
    }

    /// One GET, no credentials, ten seconds at most. Nil for anything but a 200: a private
    /// repository is a 404, and the public API's hourly limit a 403.
    private static func fetchJSON(_ address: String) -> String? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Side", forHTTPHeaderField: "User-Agent")
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data { box.text = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return box.text
    }
}

private final class ResponseBox: @unchecked Sendable {
    var text: String?
}
