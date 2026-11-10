import Foundation

/// What suspending a project would do: which agents stop with a verified
/// conversation to resume, which shells close, and what prevents it.
public struct ProjectSuspensionPlan: Codable, Equatable, Sendable {
    public enum Activity: String, Codable, Sendable {
        case idle
        /// Mid-turn, starting, or waiting on delegated workers.
        case working
        /// Basic terminal mode reports no activity, so the agent may be working.
        case unknown
    }

    public struct Agent: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var kind: CLIKind
        /// The conversation restoring resumes, verified against the provider's transcript.
        public var conversationID: String
        /// False when the recorded conversation had no transcript and a lookup in the
        /// checkout found this one instead.
        public var conversationRecorded: Bool
        public var activity: Activity
        public var id: UUID { sessionID }

        public init(sessionID: UUID, title: String, kind: CLIKind, conversationID: String, conversationRecorded: Bool, activity: Activity) {
            self.sessionID = sessionID; self.title = title; self.kind = kind
            self.conversationID = conversationID; self.conversationRecorded = conversationRecorded; self.activity = activity
        }
    }

    public struct Shell: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var id: UUID { sessionID }
        public init(sessionID: UUID, title: String) { self.sessionID = sessionID; self.title = title }
    }

    public struct Blocker: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var reason: String
        public var id: UUID { sessionID }
        public init(sessionID: UUID, title: String, reason: String) { self.sessionID = sessionID; self.title = title; self.reason = reason }
    }

    public var projectID: UUID
    public var agents: [Agent]
    public var shells: [Shell]
    public var blockers: [Blocker]

    public init(projectID: UUID, agents: [Agent] = [], shells: [Shell] = [], blockers: [Blocker] = []) {
        self.projectID = projectID; self.agents = agents; self.shells = shells; self.blockers = blockers
    }

    public var canSuspend: Bool { blockers.isEmpty && !agents.isEmpty }
    /// Agents suspending would interrupt, or might.
    public var busyAgents: [Agent] { agents.filter { $0.activity != .idle } }
}

/// What restoring a suspended project resumed, and what stays suspended.
public struct ProjectRestoreResult: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var message: String
        public var id: UUID { sessionID }
        public init(sessionID: UUID, title: String, message: String) { self.sessionID = sessionID; self.title = title; self.message = message }
    }

    public var restored: [UUID]
    public var failures: [Failure]

    public init(restored: [UUID] = [], failures: [Failure] = []) { self.restored = restored; self.failures = failures }
}

public extension CLIKind {
    /// Agents whose conversations a suspended project can resume. Codex qualifies only
    /// when its trusted hooks report the conversation (see `ProjectSuspensionPlanner`).
    var supportsSuspension: Bool { self == .claude || self == .codex }
}
