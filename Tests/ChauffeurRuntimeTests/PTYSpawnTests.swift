import Foundation
import Testing
import CChauffeur

struct PTYSpawnTests {
    /// A terminal attachment's tmux client lives as long as the view. If it
    /// inherits another command's pipe, that command never sees EOF and fails
    /// with `command_pipe`.
    @Test func spawnedTerminalDoesNotInheritOtherPipes() throws {
        let unrelated = Pipe()
        let writer = unrelated.fileHandleForWriting.fileDescriptor
        defer { withExtendedLifetime(unrelated) {} }
        // dash, Linux's /bin/sh, rejects a multi-digit `>&N` as a syntax error and prints
        // nothing at all; opening the descriptor's /dev/fd path works in any shell. Open
        // it before any other redirection: shells save a redirected descriptor at 10 or
        // above, which could take the number being probed.
        let script = "if printf x > /dev/fd/\(writer); then echo INHERITED; else echo CLOSED; fi"
        let arguments: [String] = ["/bin/sh", "-c", script]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let pid = chauffeur_spawn_pty("/bin/sh", &argv, &envp, "/", &master, 80, 24)
        try #require(pid > 0)
        defer { close(master) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[..<count])
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(String(decoding: output, as: UTF8.self).contains("CLOSED"))
    }

    #if os(macOS)
    /// `launchctl limit maxfiles` can raise the descriptor limit to about two billion.
    /// Closing every number up to it kept each terminal on "Connecting" for minutes.
    @Test func spawnedTerminalStartsQuicklyUnderARaisedDescriptorLimitAndClosesHighDescriptors() throws {
        var original = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &original) == 0)
        var raised = original
        var maxPerProcess: Int32 = 0
        var length = MemoryLayout<Int32>.size
        if sysctlbyname("kern.maxfilesperproc", &maxPerProcess, &length, nil, 0) == 0 {
            raised.rlim_cur = min(original.rlim_max, rlim_t(maxPerProcess))
        }
        _ = setrlimit(RLIMIT_NOFILE, &raised)
        defer { _ = setrlimit(RLIMIT_NOFILE, &original) }

        let unrelated = Pipe()
        defer { withExtendedLifetime(unrelated) {} }
        let high = dup2(unrelated.fileHandleForWriting.fileDescriptor, 4000)
        try #require(high == 4000)
        defer { close(high) }
        let script = "if printf x > /dev/fd/\(high); then echo INHERITED; else echo CLOSED; fi"
        let arguments: [String] = ["/bin/sh", "-c", script]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let started = Date()
        let pid = chauffeur_spawn_pty("/bin/sh", &argv, &envp, "/", &master, 80, 24)
        try #require(pid > 0)
        defer { close(master) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            output.append(contentsOf: buffer[..<count])
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(String(decoding: output, as: UTF8.self).contains("CLOSED"))
    }
    #endif
}
