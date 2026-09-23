import Foundation

public struct CoordinationSkill: Sendable {
    public static let operationalName = "chauffeur"
    public static let orchestratorName = "chauffeur-orchestrator"

    public let name: String
    public let displayName: String
    public let summary: String
    public let version: String
    public let dependencies: [String]
    public let document: Data
    public let referenceFiles: [String: Data]
    public var digest: String { JSONCoding.digest(document) }
    public var referenceDigests: [String: String] { referenceFiles.mapValues(JSONCoding.digest) }

    public init(
        name: String = CoordinationSkill.operationalName,
        displayName: String = "Chauffeur",
        summary: String = "Discover sessions, exchange messages, and control delegated work.",
        version: String,
        dependencies: [String] = [],
        document: Data,
        referenceFiles: [String: Data] = [:]
    ) throws {
        guard name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
              name.count <= 64,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              version.count <= 32, document.count <= 65_536,
              let text = String(data: document, encoding: .utf8),
              text.hasPrefix("---\nname: \(name)\n"), text.contains("  version: \"\(version)\"\n") else {
            throw ChauffeurError("skill_bundle", "The bundled \(name) skill is invalid")
        }
        self.name = name; self.displayName = displayName; self.summary = summary
        guard referenceFiles.keys.allSatisfy({ $0.hasPrefix("references/") && !$0.contains("..") && !$0.hasSuffix("/") }) else {
            throw ChauffeurError("skill_bundle", "The bundled \(name) skill has invalid reference paths")
        }
        self.version = version; self.dependencies = dependencies; self.document = document; self.referenceFiles = referenceFiles
    }

    public static func bundled() throws -> Self { try bundled(named: operationalName) }

    public static func bundled(named name: String) throws -> Self {
        let definitions: [String: (String, String, String, [String])] = [
            operationalName: ("Chauffeur", "Discover sessions, exchange messages, and control delegated work.", "1.3.0", []),
            orchestratorName: ("Chauffeur Orchestrator", "Execute a saved plan through sequential, visible Chauffeur workers.", "1.0.0", [operationalName])
        ]
        guard let definition = definitions[name] else { throw ChauffeurError("skill_bundle", "The requested bundled skill does not exist") }
        let appBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Chauffeur_ChauffeurCore.bundle")) }
        guard Bundle.main.bundleURL.pathExtension != "app" || appBundle != nil else {
            throw ChauffeurError("skill_bundle", "The bundled coordination skills are missing. Reinstall Chauffeur")
        }
        guard let url = (appBundle ?? Bundle.module).url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/\(name)") else {
            throw ChauffeurError("skill_bundle", "The bundled \(name) skill is missing. Reinstall Chauffeur")
        }
        var references: [String: Data] = [:]
        if name == orchestratorName {
            for role in ["default", "worker", "explorer", "fixer", "reviewer", "specialist"] {
                guard let roleURL = (appBundle ?? Bundle.module).url(forResource: role, withExtension: "md", subdirectory: "Skills/\(name)/references/roles") else {
                    throw ChauffeurError("skill_bundle", "The bundled \(role) role guidance is missing. Reinstall Chauffeur")
                }
                references["references/roles/\(role).md"] = try Data(contentsOf: roleURL)
            }
        }
        return try Self(name: name, displayName: definition.0, summary: definition.1, version: definition.2,
                        dependencies: definition.3, document: Data(contentsOf: url), referenceFiles: references)
    }

    public static func bundledCatalog() throws -> [Self] {
        try [bundled(named: operationalName), bundled(named: orchestratorName)]
    }
}

public struct SkillInstallation: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case notInstalled, installed, updateAvailable, conflict, unavailable }
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var summary: String
    public var dependencies: [String]
    public var state: State
    public var path: String
    public var bundledVersion: String
    public var installedVersion: String?
    public var message: String
    public var revision: String

    public init(name: String = CoordinationSkill.operationalName, displayName: String = "Chauffeur",
                summary: String = "Discover sessions, exchange messages, and control delegated work.", dependencies: [String] = [],
                state: State, path: String, bundledVersion: String, installedVersion: String? = nil, message: String, revision: String) {
        self.name = name; self.displayName = displayName; self.summary = summary; self.dependencies = dependencies
        self.state = state; self.path = path; self.bundledVersion = bundledVersion
        self.installedVersion = installedVersion; self.message = message; self.revision = revision
    }
}
