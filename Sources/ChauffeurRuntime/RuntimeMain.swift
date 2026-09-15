import Foundation
import Darwin
import OSLog
import ChauffeurCore
import ChauffeurRuntimeKit

@main struct ChauffeurRuntimeMain {
    static func main() async {
        var logs: RuntimeLogStore?
        let runtimeID = UUID()
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
            logs = try? RuntimeLogStore(root: RuntimeLogStore.directory(for: root))
            // launchd may supply the bundle-relative BundleProgram as argv[0].
            // Resolve the loaded executable, independently of that argument and cwd.
            var executableSize: UInt32 = 0
            _NSGetExecutablePath(nil, &executableSize)
            var executableBytes = [CChar](repeating: 0, count: Int(executableSize))
            guard _NSGetExecutablePath(&executableBytes, &executableSize) == 0 else { throw ChauffeurError("missing_helper", "Cannot locate the running runtime executable") }
            let executablePath = String(decoding: executableBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            let ctl = executable.deletingLastPathComponent().appendingPathComponent("chauffeurctl").path
            guard FileManager.default.isExecutableFile(atPath: ctl) else { throw ChauffeurError("missing_helper", "Install chauffeurctl beside ChauffeurRuntime", path: ctl) }
            var environment = ProcessInfo.processInfo.environment
            var loginEnvironmentLoaded = false
            // launchd has a minimal PATH. Query the user's login shell once;
            // per-child filtering still removes inherited profile/auth values.
            let shell = environment["SHELL"] ?? "/bin/zsh"
            if let login = try? await ProcessRunner.run(shell, ["-lic", "/usr/bin/env -0"], timeout: 10), login.status == 0 {
                loginEnvironmentLoaded = true
                for entry in login.output.split(separator: "\0") {
                    let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if pair.count == 2, !pair[0].contains("\n") { environment[String(pair[0])] = String(pair[1]) }
                }
            }
            // launchd's PATH excludes common CLI installation directories. Keep
            // the user's ordering, but remain usable if shell startup fails.
            var searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !searchPaths.contains(path) { searchPaths.append(path) }
            environment["PATH"] = searchPaths.joined(separator: ":")
            let runtime = try RuntimeCoordinator(root: root, ctlPath: ctl, environment: environment, logs: logs, id: runtimeID)
            if !loginEnvironmentLoaded { await runtime.record(ChauffeurError("login_environment_unavailable", "Could not load the login-shell environment. Using inherited environment and standard executable search paths; select full CLI paths if needed")) }
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
            let history = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                    await runtime.maintainHistory()
                }
            }
            let repositories = Task {
                while !Task.isCancelled {
                    await runtime.reconcileWorktrees()
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                }
            }
            defer { reconcile.cancel(); history.cancel(); repositories.cancel() }
            defer { _fixLifetime(server) }
            try await MCPServer.run(runtime: runtime, port: port ?? recordedPort ?? 0)
        } catch {
            // Startup failures can happen before our socket or file store exists.
            // Keep the system log free of command output, paths, and user data.
            let code = DiagnosticCode.redacting((error as? ChauffeurError)?.code ?? "startup_failed").rawValue
            var entry = RuntimeLogEntry(.startupFailed, runtimeID: runtimeID); entry.code = DiagnosticCode(rawValue: code)
            logs?.append(entry)
            Logger(subsystem: "dev.chauffeur.runtime", category: "startup").error("Runtime startup failed: \(code, privacy: .public)")
            let text = "Chauffeur runtime failed to start [\(code)]"
            FileHandle.standardError.write(Data((text + "\n").utf8))
            exit(1)
        }
    }
}
