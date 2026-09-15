import AppKit
import SwiftUI
import ChauffeurCore

struct TerminalLauncherSettings: View {
    @State private var installed = false
    @State private var failure: String?
    private var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/chauffeur-launcher") }
    var body: some View {
        Section("Terminal Command") {
            Text("Run chauffeur from a project folder, or pass a folder path, to open its project.")
            HStack {
                Text("/usr/local/bin/chauffeur").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(installed ? "Installed" : "Install Terminal Command…") { install() }.disabled(installed)
            }
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            Text("Installing may require administrator access. If you move Chauffeur, install the command again from its new location.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { refresh() }
    }
    private func refresh() {
        installed = TerminalLauncherInstallation.isInstalled(executable: executable)
    }
    private func install() {
        failure = nil
        do {
            if FileManager.default.isWritableFile(atPath: TerminalLauncherInstallation.destination.deletingLastPathComponent().path) {
                try TerminalLauncherInstallation.install(executable: executable)
            } else {
                // Quote independently for the shell and AppleScript. No folder
                // or app path is interpreted as a shell command.
                let command = ArgumentText.format([executable.path, "--install"])
                let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                var error: NSDictionary?
                let script = NSAppleScript(source: "do shell script \"\(quoted)\" with administrator privileges")
                _ = script?.executeAndReturnError(&error)
                if let error { throw ChauffeurError("launcher_install", error[NSAppleScript.errorMessage] as? String ?? "Terminal command installation was cancelled") }
            }
            refresh()
            if !installed { failure = "The terminal command was not installed. Try again from this app’s current location." }
        } catch { failure = error.localizedDescription }
    }
}
