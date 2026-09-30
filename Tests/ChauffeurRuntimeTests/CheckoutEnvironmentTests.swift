import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CheckoutEnvironmentTests {
    @Test func checkoutRootsNameTheMainCheckoutFromLinkedWorktreesAndSubdirectories() async throws {
        let root = URL(fileURLWithPath: Paths.canonical("/tmp")).appendingPathComponent("chauffeur-checkout-roots-\(UUID())")
        let main = root.appendingPathComponent("main"), linked = root.appendingPathComponent("linked"), plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ directory: URL, _ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args)
            try #require(result.status == 0, "Git fixture failed: \(result.error)")
        }
        try await git(main, ["init", "-b", "main"])
        try await git(main, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        try await git(main, ["worktree", "add", "-b", "task", linked.path])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let fromMain = try #require(await manager.checkoutRoots(at: main.appendingPathComponent("Sources").path))
        #expect(fromMain.main == main.path && fromMain.worktree == main.path)
        let fromLinked = try #require(await manager.checkoutRoots(at: linked.path))
        #expect(fromLinked.main == main.path && fromLinked.worktree == linked.path)
        #expect(await manager.checkoutRoots(at: plain.path) == nil)
    }

    @Test func zshDefinesNamedDirectoriesAfterTheUserStartupFiles() async throws {
        let home = URL(fileURLWithPath: "/tmp/chauffeur-named-dirs-\(UUID())").resolvingSymlinksInPath()
        let checkout = home.appendingPathComponent("my repo")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("hash -d main=/wrong\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let environment = try ShellStartup.environment(executable: "/bin/zsh", environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], exports: [:], namedDirectories: ["main": checkout.path], directory: home.appendingPathComponent("wrapper"))
        let result = try await ProcessRunner.run("/bin/zsh", ["-i", "-c", "print -r -- ~main"], environment: environment)
        #expect(result.status == 0)
        #expect(result.output.hasSuffix(checkout.path + "\n"))
        let unchanged = try ShellStartup.environment(executable: "/bin/zsh", environment: ["HOME": home.path], exports: [:], directory: home.appendingPathComponent("unused"))
        #expect(unchanged["ZDOTDIR"] == nil)
    }

    @Test func shellPreambleListsTeamExportsThenCheckoutVariablesAndNamedDirectories() {
        let checkout = ["MAIN_REPO": "/repo", "WORKTREE": "/repo-task"]
        #expect(ShellStartup.preamble(exports: ["CODEX_HOME": "/codex"], checkout: checkout, namedDirectories: ["main": "/repo", "worktree": "/repo-task"]) == """
        export CODEX_HOME='/codex'
        export MAIN_REPO='/repo'
        export WORKTREE='/repo-task'

        # $MAIN_REPO is the repository's main checkout.
        # $WORKTREE is the checkout this terminal opened in.
        # In zsh, jump to them with cd ~main or cd ~worktree.
        """)
        #expect(ShellStartup.preamble(exports: [:], checkout: ["WORKTREE": "/repo-task"], namedDirectories: [:]) == """
        export WORKTREE='/repo-task'

        # $WORKTREE is the checkout this terminal opened in.
        """)
        #expect(ShellStartup.preamble(exports: ["CODEX_HOME": "/codex"], checkout: [:], namedDirectories: [:]) == "export CODEX_HOME='/codex'")
        #expect(ShellStartup.preamble(exports: [:], checkout: [:], namedDirectories: [:]) == nil)
    }
}
