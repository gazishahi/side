import Foundation
import SideAgents

/// The `Content-Length: N\r\n\r\n<json>` framing of LSP over stdio, as a pure state machine.
///
/// Pulled out of the transport so it can be tested with bytes rather than a live server — and
/// because the transport's version trapped: `Int("-5")` is a perfectly good `Int`, and
/// `buffer.index(startIndex, offsetBy: -5)` on it is a crash. A language server that emits a
/// negative or absurd Content-Length is malformed, not fatal. (2026-09-01 audit, Part V item 15.)
struct JSONRPCFraming {
    /// Anything larger is treated as a corrupt header rather than a request to buffer a gigabyte.
    static let maximumMessageBytes = 64 * 1_024 * 1_024

    private var buffer = Data()
    private var expectedContentLength: Int?

    enum Problem: Equatable {
        case unreadableHeader
        case missingContentLength
        case invalidContentLength(Int)
    }

    /// Complete messages that `data` completes, in order, plus any framing problems met on the
    /// way. A problem discards the buffered bytes up to and including the bad header and resumes,
    /// so one bad frame costs one frame, not the connection.
    mutating func feed(_ data: Data) -> (messages: [Data], problems: [Problem]) {
        buffer.append(data)
        var messages: [Data] = []
        var problems: [Problem] = []
        while true {
            if expectedContentLength == nil {
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return (messages, problems) }
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                guard let header = String(data: headerData, encoding: .utf8) else {
                    problems.append(.unreadableHeader)
                    continue
                }
                // Found anywhere on its line, not only at the start: after a malformed frame the
                // previous body's stray bytes sit glued to the front of the next header line, and
                // a prefix match would then reject every header for the rest of the connection.
                // The value is still parsed and range-checked, so this loosens re-sync, not trust.
                var length: Int?
                for line in header.components(separatedBy: "\r\n") {
                    guard let marker = line.range(of: "content-length:", options: .caseInsensitive) else { continue }
                    let value = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
                    length = Int(value)
                }
                guard let length else {
                    problems.append(.missingContentLength)
                    continue
                }
                guard length >= 0, length <= Self.maximumMessageBytes else {
                    problems.append(.invalidContentLength(length))
                    continue
                }
                expectedContentLength = length
            }
            guard let length = expectedContentLength, buffer.count >= length else { return (messages, problems) }
            messages.append(buffer.subdata(in: buffer.startIndex..<buffer.startIndex.advanced(by: length)))
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex.advanced(by: length))
            expectedContentLength = nil
        }
    }
}
