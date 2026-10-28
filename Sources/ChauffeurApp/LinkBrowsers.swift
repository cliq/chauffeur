import AppKit
import ChauffeurCore

/// A browser installed on this Mac that can open web links.
struct InstalledBrowser: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }

    /// Apps that open `https` links, the default browser first.
    static func all() -> [InstalledBrowser] {
        let probe = URL(string: "https://example.com")!
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: probe)
        var seen = Set<String>()
        let browsers = NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url -> InstalledBrowser? in
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, seen.insert(bundleID).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return InstalledBrowser(bundleID: bundleID, name: name, url: url)
        }
        return browsers.sorted { ($0.url == defaultApp ? 0 : 1, $0.name) < ($1.url == defaultApp ? 0 : 1, $1.name) }
    }
    static func named(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }
    /// The profiles a Chromium browser offers; empty for other browsers.
    static func profiles(_ bundleID: String) -> [ChromiumProfiles.Profile] {
        ChromiumProfiles.profiles(bundleID: bundleID, applicationSupport: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
    }
}

enum LinkOpener {
    /// Opens a link, sending web pages to the team's browser and profile when it set one.
    /// Other links, or a browser no longer installed, go to the system's handler.
    @MainActor static func open(_ url: URL, in browser: LinkBrowser?) {
        guard let browser, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            NSWorkspace.shared.open(url); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        let fallback: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            if error != nil { Task { @MainActor in NSWorkspace.shared.open(url) } }
        }
        guard let profile = browser.profileDirectory else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration, completionHandler: fallback)
            return
        }
        // Chromium takes the profile on its command line. Like `open -na`, the new
        // instance hands the link to a browser that is already running, then quits.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--profile-directory=\(profile)", url.absoluteString]
        NSWorkspace.shared.openApplication(at: app, configuration: configuration, completionHandler: fallback)
    }
}
