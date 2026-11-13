import Foundation
import ChauffeurCore

/// Decides what suspending a project would do. Pure, so the runtime supplies the
/// sessions and each agent's transcripts and tests can supply fakes.
enum ProjectSuspensionPlanner {
    /// A transcript started this long before its session may still be the session's own.
    static let clockSlack: TimeInterval = 60

    /// - Parameters:
    ///   - sessions: every session the runtime knows, so conversations other sessions own are not adopted.
    ///   - launching: sessions still starting.
    ///   - checkoutExists: whether the session's checkout folder is still there.
    ///   - hasRecordedTranscript: whether the session's recorded conversation has a resumable transcript.
    ///   - conversations: the newest transcripts of an agent's kind and configuration in its checkout,
    ///     newest first, searched when the recorded conversation has none.
    static func plan(projectID: UUID, sessions: [Session], launching: Set<UUID>,
                     checkoutExists: (Session) -> Bool = { _ in true },
                     hasRecordedTranscript: (Session) -> Bool,
                     conversations: (Session) -> [RecentConversation]) -> ProjectSuspensionPlan {
        var plan = ProjectSuspensionPlan(projectID: projectID)
        let live = sessions
            .filter { $0.projectID == projectID && $0.suspendedAt == nil && ($0.state.isLive || launching.contains($0.id)) }
            .sorted { $0.createdAt < $1.createdAt }
        var unresolved: [(session: Session, candidates: [RecentConversation])] = []

        for session in live {
            let kind = session.launch.preset.kind
            if launching.contains(session.id) {
                plan.blockers.append(.init(sessionID: session.id, title: session.title, reason: "Still starting. Wait for it to finish launching."))
            } else if kind == .shell {
                plan.shells.append(.init(sessionID: session.id, title: session.title))
            } else if !checkoutExists(session) {
                // Nothing can resume in a deleted checkout; end the agent rather than block or suspend.
                plan.missingCheckouts.append(.init(sessionID: session.id, title: session.title, path: session.launch.workingDirectory))
            } else if !kind.supportsSuspension {
                plan.blockers.append(.init(sessionID: session.id, title: session.title,
                                           reason: "\(kind.displayName) sessions can't be suspended yet. Close it first."))
            } else if kind == .codex, let reason = codexBlocker(session, hasRecordedTranscript: hasRecordedTranscript) {
                // Codex names its conversation only through hooks, so there is nothing to look up instead.
                plan.blockers.append(.init(sessionID: session.id, title: session.title, reason: reason))
            } else {
                if let recorded = session.nativeConversationID, hasRecordedTranscript(session) {
                    plan.agents.append(agent(session, conversationID: recorded, recorded: true))
                } else {
                    unresolved.append((session, conversations(session)))
                }
            }
        }

        // A lookup adopts a transcript only when exactly one session could own it.
        let resolving = Set(unresolved.map(\.session.id))
        let claimed = Set(sessions.filter { !resolving.contains($0.id) }.compactMap(\.nativeConversationID))
            .union(plan.agents.map(\.conversationID))
        let groups = Dictionary(grouping: unresolved) { transcriptOwner($0.session) }
        for entry in unresolved {
            let session = entry.session
            let kind = session.launch.preset.kind
            if (groups[transcriptOwner(session)]?.count ?? 0) > 1 {
                plan.blockers.append(.init(sessionID: session.id, title: session.title, reason:
                    "Several \(kind.displayName) sessions in this checkout have no recorded conversation, so Chauffeur can't tell which transcript is whose. Close all but one."))
                continue
            }
            let earliest = session.createdAt.addingTimeInterval(-clockSlack)
            if let found = entry.candidates.first(where: { !claimed.contains($0.id) && $0.updatedAt >= earliest }) {
                plan.agents.append(agent(session, conversationID: found.id, recorded: false))
            } else {
                plan.blockers.append(.init(sessionID: session.id, title: session.title,
                                           reason: "No saved conversation was found, so there is nothing to resume. It may not have received a message yet. Close it first."))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id, $0) })
        plan.agents.sort { order[$0.sessionID, default: 0] < order[$1.sessionID, default: 0] }
        return plan
    }

    /// Why a Codex session can't be suspended, or nil when its hooks reported a conversation
    /// with a transcript. Without trusted hooks Codex never says which conversation it is in,
    /// and a transcript lookup would only be a guess.
    private static func codexBlocker(_ session: Session, hasRecordedTranscript: (Session) -> Bool) -> String? {
        switch session.inboxReminders {
        case nil:
            return "Codex reports its conversation only with coordination on. Close it, or relaunch it with coordination, first."
        case false?:
            return "Codex didn't trust Chauffeur's hooks in this session, so its conversation isn't known. Close it first."
        case true?:
            guard session.nativeConversationID != nil else {
                return "Codex hasn't reported its conversation yet. Send it a message, or close it, first."
            }
            return hasRecordedTranscript(session) ? nil
                : "Codex's conversation has no saved transcript yet, so there is nothing to resume. Close it first."
        }
    }

    /// Sessions sharing a kind, configuration, and checkout write transcripts to the same place.
    private static func transcriptOwner(_ session: Session) -> String {
        [session.launch.preset.kind.rawValue, Paths.canonical(session.launch.configurationPath), Paths.canonical(session.launch.workingDirectory)].joined(separator: "|")
    }

    private static func agent(_ session: Session, conversationID: String, recorded: Bool) -> ProjectSuspensionPlan.Agent {
        let activity: ProjectSuspensionPlan.Activity
        if session.waiting != nil || session.state == .running || session.state == .starting { activity = .working }
        else if session.state == .activityUnknown { activity = .unknown }
        else { activity = .idle }
        return .init(sessionID: session.id, title: session.title, kind: session.launch.preset.kind,
                     conversationID: conversationID, conversationRecorded: recorded, activity: activity)
    }
}
