import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct TerminalStopRaceTests {
    @Test(arguments: [false, true])
    func disappearingSessionDuringStopIsAlreadyClosed(force: Bool) async throws {
        let fixture = try StopRaceFixture(disappears: true, dead: !force)
        defer { fixture.cleanup() }
        try await fixture.host.stop(sessionID: fixture.sessionID, force: force)
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(try await fixture.host.inventory().isEmpty)
        // Repeating close after retirement is also harmless.
        try await fixture.host.stop(sessionID: fixture.sessionID, force: true)
    }

    @Test func failedStopStillReportsAnExistingSession() async throws {
        let fixture = try StopRaceFixture(disappears: false)
        defer { fixture.cleanup() }
        await #expect(throws: ChauffeurError.self) {
            try await fixture.host.stop(sessionID: fixture.sessionID, force: true)
        }
        #expect(try await fixture.host.inventory().count == 1)
    }
}

private struct StopRaceFixture {
    let root: URL
    let marker: URL
    let sessionID: UUID
    let host: TmuxHost

    init(disappears: Bool, dead: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp/ch-stop-\(UUID())")
        marker = root.appendingPathComponent("stopped")
        sessionID = UUID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("tmux")
        // Model the interleaving deterministically: inventory sees a pane,
        // another actor retires it, then kill-session returns not found.
        let script = """
        #!/bin/sh
        case "$6" in
          list-panes)
            if [ "\(disappears)" = "false" ] || [ ! -f '\(marker.path)' ]; then
              printf '%s\\n' '\(sessionID.uuidString)|%0|1234|\(dead ? "1" : "0")|'
            fi
            ;;
          kill-session)
            touch '\(marker.path)'
            echo "can't find session" >&2
            exit 1
            ;;
          *) exit 2 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        host = try TmuxHost(runtimeDirectory: root, ctlPath: "/bin/false", environment: ["PATH": "\(root.path):/usr/bin:/bin"])
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
