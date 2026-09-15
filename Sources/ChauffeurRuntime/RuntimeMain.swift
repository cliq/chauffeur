import Foundation
import Darwin
import ChauffeurCore
import ChauffeurRuntimeKit

@main struct ChauffeurRuntimeMain {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            var root = Paths.applicationSupport
            var port: Int?
            while let option = args.first {
                args.removeFirst()
                switch option {
                case "--data-dir": guard !args.isEmpty else { throw ChauffeurError("usage", "--data-dir requires a path") }; root = URL(fileURLWithPath: args.removeFirst())
                case "--mcp-port": guard !args.isEmpty, let value = Int(args.removeFirst()), (0...65535).contains(value) else { throw ChauffeurError("usage", "--mcp-port requires 0–65535") }; port = value
                case "--help": print("ChauffeurRuntime [--data-dir PATH] [--mcp-port PORT]\nNormally started by Chauffeur's per-user LaunchAgent."); return
                default: throw ChauffeurError("usage", "Unknown runtime option")
                }
            }
            let ctl = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl").path
            guard FileManager.default.isExecutableFile(atPath: ctl) else { throw ChauffeurError("missing_helper", "Install chauffeurctl beside ChauffeurRuntime", path: ctl) }
            var environment = ProcessInfo.processInfo.environment
            // launchd has a minimal PATH. Query the user's login shell once;
            // per-child filtering still removes inherited profile/auth values.
            let shell = environment["SHELL"] ?? "/bin/zsh"
            if let login = try? await ProcessRunner.run(shell, ["-lic", "/usr/bin/env -0"], timeout: 10), login.status == 0 {
                for entry in login.output.split(separator: "\0") {
                    let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if pair.count == 2, !pair[0].contains("\n") { environment[String(pair[0])] = String(pair[1]) }
                }
            }
            let runtime = try RuntimeCoordinator(root: root, ctlPath: ctl, environment: environment)
            let server = try IPCServer(root: root, runtime: runtime)
            try await runtime.start()
            server.start()
            let recordedPort = (try? Data(contentsOf: root.appendingPathComponent("runtime/mcp-port.json"))).flatMap { try? JSONCoding.decode(Int.self, from: $0) }
            let reconcile = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)); try await runtime.reconcile() }
                    catch let error as ChauffeurError { await runtime.record(error) }
                    catch { break }
                }
            }
            defer { reconcile.cancel() }
            defer { _fixLifetime(server) }
            try await MCPServer.run(runtime: runtime, port: port ?? recordedPort ?? 0)
        } catch {
            let text = (error as? ChauffeurError)?.errorDescription ?? "Chauffeur runtime failed to start"
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(1)
        }
    }
}
