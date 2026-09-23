import Foundation
import ChauffeurCore

/// Read-only Git queries run on the repository host, never in the UI process.
public actor GitRefReader {
    public init() {}

    private func git(_ path: String, _ arguments: [String], allowFailure: Bool = false) async throws -> String? {
        try Task.checkCancellation()
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", path] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                          "LC_ALL": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"], timeout: 30)
        try Task.checkCancellation()
        guard !result.outputTruncated else { throw ChauffeurError("git_failed", "Git returned too much data. Narrow the repository's refs.", path: path) }
        guard result.status == 0 else {
            if allowFailure { return nil }
            throw ChauffeurError("git_failed", String(result.error.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines), path: path)
        }
        return result.output.trimmingCharacters(in: .newlines)
    }

    public func list(at path: String) async throws -> GitRefSnapshot {
        let common = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])!
        let fields = ["refname", "objectname", "*objectname", "committerdate:unix", "*committerdate:unix", "creatordate:unix", "upstream", "upstream:track,nobracket", "HEAD", "symref", "subject", "*subject"]
        let output = try await git(path, ["for-each-ref", "--format=" + fields.map { "%(\($0))" }.joined(separator: "%00"), "refs/heads/", "refs/remotes/", "refs/tags/"])!
        let worktrees = try await git(path, ["worktree", "list", "--porcelain", "-z"])!
        let checkedOut = Set(worktrees.split(separator: "\0").filter { $0.hasPrefix("branch ") }.map { String($0.dropFirst(7)) })
        func date(_ string: String) -> Date? { Double(string).map(Date.init(timeIntervalSince1970:)) }
        var refs: [GitRef] = []
        var remoteDefaults: [String] = []
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == fields.count else { continue }
            let name = columns[0]
            if !columns[9].isEmpty {
                if name.hasSuffix("/HEAD") { remoteDefaults.append(columns[9]) }
                continue
            }
            let kind: GitRef.Kind = name.hasPrefix("refs/heads/") ? .local : name.hasPrefix("refs/remotes/") ? .remote : .tag
            // Tags pointing to trees/blobs are not valid worktree start points.
            guard kind != .tag || !columns[3].isEmpty || !columns[4].isEmpty else { continue }
            let track = columns[7].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            func count(_ label: String) -> Int { track.first { $0.hasPrefix(label + " ") }.flatMap { Int($0.dropFirst(label.count + 1)) } ?? 0 }
            refs.append(GitRef(kind: kind, fullName: name, sha: columns[2].isEmpty ? columns[1] : columns[2],
                subject: columns[2].isEmpty ? columns[10] : columns[11], lastCommitDate: date(columns[4].isEmpty ? columns[3] : columns[4]),
                creatorDate: date(columns[5]), upstream: columns[6].isEmpty ? nil : columns[6], ahead: count("ahead"), behind: count("behind"),
                isCheckedOutInWorktree: checkedOut.contains(name), isHEAD: columns[8] == "*"))
        }
        let names = Set(refs.map(\.fullName))
        let remoteDefault = remoteDefaults.sorted { lhs, rhs in
            if lhs.hasPrefix("refs/remotes/origin/") != rhs.hasPrefix("refs/remotes/origin/") { return lhs.hasPrefix("refs/remotes/origin/") }
            return lhs < rhs
        }.first
        let localDefault = remoteDefault.map { "refs/heads/" + $0.dropFirst("refs/remotes/".count).split(separator: "/").dropFirst().joined(separator: "/") }
        let defaultBranch = [localDefault, remoteDefault, "refs/heads/main", "refs/heads/master"].compactMap { $0 }.first { names.contains($0) }
        if let defaultBranch {
            let merged = try await git(path, ["for-each-ref", "--merged=" + defaultBranch, "--format=%(refname)", "refs/heads/", "refs/remotes/"])!
            let mergedNames = Set(merged.split(separator: "\n").map(String.init))
            for index in refs.indices { refs[index].isMerged = mergedNames.contains(refs[index].fullName) }
        }
        var head: GitRef?
        if let info = try await git(path, ["log", "-1", "--format=%H%x00%s", "HEAD", "--"], allowFailure: true) {
            let values = info.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            if values.count == 2 { head = GitRef(kind: .head, fullName: "HEAD", sha: String(values[0]), subject: String(values[1])) }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: common).appendingPathComponent("FETCH_HEAD").path)
        return GitRefSnapshot(repositoryKey: Paths.canonical(common), refs: refs, head: head, defaultBranch: defaultBranch, fetchedAt: attributes?[.modificationDate] as? Date)
    }

    public func resolve(_ query: String, at path: String) async throws -> GitRef? {
        try Validation.require(GitRef.isCommitQuery(query), "Enter a commit SHA of 4–40 hexadecimal characters")
        // Validate the repository separately so corruption/path errors reach Retry, not the empty state.
        _ = try await git(path, ["rev-parse", "--git-dir"])
        guard let sha = try await git(path, ["rev-parse", "--verify", "--quiet", "--end-of-options", query + "^{commit}"], allowFailure: true) else { return nil }
        let subject = try await git(path, ["show", "-s", "--format=%s", sha, "--"])!
        return GitRef(kind: .commit, fullName: sha, sha: sha, subject: subject)
    }
}
