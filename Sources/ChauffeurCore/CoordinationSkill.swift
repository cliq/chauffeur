import Foundation

public struct CoordinationSkill: Sendable {
    public let version: String
    public let document: Data
    public var digest: String { JSONCoding.digest(document) }

    public init(version: String, document: Data) throws {
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              version.count <= 32, document.count <= 65_536,
              let text = String(data: document, encoding: .utf8),
              text.hasPrefix("---\nname: chauffeur\n"), text.contains("  version: \"\(version)\"\n") else {
            throw ChauffeurError("skill_bundle", "The bundled coordination skill is invalid")
        }
        self.version = version; self.document = document
    }

    public static func bundled() throws -> Self {
        // The app's SwiftPM resource bundle also serves its embedded command-line
        // helpers. Standalone SwiftPM executables use their companion bundle.
        let appBundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Chauffeur_ChauffeurCore.bundle")) }
        guard Bundle.main.bundleURL.pathExtension != "app" || appBundle != nil else {
            throw ChauffeurError("skill_bundle", "The bundled coordination skill is missing. Reinstall Chauffeur")
        }
        guard let url = (appBundle ?? Bundle.module).url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/chauffeur") else {
            throw ChauffeurError("skill_bundle", "The bundled coordination skill is missing. Reinstall Chauffeur")
        }
        return try Self(version: "1.0.0", document: Data(contentsOf: url))
    }
}

public struct SkillInstallation: Codable, Sendable {
    public enum State: String, Codable, Sendable { case notInstalled, installed, updateAvailable, conflict, unavailable }
    public var state: State
    public var path: String
    public var bundledVersion: String
    public var installedVersion: String?
    public var message: String
    // Sent back on mutation: a sheet cannot act on a different profile after an
    // external preset edit, or overwrite a changed installation after review.
    public var revision: String

    public init(state: State, path: String, bundledVersion: String, installedVersion: String? = nil, message: String, revision: String) {
        self.state = state; self.path = path; self.bundledVersion = bundledVersion
        self.installedVersion = installedVersion; self.message = message; self.revision = revision
    }
}
