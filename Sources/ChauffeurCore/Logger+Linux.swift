#if !canImport(OSLog)
import Foundation

/// The part of `os.Logger` the runtime uses, for platforms without OSLog. Lines go to
/// standard error, which systemd's journal records. Privacy follows the unified log's
/// defaults: `.private` values, and non-numeric `.auto` ones, are written as `<private>`.
public struct Logger: Sendable {
    public enum Privacy: Sendable { case `public`, `private`, auto }

    public struct Message: ExpressibleByStringInterpolation, Sendable {
        public struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
            public mutating func appendLiteral(_ literal: String) { text += literal }
            public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .auto) {
                switch privacy {
                case .public: text += "\(value)"
                case .private: text += "<private>"
                case .auto: text += value is any Numeric || value is Bool ? "\(value)" : "<private>"
                }
            }
        }
        let text: String
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
    }

    private let label: String
    public init(subsystem: String, category: String) { label = "\(subsystem).\(category)" }

    public func debug(_ message: Message) { write("debug", message) }
    public func info(_ message: Message) { write("info", message) }
    public func notice(_ message: Message) { write("notice", message) }
    public func warning(_ message: Message) { write("warning", message) }
    public func error(_ message: Message) { write("error", message) }
    public func fault(_ message: Message) { write("fault", message) }

    private func write(_ level: String, _ message: Message) {
        FileHandle.standardError.write(Data("[\(label)] \(level): \(message.text)\n".utf8))
    }
}
#endif
