import Foundation

public enum RuntimeConnectionPolicy {
    /// Agent terminals inherit the managed socket. Only a different destination
    /// opts the app out of bundled service registration and identity verification.
    public static func usesCustomSocket(_ configured: String?, defaultSocket: String) -> Bool {
        guard let configured else { return false }
        return Paths.canonical(configured) != Paths.canonical(defaultSocket)
    }
}

public enum AppBuild: String, Codable, Sendable, CaseIterable {
    case debug = "Debug", release = "Release"

    #if DEBUG
    public static let current = AppBuild.debug
    #else
    public static let current = AppBuild.release
    #endif

    public var displayName: String { self == .debug ? "Chauffeur Debug" : "Chauffeur" }
    public var serviceLabel: String { self == .debug ? "dev.chauffeur.debug.runtime" : "dev.chauffeur.runtime" }
    public var notificationIdentifier: String { self == .debug ? "dev.chauffeur.debug.notifications" : "dev.chauffeur.notifications" }
    public var urlScheme: String { self == .debug ? "chauffeur-debug" : "chauffeur" }
    public var commandName: String { urlScheme }
    public var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(displayName)", isDirectory: true)
    }
    /// Where new managed Git checkouts are created. A dot directory in the home
    /// folder keeps the path free of spaces, which tools launched inside a
    /// worktree do not always quote correctly. Checkouts created under the
    /// Application Support store before this change stay managed there.
    public var worktreeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(self == .debug ? ".chauffeur-debug/worktrees" : ".chauffeur/worktrees", isDirectory: true)
    }
}

/// Captured once when the runtime starts, before an app update can replace its
/// executable on disk. A version number alone cannot identify a running build.
public struct RuntimeIdentity: Codable, Sendable, Equatable {
    public let build: AppBuild
    public let executablePath: String
    public let executableDigest: String
    public let dataRoot: String

    public init(build: AppBuild = .current, executable: URL, dataRoot: URL) throws {
        self.build = build
        executablePath = Paths.canonical(executable.path)
        executableDigest = JSONCoding.digest(try Data(contentsOf: executable, options: .mappedIfSafe))
        self.dataRoot = Paths.canonical(dataRoot.path)
    }

    /// Includes the app's location: moving an unchanged bundle still requires
    /// refreshing launchd's registration, which can retain its old location.
    public func registrationFingerprint(plist: Data) -> String {
        JSONCoding.digest(Data((executablePath + "\n" + executableDigest + "\n" + build.rawValue + "\n" + dataRoot).utf8)) + ":" + JSONCoding.digest(plist)
    }
}
