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
    public init(protocolVersion: Int = SessionProtocol.version, build: String) {
        self.protocolVersion = protocolVersion
        self.build = build
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
