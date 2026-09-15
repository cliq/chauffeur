import Foundation
import Darwin
import ChauffeurCore

public struct CommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    public var outputTruncated = false
}
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], directory: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 15, outputLimit: Int = 4 * 1024 * 1024, keepOutputTail: Bool = false) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try runSync(executable, arguments, directory: directory, environment: environment, timeout: timeout, outputLimit: outputLimit, keepOutputTail: keepOutputTail)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func runSync(_ executable: String, _ arguments: [String], directory: String?, environment: [String: String]?, timeout: TimeInterval, outputLimit: Int, keepOutputTail: Bool) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let outputReader = BoundedReader(limit: outputLimit, keepTail: keepOutputTail), errorReader = BoundedReader()
        try process.run()
        let readers = DispatchGroup()
        readers.enter(); DispatchQueue.global().async { outputReader.read(output.fileHandleForReading); readers.leave() }
        readers.enter(); DispatchQueue.global().async { errorReader.read(errors.fileHandleForReading); readers.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            // Helpers may have descendants holding a pipe. Closing our read
            // descriptors makes their lifetimes independent from this timeout.
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            throw ChauffeurError("command_timeout", "Command exceeded its time limit", path: executable)
        }
        process.waitUntilExit()
        guard readers.wait(timeout: .now() + 1) == .success else {
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            throw ChauffeurError("command_pipe", "Command left an output pipe open", path: executable)
        }
        return CommandResult(status: process.terminationStatus, output: outputReader.text, error: errorReader.text, outputTruncated: outputReader.truncated)
    }
}
private final class BoundedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private let keepTail: Bool
    private var wasTruncated = false
    init(limit: Int = 4 * 1024 * 1024, keepTail: Bool = false) { self.limit = max(1, limit); self.keepTail = keepTail }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return wasTruncated }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func read(_ file: FileHandle) {
        while let chunk = try? file.read(upToCount: 65_536), !chunk.isEmpty {
            lock.lock()
            if data.count + chunk.count > limit { wasTruncated = true }
            if keepTail {
                data.append(chunk)
                if data.count > limit { data.removeFirst(data.count - limit) }
            } else if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
            lock.unlock()
        }
    }
}
