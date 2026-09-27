import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct KimiInitialTaskTests {
    @Test func launchReturnsBeforeWorkspaceTrustAndDeliversWhenReady() async throws {
        let fixture = try await LaunchFixture.make(kind: .kimi)
        defer { fixture.cleanup() }
        let executable = fixture.path("fixture.py")
        var script = try String(contentsOf: executable, encoding: .utf8)
        script = script.replacingOccurrences(of: "print('1.18.32' if (root / 'opencode').exists() else '2.1.272 (Claude Code)')", with: "print('2.1.1')")
        script = script.replacingOccurrences(of: "else: print('--resume --add-dir')", with: "else: print('Usage: kimi [options] --auto --agent-file --session --add-dir')")
        script = script.replacingOccurrences(of: "mark('started', os.getpid())", with: #"""
        mark('started', os.getpid())
            print('Trust this folder?', flush=True)
            while not (root / 'allow-input').exists(): time.sleep(0.01)
            print('\x1b[2J\x1b[H ╭────────────╮\n │ >          │\n ╰────────────╯\x1b[2;6H', end='', flush=True)
            mark('received-task', sys.stdin.readline().strip())
        """#)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var request = fixture.request; request.task = "Do the requested task"
        let launchRequest = request
        let launch = Task {
            let session = try await fixture.runtime.launch(launchRequest)
            try Data().write(to: fixture.path("launch-returned"))
            return session
        }
        defer { launch.cancel() }
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("launch-returned").path) }
        let session = try await launch.value
        #expect(session.state.isLive)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("received-task").path))
        try Data().write(to: fixture.path("allow-input"))
        try await fixture.wait { (try? String(contentsOf: fixture.path("received-task"), encoding: .utf8).isEmpty) == false }
        #expect(try String(contentsOf: fixture.path("received-task"), encoding: .utf8) == "Do the requested task")
    }
}
