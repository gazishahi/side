import XCTest
@testable import Heron

/// 2026-09-30 audit, H1: writing to a child that has exited raised SIGPIPE and ended the whole
/// process. This test process doesn't ignore SIGPIPE, so if `PipeWriting` didn't protect the
/// descriptor, the test runner itself would die here.
final class PipeWritingTests: XCTestCase {
    func testWritingToAnExitedReaderFailsInsteadOfKillingUs() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let stdin = Pipe()
        process.standardInput = stdin
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        // More than a pipe's buffer, so the write can't just land in it.
        let large = Data(repeating: 0x61, count: 300_000)
        XCTAssertFalse(PipeWriting.write(large, to: stdin.fileHandleForWriting))
        XCTAssertFalse(PipeWriting.write(Data("again".utf8), to: stdin.fileHandleForWriting), "and again, still alive")
    }

    func testWritingToALiveReaderSucceeds() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        XCTAssertTrue(PipeWriting.write(Data("hello".utf8), to: stdin.fileHandleForWriting))
        try stdin.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "hello")
    }
}
