import Foundation

/// The browser a team opens web links in, such as Chrome with a work profile.
public struct LinkBrowser: Codable, Equatable, Sendable {
    /// The browser app's bundle identifier.
    public var bundleID: String
    /// A Chromium profile directory, such as `Profile 1`; nil leaves the profile to the browser.
    public var profileDirectory: String?
    public init(bundleID: String, profileDirectory: String? = nil) {
        self.bundleID = bundleID; self.profileDirectory = profileDirectory
    }
    func validate() throws {
        try Validation.require(!bundleID.isEmpty && !bundleID.contains("\0"), "Choose a browser")
        if let profileDirectory { try Validation.require(!profileDirectory.isEmpty && !profileDirectory.contains("\0"), "Choose a browser profile") }
    }
}

/// Profiles of Chromium browsers, which take one on the command line.
public enum ChromiumProfiles {
    public struct Profile: Equatable, Sendable, Identifiable {
        /// The directory name the browser's `--profile-directory` takes.
        public var directory: String
        /// The name the browser shows for it.
        public var name: String
        /// The account signed in to it, if any.
        public var account: String?
        /// The name, with the account or directory where names alone would be ambiguous.
        public var label: String
        public var id: String { directory }
        public init(directory: String, name: String, account: String? = nil, label: String? = nil) {
            self.directory = directory; self.name = name; self.account = account; self.label = label ?? name
        }
    }
    /// Where each known Chromium browser keeps its data, under Application Support.
    public static let dataDirectories = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]
    /// The profiles a browser's `Local State` file lists, by name; empty for other browsers or an unreadable file.
    public static func profiles(bundleID: String, applicationSupport: URL) -> [Profile] {
        guard let directory = dataDirectories[bundleID],
              let data = try? Data(contentsOf: applicationSupport.appendingPathComponent(directory).appendingPathComponent("Local State")) else { return [] }
        return profiles(localState: data)
    }
    public static func profiles(localState: Data) -> [Profile] {
        guard let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        var profiles = cache.map { directory, info -> Profile in
            let info = info as? [String: Any]
            let account = (info?["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(directory: directory, name: (info?["name"] as? String) ?? directory, account: account)
        }
        // Several profiles often share a name, such as a company domain; their accounts tell them apart.
        let names = Dictionary(grouping: profiles, by: \.name)
        for index in profiles.indices where names[profiles[index].name]!.count > 1 {
            profiles[index].label = "\(profiles[index].name) (\(profiles[index].account ?? profiles[index].directory))"
        }
        let labels = Dictionary(grouping: profiles, by: \.label)
        for index in profiles.indices where labels[profiles[index].label]!.count > 1 {
            profiles[index].label = "\(profiles[index].name) (\(profiles[index].directory))"
        }
        return profiles.sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.directory < $1.directory : order == .orderedAscending
        }
    }
}
