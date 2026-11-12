import Foundation

/// The wire format between Side and a keeper: a kind byte, a little-endian UInt32 length, and the
/// payload. Control messages carry JSON; output, input and snapshots carry raw bytes.
public enum FrameKind: UInt8, Sendable {
    // Client → keeper
    case hello = 1
    case attach = 2
    case detach = 3
    case input = 4
    case resize = 5
    case signal = 6
    // Keeper → client
    case welcome = 16
    case snapshot = 17
    case output = 18
    case title = 19
    case attention = 20
    case exited = 21
    /// Another client attached; this one no longer receives output.
    case replaced = 22
    /// The program's status records (OSC 7501), all of them, after any change: JSON
    /// `[ProgramStatusRecord]`. Only to a client whose Hello asked for events.
    case programStatus = 23
    /// The working directory the shell reported (OSC 7), as a path. Only with events.
    case pwd = 24
}

public struct Frame: Sendable, Equatable {
    public let kind: FrameKind
    public let payload: [UInt8]

    public init(_ kind: FrameKind, _ payload: [UInt8] = []) {
        self.kind = kind
        self.payload = payload
    }

    public init<T: Encodable>(_ kind: FrameKind, json value: T) {
        self.init(kind, Array((try? JSONEncoder().encode(value)) ?? Data()))
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: Data(payload)) }

    /// A payload past this is a corrupt stream, not a message.
    public static let maximumPayload = 64 << 20

    public var encoded: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(5 + payload.count)
        bytes.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: payload)
        return bytes
    }
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    public private(set) var isCorrupt = false

    public init() {}

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        if start > 0, start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        buffer.append(contentsOf: bytes)
    }

    public mutating func append(_ bytes: [UInt8]) { bytes.withUnsafeBytes { append($0) } }

    /// The next whole frame, if one has arrived.
    public mutating func next() -> Frame? {
        guard !isCorrupt, buffer.count - start >= 5 else { return nil }
        var length: UInt32 = 0
        withUnsafeMutableBytes(of: &length) { $0.copyBytes(from: buffer[(start + 1)..<(start + 5)]) }
        let count = Int(UInt32(littleEndian: length))
        guard let kind = FrameKind(rawValue: buffer[start]), count <= Frame.maximumPayload else { isCorrupt = true; return nil }
        guard buffer.count - start - 5 >= count else { return nil }
        let frame = Frame(kind, Array(buffer[(start + 5)..<(start + 5 + count)]))
        start += 5 + count
        // Keep the buffer from growing without bound under a steady stream.
        if start > 1 << 20 { buffer.removeFirst(start); start = 0 }
        return frame
    }
}

// MARK: - Control payloads

public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var build: String
    /// The client understands `programStatus` and `pwd` frames. An older client leaves it out,
    /// and gets none: a frame kind it doesn't know reads as a corrupt stream.
    public var events: Bool?
    public init(protocolVersion: Int = SessionProtocol.version, build: String, events: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.build = build
        self.events = events
    }
}

/// One record of the Program Status Protocol (OSC 7501, revision 0.4,
/// superlogical.com/rex/docs/build/program-status): what a program in the terminal says it's
/// doing. libghostty-vt parses and validates the report; the keeper keeps the records, as the
/// spec asks of a terminal, and hands them to Side.
public struct ProgramStatusRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case idle, working, done, blocked, error }
    public enum Kind: String, Codable, Sendable { case permission, question, auth }

    /// Empty for the root record (the program itself); "build/test" is a child of "build".
    public var id: String
    public var state: State
    /// What a blocked program needs; nil otherwise, or when it didn't say.
    public var kind: Kind?
    /// 0–100 while working or blocked; nil when indeterminate.
    public var progress: Int?
    /// A stable name to match on ("claude-code"); empty when the report had none. Not a label.
    public var app: String
    /// A short label, for people. Untrusted text from the program.
    public var title: String
    /// One line saying what it's doing or waiting for. Untrusted text from the program.
    public var message: String
    public var updatedAt: Date

    public init(id: String, state: State, kind: Kind? = nil, progress: Int? = nil, app: String = "", title: String = "", message: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
        self.updatedAt = updatedAt
    }
}

/// The spec's rules for keeping records, apart from the terminal so they can be tested alone.
public struct ProgramStatusRecords: Sendable, Equatable {
    public private(set) var records: [ProgramStatusRecord] = []
    /// Past this many, the least recently updated goes (the spec: at most 256, at least 64).
    public static let limit = 256

    public init(_ records: [ProgramStatusRecord] = []) { self.records = records }

    /// A report replaces its record completely.
    public mutating func put(_ record: ProgramStatusRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        if records.count > Self.limit, let oldest = records.indices.min(by: { records[$0].updatedAt < records[$1].updatedAt }) {
            records.remove(at: oldest)
        }
    }

    /// `state=clear`: the record and everything beneath it; an empty id, every record.
    public mutating func clear(_ id: String) {
        guard !id.isEmpty else { records.removeAll(); return }
        records.removeAll { $0.id == id || $0.id.hasPrefix(id + "/") }
    }

    /// A new shell prompt, or the program exited: working and blocked records go. Done and
    /// error stay until the person has seen them.
    public mutating func programEnded() {
        records.removeAll { $0.state == .working || $0.state == .blocked }
    }

    /// The program itself: the root record.
    public var root: ProgramStatusRecord? { records.first { $0.id.isEmpty } }

    /// A record's app, or its nearest ancestor's when it has none (the spec's inheritance).
    public func app(of record: ProgramStatusRecord) -> String {
        if !record.app.isEmpty { return record.app }
        var id = record.id
        while !id.isEmpty {
            id = id.contains("/") ? String(id[..<id.lastIndex(of: "/")!]) : ""
            if let parent = records.first(where: { $0.id == id }), !parent.app.isEmpty { return parent.app }
        }
        return ""
    }
}

public struct Welcome: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var build: String
    public var record: SessionRecord
    public init(protocolVersion: Int, build: String, record: SessionRecord) {
        self.protocolVersion = protocolVersion
        self.build = build
        self.record = record
    }
}

public struct Size: Codable, Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// An attach: the client's grid, and how much history its own terminal keeps. The keeper keeps
/// all of its scrollback either way; it sends only what the client can hold, since replaying
/// lines a client then drops is work on the client's main thread for nothing.
public struct Attach: Codable, Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    /// Lines of scrollback the client keeps; nil for everything.
    public var history: Int?
    public init(cols: Int, rows: Int, history: Int? = nil) {
        self.cols = cols
        self.rows = rows
        self.history = history
    }
}

public struct SignalRequest: Codable, Sendable, Equatable {
    public var signal: Int32
    /// Every descendant too: an interactive shell puts each background job in its own process
    /// group, so signalling the group alone leaves `npm run dev &` running.
    public var wholeTree: Bool
    public init(signal: Int32, wholeTree: Bool) {
        self.signal = signal
        self.wholeTree = wholeTree
    }
}

public struct Exit: Codable, Sendable, Equatable {
    /// The exit status, or nil when the process ended by a signal.
    public var status: Int32?
    public var signal: Int32?
    public init(status: Int32?, signal: Int32?) {
        self.status = status
        self.signal = signal
    }
}

public enum SessionProtocol {
    /// Bumped only for an incompatible change; new messages are added, never changed.
    public static let version = 1
}
