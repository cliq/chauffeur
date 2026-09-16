import AppKit
import Darwin
import ChauffeurCore

@main struct ChauffeurLauncher {
    @MainActor static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] || arguments == ["-h"] {
                print("Usage: \(AppBuild.current.commandName) [FOLDER]\nOpens the project containing FOLDER (default: current directory).\nUse -- before a folder name beginning with a dash.\n\n\(AppBuild.current.commandName) --install   Install \(TerminalLauncherInstallation.destination.path)")
                return
            }
            let executable = try executableURL()
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard app.pathExtension == "app", FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Chauffeur").path) else {
                throw ChauffeurError("launcher_app", "Run the terminal command bundled inside \(AppBuild.current.displayName).app")
            }
            if arguments == ["--install"] {
                try TerminalLauncherInstallation.install(executable: executable)
                print("Installed \(TerminalLauncherInstallation.destination.path)")
                return
            }
            if arguments.first == "--" { arguments.removeFirst() }
            else if arguments.first?.hasPrefix("-") == true { throw ChauffeurError("usage", "Unknown option. Run \(AppBuild.current.commandName) --help") }
            guard arguments.count <= 1 else { throw ChauffeurError("usage", "Pass one folder, quoting paths that contain spaces") }
            let input = ((arguments.first ?? FileManager.default.currentDirectoryPath) as NSString).expandingTildeInPath
            let path = try Paths.directory(URL(fileURLWithPath: input, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).standardizedFileURL.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([FolderRoute(path: path).url], withApplicationAt: app, configuration: configuration)
        } catch {
            FileHandle.standardError.write(Data(((error as? ChauffeurError)?.errorDescription ?? error.localizedDescription).utf8) + Data("\n".utf8))
            exit(1)
        }
    }
    private static func executableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw ChauffeurError("launcher_app", "Cannot locate the Chauffeur app") }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath()
    }
}
