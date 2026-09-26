import Foundation

/// A JSON value to send: what the protocol leaves open (capabilities, a server's settings,
/// replies to its requests), written as a literal.
enum LSPValue: Encodable, Sendable, Equatable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LSPValue])
    case object([String: LSPValue])

    init(dictionaryLiteral elements: (String, LSPValue)...) { self = .object(Dictionary(elements) { $1 }) }
    init(arrayLiteral elements: LSPValue...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(nilLiteral: ()) { self = .null }

    /// From what `JSONSerialization` read: how a server's own values (a completion item's
    /// `data`, a request's `id`) go back to it unchanged.
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else if CFNumberIsFloatType(number) { self = .double(number.doubleValue) }
            else { self = .int(number.intValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { LSPValue(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { LSPValue(any: $0) })
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A reply's `result` as `JSONSerialization` read it, parsed once on the client's actor and
/// handed on without being written out and read again. Immutable once made.
struct LSPResult: @unchecked Sendable {
    let value: Any

    var object: [String: Any]? { value as? [String: Any] }
    var array: [Any]? { value as? [Any] }
    var isNull: Bool { value is NSNull }

    /// For the shapes that are simplest decoded by `Codable` (small ones: locations).
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard !isNull, JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
