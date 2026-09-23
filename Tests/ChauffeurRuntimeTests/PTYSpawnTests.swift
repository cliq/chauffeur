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
        let script = "if { printf x >&\(writer); } 2>/dev/null; then echo INHERITED; else echo CLOSED; fi"
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
}
