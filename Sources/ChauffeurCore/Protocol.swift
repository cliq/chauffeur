import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let value) = self { return value[key] ?? .null }; return .null }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var int: Int? { if case .number(let value) = self, value.isFinite, value >= Double(Int.min), value < Double(Int.max) { return Int(value) }; return nil }
    public var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    public func requiredString(_ key: String) throws -> String {
        guard let value = self[key].string, !value.isEmpty else { throw ChauffeurError("invalid_argument", "\(key) is required") }; return value
    }
    public func uuid(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try requiredString(key)) else { throw ChauffeurError("invalid_argument", "\(key) must be a UUID") }; return value
    }
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue { try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(value)) }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONCoding.decode(type, from: JSONCoding.encode(self)) }
}

public enum WireProtocol {
    public static let major = 1
    public static let maxFrameBytes = 8 * 1024 * 1024
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONCoding.encode(value)
        guard data.count <= maxFrameBytes else { throw ChauffeurError("frame_too_large", "IPC frame exceeds limit") }
        var size = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + data
    }
}

public struct IPCRequest: Codable, Sendable {
    public var version = WireProtocol.major
    public var id = UUID()
    public var method: String
    public var params: JSONValue
    public init(_ method: String, params: JSONValue = .object([:])) { self.method = method; self.params = params }
}
public struct IPCResponse: Codable, Sendable {
    public var version = WireProtocol.major
    public var id: UUID
    public var result: JSONValue?
    public var error: ChauffeurError?
    public init(id: UUID, result: JSONValue? = nil, error: ChauffeurError? = nil) { self.id = id; self.result = result; self.error = error }
}
