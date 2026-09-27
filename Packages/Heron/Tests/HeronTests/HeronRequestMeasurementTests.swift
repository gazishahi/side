import XCTest
@testable import Heron

/// SIDE_RFC_HERON_EFFICIENCY.md, step 1: what Heron sends, measured against a fake server. A
/// scripted session (two messages, ten tool round trips each, reading real files) records every
/// request body; the report says how much each re-sent, and how much of it a prompt cache could
/// have served (the part identical to the request before it).
@MainActor
final class HeronRequestMeasurementTests: XCTestCase {
    /// A project of twelve files, a few hundred lines each: what an agent reads to answer.
    static func fixtureProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heron-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        for file in 0..<12 {
            let lines = (0..<180).map { line in "    func step\(file)_\(line)(_ value: Int) -> Int { value &* \(line + 1) &+ \(file) }  // part \(line)" }
            try (["struct Part\(file) {"] + lines + ["}"]).joined(separator: "\n")
                .write(to: root.appendingPathComponent("Sources/Part\(file).swift"), atomically: true, encoding: .utf8)
        }
        return root
    }

    struct Measurement {
        var bodies: [Int] = []
        /// Bytes identical to the previous request's start.
        var sharedWithPrevious: [Int] = []
        var total: Int { bodies.reduce(0, +) }
        var reusable: Int { sharedWithPrevious.reduce(0, +) }
    }

    static func measure(_ bodies: [Data]) -> Measurement {
        var result = Measurement()
        var previous = Data()
        for body in bodies {
            let shared = zip(previous, body).prefix { $0 == $1 }.count
            result.bodies.append(body.count)
            result.sharedWithPrevious.append(shared)
            previous = body
        }
        return result
    }

    func testTheBaselineOfWhatARoundTripReSends() throws {
        let project = try Self.fixtureProject()
        defer { try? FileManager.default.removeItem(at: project) }
        // Each request reads the next file; the tenth of each message answers.
        let server = try FakeModelServer { index, _ in
            let step = index % 11
            if step == 10 { return .text("Read them. Each part multiplies and adds its own index.") }
            return .tools([(name: "read_file", input: #"{"path": "Sources/Part\#(step).swift"}"#)])
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .ask, autonomy: .manual))
        defer { heron.cleanUp() }

        XCTAssertEqual(heron.send("Read the parts and say what they do."), .finishedTurn)
        XCTAssertEqual(heron.send("Now read them again and compare the last two."), .finishedTurn)
        let bodies = server.requests
        XCTAssertEqual(bodies.count, 22)
        let measured = Self.measure(bodies)
        let reusable = Double(measured.reusable) / Double(measured.total)
        print("HERON baseline: \(bodies.count) requests, \(measured.total) bytes sent, largest \(measured.bodies.max() ?? 0)")
        print("HERON baseline: identical to the previous request's start: \(measured.reusable) bytes (\(String(format: "%.0f", reusable * 100))%)")
        print("HERON baseline: bodies " + measured.bodies.map(String.init).joined(separator: " "))
        print("HERON baseline: shared " + measured.sharedWithPrevious.map(String.init).joined(separator: " "))
        // Nothing asks for caching today.
        XCTAssertFalse(bodies.contains { String(decoding: $0, as: UTF8.self).contains("cache_control") })
        XCTAssertEqual(heron.totals.requestCount, 22, "every request metered")
    }
}

/// The headless driver applies an edit at full autonomy, as the benchmark's Build task needs.
@MainActor
final class HeadlessHeronTests: XCTestCase {
    func testAnEditIsAppliedWithoutAClick() throws {
        let project = try HeronBenchmarkTests.projectCopy()
        defer { try? FileManager.default.removeItem(at: project) }
        let server = try FakeModelServer { index, _ in
            index == 0
                ? .tools([(name: "edit_file", input: ##"{"path": "README.md", "old_string": "# Shop", "new_string": "# Shop (edited)"}"##)])
                : .text("Done.")
        }
        defer { server.stop() }
        let heron = try HeadlessHeron(project: project, baseURL: server.baseURL, modelId: "claude-sonnet-5",
                                      mode: AgentMode(scope: .build, autonomy: .full))
        defer { heron.cleanUp() }
        XCTAssertEqual(heron.send("Mark the readme."), .finishedTurn)
        XCTAssertTrue(try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8).hasPrefix("# Shop (edited)"))
        XCTAssertEqual(server.requests.count, 2)
    }
}
