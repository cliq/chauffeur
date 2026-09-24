import Foundation

/// Models a provider listed during its capability probe (`opencode models`), kept per
/// executable and configuration directory. The runtime writes the file; the app and
/// `chauffeur_discover` read it for suggestions. Free text stays allowed.
public enum ModelSuggestionCache {
    struct Entry: Codable, Equatable {
        var kind: CLIKind
        var executable: String
        /// Empty for the provider's default configuration.
        var configurationDirectory: String
        var models: [String]
        var updatedAt: Date
    }
    /// The file the runtime under `root` writes.
    public static func url(root: URL) -> URL { root.appendingPathComponent("cache/model-suggestions.json") }
    public static var defaultURL: URL { url(root: Paths.applicationSupport) }
    /// Beyond this, a listing is not a curated set of suggestions.
    static let limit = 500

    public static func store(_ models: [String], kind: CLIKind, executable: String, configurationDirectory: String, at url: URL) throws {
        var entries = read(url).filter { !($0.kind == kind && $0.executable == executable && $0.configurationDirectory == configurationDirectory) }
        var seen = Set<String>()
        let unique = models.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit)
        entries.append(Entry(kind: kind, executable: executable, configurationDirectory: configurationDirectory, models: Array(unique), updatedAt: Date()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONCoding.encode(entries).write(to: url, options: .atomic)
    }

    /// The listing for one executable and directory when known, otherwise every
    /// listing for `kind`, newest first.
    public static func models(kind: CLIKind, executable: String? = nil, configurationDirectory: String? = nil, at url: URL = defaultURL) -> [String] {
        let entries = read(url).filter { $0.kind == kind }.sorted { $0.updatedAt > $1.updatedAt }
        if let exact = entries.first(where: { $0.executable == executable && $0.configurationDirectory == configurationDirectory }) { return exact.models }
        var seen = Set<String>()
        return entries.flatMap(\.models).filter { seen.insert($0).inserted }
    }

    private static func read(_ url: URL) -> [Entry] {
        (try? Data(contentsOf: url)).flatMap { try? JSONCoding.decode([Entry].self, from: $0) } ?? []
    }
}
