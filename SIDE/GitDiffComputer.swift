import Foundation

enum GitDiffMark { case added, modified, removedBefore }

enum GitDiffComputer {
    static func compute(projectRoot: URL, relativePath: String, currentContent: String, completion: @escaping ([Int: GitDiffMark]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let headContent = runGit(["show", "HEAD:\(relativePath)"], cwd: projectRoot.path)
            let marks = diffMarks(original: headContent.isEmpty ? nil : headContent, current: currentContent, projectRoot: projectRoot)
            DispatchQueue.main.async { completion(marks) }
        }
    }

    private static func diffMarks(original: String?, current: String, projectRoot: URL) -> [Int: GitDiffMark] {
        guard let original else {
            guard !current.isEmpty else { return [:] }
            let lineCount = current.components(separatedBy: "\n").count
            var marks: [Int: GitDiffMark] = [:]
            for line in 1...max(lineCount, 1) { marks[line] = .added }
            return marks
        }
        guard original != current else { return [:] }

        let tmpDir = FileManager.default.temporaryDirectory
        let originalFile = tmpDir.appendingPathComponent("side-diff-orig-\(UUID().uuidString).txt")
        let currentFile = tmpDir.appendingPathComponent("side-diff-cur-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: originalFile)
            try? FileManager.default.removeItem(at: currentFile)
        }
        do {
            try original.write(to: originalFile, atomically: true, encoding: .utf8)
            try current.write(to: currentFile, atomically: true, encoding: .utf8)
        } catch { return [:] }

        let output = runGit(["diff", "--no-index", "--no-color", "-U0", originalFile.path, currentFile.path], cwd: projectRoot.path)
        return parseHunks(output)
    }

    private static func parseHunks(_ diffOutput: String) -> [Int: GitDiffMark] {
        var marks: [Int: GitDiffMark] = [:]
        guard let hunkRegex = try? NSRegularExpression(pattern: "^@@ -\\d+(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@") else { return marks }
        for line in diffOutput.components(separatedBy: "\n") where line.hasPrefix("@@") {
            let ns = line as NSString
            guard let match = hunkRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let oldCount = Int(group(1) ?? "1") ?? 1
            let newStart = Int(group(2) ?? "0") ?? 0
            let newCount = Int(group(3) ?? "1") ?? 1

            if newCount == 0 {
                marks[max(newStart, 1)] = .removedBefore
            } else if oldCount == 0 {
                for line in newStart..<(newStart + newCount) { marks[line] = .added }
            } else {
                for line in newStart..<(newStart + newCount) { marks[line] = .modified }
            }
        }
        return marks
    }

    private static func runGit(_ args: [String], cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
