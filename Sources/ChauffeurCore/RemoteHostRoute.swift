import Foundation

/// Opens a paired remote server's window, or the Remote Servers window when `hostID` is nil.
public struct RemoteHostRoute: Equatable, Sendable {
    public var hostID: UUID?
    public init(hostID: UUID?) { self.hostID = hostID }
    public var url: URL {
        URL(string: "\(AppBuild.current.urlScheme)://remote-host" + (hostID.map { "/\($0.uuidString)" } ?? ""))!
    }
    public init?(url: URL) {
        guard url.scheme == AppBuild.current.urlScheme, url.host == "remote-host" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count <= 1 else { return nil }
        if let id = parts.first {
            guard let hostID = UUID(uuidString: id) else { return nil }
            self.hostID = hostID
        } else { self.hostID = nil }
    }
}

/// The paired remote servers' names, without their credentials, for menus that only open their windows.
public struct RemoteHostListing: Codable, Equatable, Sendable, Identifiable {
    public var hostID: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var id: UUID { hostID }
    /// Where the app saves paired servers (mode 0600, written by `ChauffeurApp`).
    public static var fileURL: URL { Paths.applicationSupport.appendingPathComponent("remote-hosts.json") }
    public static func load(from url: URL = fileURL) -> [RemoteHostListing] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteHostListing].self, from: data)) ?? []
    }
}
