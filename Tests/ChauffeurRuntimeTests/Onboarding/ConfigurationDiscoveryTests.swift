import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct ConfigurationDiscoveryTests {
    @Test func inventoryIsBoundedAndUsesEffectiveOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-config-discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let currentCodex = root.appendingPathComponent("profiles/codex current")
        for directory in [home.appendingPathComponent(".claude-work"), home.appendingPathComponent(".codexwho-client"), bin, currentCodex] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let codex = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let missingImported = root.appendingPathComponent("missing/claude fixture")
        let discovery = ConfigurationDiscovery(
            home: home,
            environment: ["PATH": bin.path, "CODEX_HOME": currentCodex.path],
            configuredPaths: [CLIKind.claude.rawValue: [missingImported.path]]
        )

        let inventory = try discovery.inventory()

        #expect(inventory.homePath == Paths.canonical(home.path))
        #expect(inventory.executables[CLIKind.codex.rawValue] == Paths.canonical(codex.path))
        #expect(inventory.missingAgents == [.claude])
        #expect(inventory.configurations.contains { $0.kind == .codex && $0.path == Paths.canonical(currentCodex.path) && $0.isCurrent && $0.available })
        #expect(inventory.configurations.contains { $0.path == Paths.canonical(missingImported.path) && !$0.available })
        #expect(inventory.configurations.contains { $0.path.hasSuffix(".claude-work") })
        #expect(inventory.configurations.contains { $0.path.hasSuffix(".codexwho-client") })
    }

    @Test func nestedAndEqualDestinationsAreRejected() throws {
        let discovery = ConfigurationDiscovery(home: URL(fileURLWithPath: "/tmp"), environment: [:], configuredPaths: [:])
        #expect(throws: ChauffeurError.self) {
            try discovery.validateDestination(source: "/tmp/source", destination: "/tmp/source/work", reserved: [])
        }
        #expect(throws: ChauffeurError.self) {
            try discovery.validateDestination(source: "/tmp/destination/source", destination: "/tmp/destination", reserved: [])
        }
        #expect(throws: ChauffeurError.self) {
            try discovery.validateDestination(source: "/tmp/source", destination: "/tmp/source", reserved: [])
        }
    }

    @Test func destinationsResolveParentSymlinksAndFoldReservedNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-destination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let discovery = ConfigurationDiscovery(home: root, environment: [:], configuredPaths: [:])

        let resolved = try discovery.validateDestination(source: nil, destination: alias.appendingPathComponent("Client Profile").path, reserved: [])
        #expect(resolved == Paths.canonical(actual.appendingPathComponent("Client Profile").path))
        #expect(throws: ChauffeurError.self) {
            try discovery.validateDestination(
                source: nil,
                destination: alias.appendingPathComponent("WÖRK").path,
                reserved: [actual.appendingPathComponent("wörk").path]
            )
        }
        try FileManager.default.createDirectory(at: actual.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        #expect(throws: ChauffeurError.self) {
            try discovery.validateDestination(source: nil, destination: alias.appendingPathComponent("occupied").path, reserved: [])
        }
    }
}
