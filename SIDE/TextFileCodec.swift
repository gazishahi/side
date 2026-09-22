import Foundation

/// How a text file is stored on disk, so that saving it writes back the same shape it came in.
///
/// The editor used to decode with a ladder ending in Latin-1 — which accepts every byte
/// sequence — and save as UTF-8 with `\n`. So a binary file opened as mojibake and one keystroke
/// plus ⌘S destroyed it; a Windows-1252 file was silently transcoded; a CRLF file gained mixed
/// line endings on the first typed newline (2026-09-01 audit, H7). The invariant now: bytes the
/// user did not touch do not change, and a file that cannot be round-tripped is not editable.
enum TextFileCodec {
    enum LineEnding: Equatable { case lf, crlf }

    struct Format: Equatable {
        var encoding: String.Encoding
        var byteOrderMark: Bool
        var lineEnding: LineEnding

        static let utf8 = Format(encoding: .utf8, byteOrderMark: false, lineEnding: .lf)

        /// For the save-error message when a buffer can no longer be represented.
        var encodingName: String {
            switch encoding {
            case .utf8: return "UTF-8"
            case .utf16LittleEndian, .utf16BigEndian, .utf16: return "UTF-16"
            case .windowsCP1252: return "Windows-1252"
            default: return "\(encoding)"
            }
        }
    }

    struct Decoded { let text: String; let format: Format }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// A NUL anywhere in the first 8 KB, or a dense run of other control characters, and this is
    /// not text — no encoding makes it editable, however happily Latin-1 would decode it.
    static func looksBinary(_ data: Data) -> Bool {
        let window = data.prefix(8192)
        guard !window.isEmpty else { return false }
        var controls = 0
        for byte in window {
            if byte == 0 { return true }
            // Below 0x20 except tab, LF, FF, CR, and ESC (terminals write it into logs).
            if byte < 0x20, ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(byte) { controls += 1 }
        }
        return controls * 10 > window.count  // more than 10 % control bytes
    }

    /// Decodes to a buffer that always uses `\n`, remembering what it will take to write it back.
    /// UTF-16 is accepted only with a byte-order mark: without one, ASCII in UTF-16 is
    /// indistinguishable from a binary full of NULs, and guessing was how H7 happened.
    static func decode(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data.prefix(3))
        var format = Format.utf8
        var body = data
        if bytes.starts(with: utf8BOM) {
            format.byteOrderMark = true
            body = data.dropFirst(3)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            format = Format(encoding: .utf16LittleEndian, byteOrderMark: true, lineEnding: .lf)
            body = data.dropFirst(2)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            format = Format(encoding: .utf16BigEndian, byteOrderMark: true, lineEnding: .lf)
            body = data.dropFirst(2)
        } else if looksBinary(data) {
            return nil
        }
        var text: String
        if let decoded = String(data: body, encoding: format.encoding) {
            text = decoded
        } else if format.encoding == .utf8, let cp1252 = String(data: body, encoding: .windowsCP1252) {
            format.encoding = .windowsCP1252
            text = cp1252
        } else {
            return nil
        }
        // The dominant line ending is the file's; the buffer itself is normalised to `\n` so a
        // typed return can't introduce a second convention.
        let crlfCount = text.components(separatedBy: "\r\n").count - 1
        if crlfCount > 0 {
            let loneLF = text.components(separatedBy: "\n").count - 1 - crlfCount
            if crlfCount >= loneLF { format.lineEnding = .crlf }
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        return Decoded(text: text, format: format)
    }

    /// The inverse of `decode`. Nil when the buffer holds a character the file's encoding cannot
    /// represent — the caller must refuse the save rather than silently transcode.
    static func encode(_ text: String, as format: Format) -> Data? {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if format.lineEnding == .crlf { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        guard var data = body.data(using: format.encoding, allowLossyConversion: false) else { return nil }
        if format.byteOrderMark {
            switch format.encoding {
            case .utf8: data.insert(contentsOf: utf8BOM, at: 0)
            case .utf16LittleEndian: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            default: break
            }
        }
        return data
    }

    /// Writes `text` back in the shape the file on disk already has (or UTF-8 for a new file).
    static func write(_ text: String, to url: URL) throws {
        let format = (try? Data(contentsOf: url)).flatMap { decode($0)?.format } ?? .utf8
        guard let data = encode(text, as: format) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is \(format.encodingName) and the new content can't be represented in it."])
        }
        try data.write(to: url, options: .atomic)
    }
}
