import XCTest
@testable import Heron

/// Parallel tracks don't collide on ports (2026-10-02, the owner).
final class TrackPortsTests: XCTestCase {
    override func tearDown() {
        TrackPorts.set([:], forProject: "/test-project")
        super.tearDown()
    }

    func testAProcessInATracksFolderGetsItsPorts() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ports-\(UUID().uuidString)").path
        TrackPorts.set([folder: TrackPorts.Block(base: 4120, trackName: "Search")], forProject: "/test-project")
        XCTAssertEqual(TrackPorts.environment(forDirectory: folder + "/packages/web"),
                       ["PORT": "4120", "SIDE_PORT_BASE": "4120", "SIDE_PORT_RANGE": "4120-4129"])
        XCTAssertEqual(TrackPorts.environment(forDirectory: folder + "-other"), [:], "a sibling folder isn't inside it")
        XCTAssertEqual(TrackPorts.environment(forDirectory: nil), [:])
        XCTAssertTrue(TrackPorts.promptSection(forDirectory: folder)?.contains("4120–4129") == true)
        XCTAssertTrue(TrackPorts.takenBases.contains(4120))
    }

    func testAFreeBlockSkipsTakenBasesAndBusyPorts() {
        XCTAssertEqual(TrackPorts.freeBase(excluding: [4100], isFree: { _ in true }), 4110)
        XCTAssertEqual(TrackPorts.freeBase(excluding: [], isFree: { $0 != 4105 }), 4110, "one busy port rules out its block")
        XCTAssertNil(TrackPorts.freeBase(excluding: [], isFree: { _ in false }))
    }

    func testThePortInUseIsReadFromTheUsualMessages() {
        XCTAssertEqual(PortConflict.port(in: "Error: listen EADDRINUSE: address already in use :::3000"), 3000)
        XCTAssertEqual(PortConflict.port(in: "Port 5173 is in use, trying another one..."), 5173)
        XCTAssertEqual(PortConflict.port(in: "OSError: [Errno 48] Address already in use (port 8000)"), 8000)
        XCTAssertEqual(PortConflict.port(in: #"Address already in use - bind(2) for "127.0.0.1" port 3001 (Errno::EADDRINUSE)"#), 3001)
        XCTAssertEqual(PortConflict.port(in: "listen tcp :8080: bind: address already in use"), 8080)
        XCTAssertEqual(PortConflict.port(in: "Bind for 0.0.0.0:5432 failed: port is already allocated"), 5432)
        XCTAssertNil(PortConflict.port(in: "Server listening on 3000"))
    }

    /// Who holds a port is named: here, this test's own listener.
    func testTheHolderOfAPortIsNamed() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(socket, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(TrackPorts.isFree(port))
        let holder = try XCTUnwrap(PortConflict.holder(of: port))
        XCTAssertEqual(holder.pid, Int(getpid()))
        let explained = try XCTUnwrap(PortConflict.explanation(for: "listen EADDRINUSE: address already in use :::\(port)", directory: nil))
        XCTAssertTrue(explained.contains("port \(port) is already in use by"), explained)
    }
}
