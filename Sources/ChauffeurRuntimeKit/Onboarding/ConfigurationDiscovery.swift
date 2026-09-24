import Foundation
import ChauffeurCore

public struct ConfigurationDiscovery: Sendable {
    private let home: URL
    private let environment: [String: String]
    private let configuredPaths: [String: [String]]

    public init(home: URL, environment: [String: String], configuredPaths: [String: [String]]) {
        self.home = home.standardizedFileURL
        self.environment = environment
        self.configuredPaths = configuredPaths
    }

    public func inventory() throws -> SetupInventory {
        let manager = FileManager.default
        var configurations: [DiscoveredConfiguration] = []
        var indices: [String: Int] = [:]

        func add(kind: CLIKind, path: String, current: Bool) {
            let canonical = Paths.canonical(path)
            let key = kind.rawValue + "\0" + canonical
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: canonical, isDirectory: &isDirectory)
            let available = exists && isDirectory.boolValue
                && manager.isReadableFile(atPath: canonical)
                && manager.isExecutableFile(atPath: canonical)
            if let index = indices[key] {
                configurations[index].isCurrent = configurations[index].isCurrent || current
                configurations[index].available = configurations[index].available || available
                return
            }
            indices[key] = configurations.count
            configurations.append(DiscoveredConfiguration(
                kind: kind,
                path: canonical,
                displayName: displayName(kind: kind, path: canonical, current: current),
                isCurrent: current,
                available: available
            ))
        }

        for kind in CLIKind.onboardingKinds where kind.isAgent {
            let current = effectivePath(for: kind)
            add(kind: kind, path: current, current: true)
            let standardName = kind.provider?.defaultHomeFolder ?? ".\(kind.rawValue)"
            add(kind: kind, path: home.appendingPathComponent(standardName).path, current: Paths.canonical(current) == Paths.canonical(home.appendingPathComponent(standardName).path))
            for path in configuredPaths[kind.rawValue] ?? [] { add(kind: kind, path: path, current: Paths.canonical(path) == Paths.canonical(current)) }
        }

        let children = (try? manager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        for child in children {
            let name = child.lastPathComponent
            guard let kind = candidateKind(name: name) else { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            add(kind: kind, path: child.path, current: Paths.canonical(child.path) == Paths.canonical(effectivePath(for: kind)))
        }

        configurations.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        var executables: [String: String] = [:]
        var missingAgents: [CLIKind] = []
        for kind in CLIKind.onboardingKinds where kind.isAgent {
            let override = environment["CHAUFFEUR_\(kind.rawValue.uppercased())_EXECUTABLE"]
            do {
                // Validate now, but persist the stable command/symlink rather than
                // a versioned installation target that an auto-update removes.
                let command = override ?? kind.rawValue
                _ = try Paths.executable(command, environment: environment)
                executables[kind.rawValue] = command
            }
            catch { missingAgents.append(kind) }
        }
        return SetupInventory(
            homePath: Paths.canonical(home.path),
            configurations: configurations,
            executables: executables,
            missingAgents: missingAgents
        )
    }

    public func validateDestination(source: String?, destination: String, reserved: [String]) throws -> String {
        try Validation.absolutePath(destination)
        let manager = FileManager.default
        let canonicalDestination = Paths.canonical(destination)
        if let source {
            try Validation.absolutePath(source)
            let canonicalSource = Paths.canonical(source)
            guard collisionKey(canonicalSource) != collisionKey(canonicalDestination) else {
                throw ChauffeurError("same_configuration_path", "Source and destination must be different", path: destination)
            }
            guard !contains(collisionKey(canonicalSource), collisionKey(canonicalDestination)),
                  !contains(collisionKey(canonicalDestination), collisionKey(canonicalSource)) else {
                throw ChauffeurError("nested_configuration_path", "Source and destination cannot contain one another", path: destination)
            }
        }
        let foldedDestination = collisionKey(canonicalDestination)
        guard !reserved.map({ collisionKey(Paths.canonical($0)) }).contains(foldedDestination) else {
            throw ChauffeurError("reserved_configuration_path", "Another setup configuration uses this destination", path: destination)
        }
        guard !manager.fileExists(atPath: canonicalDestination) else {
            throw ChauffeurError("destination_exists", "Destination already exists. Choose it as an existing folder or select another destination", path: destination)
        }
        var parent = URL(fileURLWithPath: canonicalDestination).deletingLastPathComponent()
        while !manager.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              manager.isWritableFile(atPath: parent.path), manager.isExecutableFile(atPath: parent.path) else {
            throw ChauffeurError("unwritable_destination", "Destination parent is not writable", path: parent.path)
        }
        let destinationParent = URL(fileURLWithPath: canonicalDestination).deletingLastPathComponent()
        if manager.fileExists(atPath: destinationParent.path) {
            let requested = collisionKey(URL(fileURLWithPath: canonicalDestination).lastPathComponent)
            let siblings = try manager.contentsOfDirectory(atPath: destinationParent.path)
            guard !siblings.contains(where: { collisionKey($0) == requested }) else {
                throw ChauffeurError("destination_exists", "A destination with this name already exists", path: destination)
            }
        }
        return canonicalDestination
    }

    private func effectivePath(for kind: CLIKind) -> String {
        let fallback = home.appendingPathComponent(kind.provider?.defaultHomeFolder ?? ".\(kind.rawValue)").path
        // OpenCode's variable adds a layer; the global directory stays current.
        guard kind != .opencode, let variable = kind.provider?.configurationEnvironmentKey else { return Paths.canonical(fallback) }
        return Paths.canonical(environment[variable] ?? fallback)
    }

    private func candidateKind(name: String) -> CLIKind? {
        if name.hasPrefix(".claude-") || name.hasPrefix(".claudewho-") { return .claude }
        if name.hasPrefix(".codex-") || name.hasPrefix(".codexwho-") { return .codex }
        return nil
    }

    private func displayName(kind: CLIKind, path: String, current: Bool) -> String {
        if current { return "Current \(kind.displayName)" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func contains(_ parent: String, _ child: String) -> Bool {
        parent == "/" ? child != "/" : child.hasPrefix(parent + "/")
    }

    private func collisionKey(_ path: String) -> String {
        path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
