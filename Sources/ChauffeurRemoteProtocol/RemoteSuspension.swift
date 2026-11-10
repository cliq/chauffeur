import Foundation

/// Asks the Mac what suspending a project would do.
public struct SuspendPlanRequest: Codable, Equatable, Sendable {
    public var projectID: UUID

    public init(projectID: UUID) { self.projectID = projectID }
}

/// Suspends a project. `interruptBusy` is the user's consent to stop agents the plan showed as
/// working; without it the Mac refuses with `busy_sessions` while any may be working.
public struct SuspendProjectRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var interruptBusy: Bool

    public init(projectID: UUID, interruptBusy: Bool) {
        self.projectID = projectID; self.interruptBusy = interruptBusy
    }
}

/// Resumes the chosen suspended sessions. Every other suspended session in the project becomes
/// an ended session, so `shownSessionIDs` names every suspended session the user saw: the Mac
/// refuses with `suspension_changed` when the project's suspended sessions differ, rather than
/// end one the user never saw. Nil skips that check.
public struct RestoreProjectRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var sessionIDs: [UUID]
    public var shownSessionIDs: [UUID]?

    public init(projectID: UUID, sessionIDs: [UUID], shownSessionIDs: [UUID]? = nil) {
        self.projectID = projectID; self.sessionIDs = sessionIDs; self.shownSessionIDs = shownSessionIDs
    }
}

/// What suspending a project would do: which agents stop with a verified conversation to resume,
/// which terminals close, and what prevents it. Mirrors the Mac's `ProjectSuspensionPlan`.
public struct RemoteSuspendPlan: Codable, Equatable, Sendable {
    public enum Activity: String, Codable, Sendable {
        case idle
        /// Mid-turn, starting, or waiting on delegated workers.
        case working
        /// The agent reports no activity, so it may be working.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Activity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct Agent: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var kind: RemoteSessionKind
        /// False when the recorded conversation had no transcript and a search of the
        /// checkout's transcripts found this one instead.
        public var conversationRecorded: Bool
        public var activity: Activity
        public var id: UUID { sessionID }

        public init(sessionID: UUID, title: String, kind: RemoteSessionKind, conversationRecorded: Bool, activity: Activity) {
            self.sessionID = sessionID; self.title = title; self.kind = kind
            self.conversationRecorded = conversationRecorded; self.activity = activity
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

        public init(sessionID: UUID, title: String, reason: String) {
            self.sessionID = sessionID; self.title = title; self.reason = reason
        }
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

/// What restoring resumed; sessions that failed stay suspended with their error.
public struct RemoteRestoreResult: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable, Identifiable {
        public var sessionID: UUID
        public var title: String
        public var message: String
        public var id: UUID { sessionID }

        public init(sessionID: UUID, title: String, message: String) {
            self.sessionID = sessionID; self.title = title; self.message = message
        }
    }

    public var restored: [UUID]
    public var failures: [Failure]

    public init(restored: [UUID] = [], failures: [Failure] = []) { self.restored = restored; self.failures = failures }
}
