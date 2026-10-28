import AppKit

/// After a crash, the next launch offers to report it: a GitHub issue on side-releases, opened in
/// the person's browser with the report's summary filled in. Nothing is sent unless they press
/// Report, and the summary holds only versions, the exception and the crashed thread's frames
/// (image names and offsets, which a release's dSYM turns into lines): no paths, no file names.
@MainActor
enum CrashReports {
    static let issuesURL = URL(string: "https://github.com/gazishahi/side-releases/issues/new")!
    static var defaults = UserDefaults.standard
    static var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    private static let seenKey = "crashReports.lastSeen"
    /// With nothing seen yet (the first launch with this), a crash this recent is still offered.
    private static let firstLookBack: TimeInterval = 3 * 24 * 3600
    private static let frameLimit = 30

    struct Report: Equatable {
        var file: URL
        var date: Date
        var summary: String
    }

    /// The newest crash of Side's that hasn't been offered yet, if any.
    static func unseen(now: Date = Date()) -> Report? {
        let since = defaults.object(forKey: seenKey) as? Date ?? now.addingTimeInterval(-firstLookBack)
        // macOS moves a report into Retired once it has been seen or sent to Apple.
        let files = [directory, directory.appendingPathComponent("Retired", isDirectory: true)].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("Side-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > since else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, date) in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8), let summary = summary(ofReport: text) else { continue }
            return Report(file: url, date: date, summary: summary)
        }
        return nil
    }

    static func markSeen(_ report: Report) {
        defaults.set(report.date, forKey: seenKey)
    }

    /// The report's first line is a JSON header, the rest one JSON object. Nil for anything that
    /// isn't a crash of Side's.
    static func summary(ofReport text: String) -> String? {
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              header["bundleID"] as? String == "com.shahi.side",
              header["bug_type"] as? String == "309",
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let side = images.first { $0["name"] as? String == "Side" }
        // A development build's crash (Xcode, a test run) is the developer's own to read.
        if let path = side?["path"] as? String, path.contains("/DerivedData/") || path.contains("/Build/Products/") { return nil }
        var lines: [String] = []
        let version = header["app_version"] as? String ?? "?"
        let build = header["build_version"] as? String ?? "?"
        let os = header["os_version"] as? String ?? "?"
        let arch = side?["arch"] as? String ?? "?"
        lines.append("Side \(version) (\(build)), \(os), \(arch)")
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = exception["signal"] as? String
            lines.append("Exception: \(type)" + (signal.map { " (\($0))" } ?? ""))
        }
        if let uuid = side?["uuid"] as? String {
            lines.append("Side image: \(uuid)")
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = body["faultingThread"] as? Int ?? 0
        if threads.indices.contains(crashed) {
            let thread = threads[crashed]
            let queue = thread["queue"] as? String
            lines.append("")
            lines.append("Thread \(crashed) crashed" + (queue.map { " (\($0))" } ?? "") + ":")
            for (number, frame) in (thread["frames"] as? [[String: Any]] ?? []).prefix(frameLimit).enumerated() {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index]["name"] as? String ?? "?" : "?"
                let offset = frame["imageOffset"] as? Int ?? 0
                // System frames keep their symbols; Side's are stripped, and read from the dSYM.
                var line = "\(number) \(image) +0x\(String(offset, radix: 16))"
                if image != "Side", let symbol = frame["symbol"] as? String {
                    line += " \(symbol)"
                    if let location = frame["symbolLocation"] as? Int { line += " + \(location)" }
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A new issue on side-releases with the summary, for the person to read and send.
    static func issueURL(for report: Report) -> URL {
        let firstLine = report.summary.split(separator: "\n").first.map(String.init) ?? "Side"
        let body = """
        **What were you doing when Side quit?**


        **Crash summary** (versions, the exception and the crashed thread; nothing from your files)
        ```
        \(report.summary)
        ```
        """
        var components = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: "Crash: \(firstLine)"), URLQueryItem(name: "body", value: body)]
        return components.url!
    }

    /// Asks once per crash, as a sheet on the window.
    static func offer(in window: NSWindow) {
        guard let report = unseen() else { return }
        markSeen(report)
        let alert = NSAlert()
        alert.messageText = "Side quit unexpectedly"
        alert.informativeText = "Reporting it on GitHub helps get it fixed. Your browser opens a new issue with a summary of the crash, which you can read before sending. It holds Side's and macOS's versions and where Side stopped, nothing from your files."
        alert.addButton(withTitle: "Report on GitHub…")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Show Report")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(issueURL(for: report))
            case .alertThirdButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([report.file])
            default: break
            }
        }
    }
}
