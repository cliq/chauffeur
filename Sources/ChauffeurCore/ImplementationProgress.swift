import Foundation

/// The skill's versioned, agent-independent progress document. Missing schemaVersion
/// identifies the original format; its completion estimate uses the same phase weights.
public struct ImplementationProgress: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case pending, active, done, blocked }
    public struct Step: Decodable, Equatable, Sendable {
        public let title: String
        public let state: State
    }
    public struct Phase: Decodable, Equatable, Sendable {
        public let title: String
        public let detail: String
        public let state: State
        public let steps: [Step]
    }
    public let schemaVersion: Int
    public let title: String
    public let subtitle: String
    public let now: String
    public let updated: Date
    public let phases: [Phase]
    public let percentComplete: Int

    private enum CodingKeys: String, CodingKey { case schemaVersion, title, subtitle, now, updated, phases, percentComplete }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: fields, debugDescription: "Unsupported progress schema")
        }
        title = try fields.decode(String.self, forKey: .title)
        subtitle = try fields.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        now = try fields.decode(String.self, forKey: .now)
        let timestamp = try fields.decode(String.self, forKey: .updated)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? formatter.date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(forKey: .updated, in: fields, debugDescription: "Expected an ISO 8601 timestamp")
        }
        updated = date
        phases = try fields.decode([Phase].self, forKey: .phases)
        let completed = phases.reduce(0.0) { count, phase in
            switch phase.state {
            case .done: count + 1
            case .active: count + (phase.steps.isEmpty ? 0.5 : Double(phase.steps.filter { $0.state == .done }.count) / Double(phase.steps.count))
            case .pending, .blocked: count
            }
        }
        let estimated = phases.isEmpty ? 0 : Int((100 * completed / Double(phases.count)).rounded())
        percentComplete = try fields.decodeIfPresent(Int.self, forKey: .percentComplete) ?? estimated
        guard (0...100).contains(percentComplete) else {
            throw DecodingError.dataCorruptedError(forKey: .percentComplete, in: fields, debugDescription: "Expected a percentage between 0 and 100")
        }
    }

    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

public struct ProgressRegistration: Codable, Equatable, Hashable, Sendable {
    public var jsonPath: String
    public var htmlPath: String?
    public init(jsonPath: String, htmlPath: String? = nil) { self.jsonPath = jsonPath; self.htmlPath = htmlPath }
}
