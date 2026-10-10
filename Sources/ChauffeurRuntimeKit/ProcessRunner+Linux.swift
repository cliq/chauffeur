#if os(Linux)
import Foundation
import Glibc
import CChauffeur
import ChauffeurCore

/// Foundation's `Process` on Linux can't run the runtime's commands. It learns that a child
/// exited through a socket the child inherits, so a child that daemonizes (the tmux server
/// `new-session` starts) holds it open and the command never finishes, keeping its pipes
/// open meanwhile; and the child inherits the calling thread's signal mask, which blocks
/// SIGCHLD in tmux. Commands start through `chauffeur_spawn` instead, and this thread alone
/// signals and reaps the child, so it never signals a process ID after reaping it.
extension ProcessRunner {
    static func runSync(_ executable: String, _ arguments: [String], directory: String?, environment: [String: String]?, timeout: TimeInterval, outputLimit: Int, keepOutputTail: Bool, cancellation: CommandCancellation) throws -> CommandResult {
        if cancellation.isCancelled { throw CancellationError() }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw ChauffeurError("command_failed", "Cannot start the command", path: executable) }
        defer { close(input) }
        let output = try pipe(for: executable)
        let errors: (read: Int32, write: Int32)
        do { errors = try pipe(for: executable) } catch { close(output.read); close(output.write); throw error }
        let environment = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let pid = withCStrings([executable] + arguments) { argv in
            withCStrings(environment) { envp in
                chauffeur_spawn(executable, argv, envp, directory, input, output.write, errors.write)
            }
        }
        close(output.write); close(errors.write)
        guard pid > 0 else {
            close(output.read); close(errors.read)
            throw ChauffeurError("command_failed", "Cannot start the command", path: executable)
        }

        let outputReader = BoundedReader(limit: outputLimit, keepTail: keepOutputTail), errorReader = BoundedReader()
        // Readers close their descriptor once they stop, at end of file or when told to.
        let stopReading = CommandCancellation()
        defer { stopReading.cancel() }
        let readers = DispatchGroup()
        for (descriptor, reader) in [(output.read, outputReader), (errors.read, errorReader)] {
            readers.enter()
            Thread.detachNewThread { drain(descriptor, into: reader, until: stopReading); readers.leave() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var exited = false, pause: useconds_t = 500
        while !exited && !cancellation.isCancelled && Date() < deadline {
            exited = try reap(pid, &status, blocking: false)
            if !exited { usleep(pause); pause = min(pause * 2, 10_000) }
        }
        if !exited {
            kill(pid, SIGTERM)
            let stopDeadline = Date().addingTimeInterval(1)
            while !exited && Date() < stopDeadline {
                exited = try reap(pid, &status, blocking: false)
                if !exited { usleep(10_000) }
            }
            if !exited { kill(pid, SIGKILL); _ = try reap(pid, &status, blocking: true) }
            if cancellation.isCancelled { throw CancellationError() }
            throw ChauffeurError("command_timeout", "Command exceeded its time limit", path: executable)
        }
        if cancellation.isCancelled { throw CancellationError() }
        // Helpers may leave descendants holding a pipe; don't wait on their lifetimes.
        guard readers.wait(timeout: .now() + 1) == .success else {
            throw ChauffeurError("command_pipe", "Command left an output pipe open", path: executable)
        }
        // Like `Process.terminationStatus`: the exit code, or the signal that ended the child.
        let signal = status & 0x7f
        return CommandResult(status: signal == 0 ? (status >> 8) & 0xff : signal, output: outputReader.text, error: errorReader.text, outputTruncated: outputReader.truncated)
    }

    /// True once the child has exited and been reaped. Any other failure is an error rather
    /// than success: this runner is the child's only reaper.
    private static func reap(_ pid: pid_t, _ status: inout Int32, blocking: Bool) throws -> Bool {
        while true {
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if result == pid { return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw ChauffeurError("command_failed", "Lost track of the command's process")
        }
    }

    private static func pipe(for executable: String) throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard chauffeur_pipe(&descriptors) == 0 else { throw ChauffeurError("command_failed", "Cannot start the command", path: executable) }
        return (descriptors[0], descriptors[1])
    }

    /// Polls rather than blocking in `read`, so a reader can be stopped while a descendant
    /// still holds the pipe; on Linux, closing a descriptor doesn't wake a blocked read.
    private static func drain(_ descriptor: Int32, into reader: BoundedReader, until stop: CommandCancellation) {
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while !stop.isCancelled {
            let ready = poll(&item, 1, 50)
            if ready < 0 && errno != EINTR { return }
            guard ready > 0 else { continue }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { reader.append(Data(buffer[..<count])) }
            else if count == 0 || errno != EINTR { return }
        }
    }

    /// A NULL-terminated array of C strings, valid for the duration of `body`.
    private static func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
#endif
