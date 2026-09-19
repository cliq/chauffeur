import Foundation
import Darwin
import Testing
@testable import ChauffeurCore
@testable import ChauffeurRuntimeKit

@Suite struct SetupLoginHostTests {
    @Test func outputInputResizeAndExitAreIndependentOfSessions() async throws {
        let host = SetupLoginHost()
        let operationID = UUID()
        let command = shellCommand("printf 'ready\\n'; IFS= read -r value; printf 'received:%s\\n' \"$value\"")
        let started = try await host.start(operationID: operationID, command: command)
        #expect(started.generation == 0)
        let attached = try await host.attach(operationID: operationID)
        try await host.resize(operationID: operationID, generation: attached.generation, cols: 90, rows: 24)
        try await host.input(operationID: operationID, generation: attached.generation, bytes: Data("hello\n".utf8))
        #expect(try await host.waitForExit(operationID: operationID) == 0)
        let output = try await host.read(operationID: operationID, generation: attached.generation, cursor: 0)
        let text = String(decoding: output.bytes, as: UTF8.self)
        #expect(text.contains("ready"))
        #expect(text.contains("received:hello"))
        #expect(output.running == false)
        #expect(output.exitStatus == 0)
    }

    @Test func detachKeepsLoginAliveAndReattachRevokesGeneration() async throws {
        let host = SetupLoginHost()
        let operationID = UUID()
        _ = try await host.start(operationID: operationID, command: shellCommand("IFS= read -r value; printf '%s\\n' \"$value\""))
        let first = try await host.attach(operationID: operationID)
        await host.detach(operationID: operationID, generation: first.generation)
        let second = try await host.attach(operationID: operationID)
        #expect(second.generation != first.generation)
        await #expect(throws: ChauffeurError.self) {
            try await host.input(operationID: operationID, generation: first.generation, bytes: Data("stale\n".utf8))
        }
        try await host.input(operationID: operationID, generation: second.generation, bytes: Data("continued\n".utf8))
        #expect(try await host.waitForExit(operationID: operationID) == 0)
        let output = try await host.read(operationID: operationID, generation: second.generation, cursor: 0)
        #expect(String(decoding: output.bytes, as: UTF8.self).contains("continued"))
    }

    @Test func oneLoginAtATimeAndCancelStopsProcessGroup() async throws {
        let host = SetupLoginHost()
        let firstID = UUID()
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-login-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        _ = try await host.start(operationID: firstID, command: shellCommand("sleep 30 & child=$!; printf '%s' \"$child\" > '\(pidFile.path)'; wait"))
        await #expect(throws: ChauffeurError.self) {
            _ = try await host.start(operationID: UUID(), command: shellCommand("exit 0"))
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let childPID = try #require(Int32(pidText))
        try await host.cancel(operationID: firstID)
        let handle = await host.status(operationID: firstID)
        #expect(handle?.phase == .failed)
        for _ in 0..<100 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(kill(childPID, 0) != 0)
    }

    @Test func boundedOutputReportsOldestAvailableCursor() async throws {
        let host = SetupLoginHost(outputLimit: 32, readLimit: 16)
        let operationID = UUID()
        _ = try await host.start(operationID: operationID, command: shellCommand("printf 'abcdefghijklmnopqrstuvwxyz0123456789'"))
        let attached = try await host.attach(operationID: operationID)
        _ = try await host.waitForExit(operationID: operationID)
        let first = try await host.read(operationID: operationID, generation: attached.generation, cursor: 0)
        #expect(first.oldestCursor > 0)
        #expect(first.nextCursor == first.oldestCursor + UInt64(first.bytes.count))
        let second = try await host.read(operationID: operationID, generation: attached.generation, cursor: first.nextCursor)
        #expect(second.bytes.count <= 16)
    }
}

private func shellCommand(_ source: String) -> SetupCommand {
    SetupCommand(
        executable: "/bin/sh",
        arguments: ["-c", source],
        directory: "/tmp",
        environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
    )
}
