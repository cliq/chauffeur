import Foundation
import Darwin

/// A closed vocabulary: neither provider output nor arbitrary error text can
/// become a log field, even when supplied as an error's code.
public enum DiagnosticCode: String, Codable, Sendable {
    case operation_failed, startup_failed, log_unavailable, cli_exit, terminal_ownership_lost, diagnostics_export_failed
    case active_worktree, already_attached, already_live, already_received, already_running
    case attachment_closed, attachment_lost, child_limit, command_pipe, command_timeout
    case connection_closed, conversation_mismatch, delegation_depth, dirty_worktree, duplicate_id
    case edit_conflict, exec_failed, external_worktree, frame_too_large, git_failed, handoff_cleanup
    case help_failed, immutable_membership, inaccessible_directory, input_failed, integration_unavailable
    case interrupt_failed, invalid, invalid_argument, invalid_arguments, invalid_delivery_state
    case invalid_frame, invalid_handoff, invalid_input, invalid_record, invalid_settings, invalid_snapshot
    case launch_cancelled, launch_file, launch_handoff_timeout, launch_pending, stop_pending, ledger_bind, ledger_open, ledger_query
    case ledger_read, ledger_schema, ledger_write, login_environment_unavailable, managed_argument
    case message_expired, missing_directory, missing_executable, missing_folder, missing_group
    case missing_helper, missing_message, missing_preset, missing_project, missing_session, missing_set
    case missing_worktree, not_found, not_live, port_persistence, project_unavailable, protocol_error
    case protocol_mismatch, pty_failed, random_failure, resize_failed, resume_unavailable, retention_failed
    case retry_conflict, runtime_already_running, service_unavailable, sessions_still_running, shared_checkout
    case snapshot_budget, snapshot_failed, snapshot_path, snapshot_unavailable, snapshot_version
    case socket_failed, stop_failed, terminal_error, terminal_inventory, terminal_launch, unauthorized
    case unknown_event, unknown_method, unknown_terminal_command, unknown_tool, unmanaged_path
    case unreadable_directory, unresolved_preset_set, unresolved_reference, metadata_watcher, preset_preference, unsupported_directories, usage, version_failed
    case working_directory, worktree_busy, worktree_unavailable, worktree_registration, checkout_changed, checkout_unverified
    case skill_bundle, skill_busy, skill_conflict, skill_unavailable
    case notification_helper, notification_unavailable

    public static func redacting(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .operation_failed }
}

public enum DiagnosticRedaction {
    public static func path(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains(where: { "\"{}=<>".contains($0) }) else { return nil }
        return value.components(separatedBy: "/").map { component in
            let lower = component.lowercased()
            let credential = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "bearer", "eyj", "xoxb-", "xoxp-", "akia", "asia"].contains { lower.contains($0) }
            let opaque = component.count >= 40 && UUID(uuidString: component) == nil && component.range(of: "^[A-Za-z0-9_.+%-]+$", options: .regularExpression) != nil
            return credential || opaque || component.contains(":") || component.contains("@") || component.contains("%") || component.contains("?") ? "[redacted]" : component
        }.joined(separator: "/")
    }
    public static func version(_ value: String?) -> String? {
        guard var value, value.utf8.count <= 80 else { return nil }
        if value.hasPrefix("codex-cli ") { value.removeFirst("codex-cli ".count) }
        if value.hasSuffix(" (Claude Code)") { value.removeLast(" (Claude Code)".count) }
        guard value.range(of: "^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}(-dev)?$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

public struct DiagnosticIssue: Codable, Sendable {
    public let code: DiagnosticCode
    public let path: String?
    public init(_ error: ChauffeurError) { code = .redacting(error.code); path = DiagnosticRedaction.path(error.path) }
}

public enum RuntimeLogEvent: String, Codable, Sendable { case runtimeStarting, runtimeReady, startupFailed, sessionChanged, operationFailed, metadataInvalid, toolCalled }
public enum DiagnosticTool: String, Codable, Sendable {
    case chauffeur_discover, chauffeur_send_message, chauffeur_inbox, chauffeur_reply
    case chauffeur_delegate, chauffeur_delegation_status, chauffeur_report_result
    case chauffeur_follow_up, chauffeur_close_session, chauffeur_recover_workers
    case chauffeur_register_progress, chauffeur_unregister_progress
}
public struct RuntimeLogEntry: Codable, Sendable {
    public var schemaVersion = 1
    public var timestamp = Date()
    public let event: RuntimeLogEvent
    public let runtimeID: UUID
    public var sessionID: UUID?
    public var projectID: UUID?
    public var groupID: UUID?
    public var state: SessionState?
    public var processID: Int32?
    public var exitStatus: Int32?
    public var code: DiagnosticCode?
    public var tool: DiagnosticTool?
    public var count: Int?
    public init(_ event: RuntimeLogEvent, runtimeID: UUID) { self.event = event; self.runtimeID = runtimeID }
}
public enum DiagnosticLogStatus: String, Codable, Sendable { case available, unavailable, notFetched }
public struct DiagnosticLogs: Codable, Sendable {
    public var status: DiagnosticLogStatus
    public var discardedLines = 0
    public var entries: [RuntimeLogEntry] = []
    public init(status: DiagnosticLogStatus) { self.status = status }
}

public struct DiagnosticSession: Codable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let groupID: UUID
    public let presetID: UUID
    public let kind: CLIKind
    public let executablePath: String?
    public let executableVersion: String?
    public let configurationPath: String?
    public let workingDirectory: String?
    public let additionalPaths: [String]
    public let omittedAdditionalPaths: Int
    public let state: SessionState
    public let processID: Int32?
    public let runtimeID: UUID?
    public let hasNativeConversationID: Bool
    public let failureCode: DiagnosticCode?
    public let exitStatus: Int32?
    public init(_ session: Session) {
        id = session.id; projectID = session.projectID; groupID = session.groupID; presetID = session.launch.preset.id
        kind = session.launch.preset.kind
        executablePath = DiagnosticRedaction.path(session.launch.executablePath)
        executableVersion = DiagnosticRedaction.version(session.launch.executableVersion)
        configurationPath = DiagnosticRedaction.path(session.launch.configurationPath)
        workingDirectory = DiagnosticRedaction.path(session.launch.workingDirectory)
        additionalPaths = session.launch.additionalPaths.prefix(8).compactMap { DiagnosticRedaction.path($0) }
        omittedAdditionalPaths = session.launch.additionalPaths.count - additionalPaths.count
        state = session.state; processID = session.processID; runtimeID = session.runtimeID
        hasNativeConversationID = session.nativeConversationID != nil
        failureCode = session.failureCode.map { .redacting($0) } ?? (session.error == nil ? nil : .operation_failed)
        exitStatus = session.exitStatus
    }
}

public enum DiagnosticObservation: String, Codable, Sendable { case live, cached, unavailable }
public enum DiagnosticRuntimeState: String, Codable, Sendable { case running, unavailable, unknown }
public enum DiagnosticServiceStatus: String, Codable, Sendable { case customConnection, notRegistered, enabled, requiresApproval, notFound, unknown }
public struct DiagnosticApp: Codable, Sendable {
    public let version: String?
    public let service: DiagnosticServiceStatus
    public let serviceErrorCode: Int?
    public let serviceErrorDomain: ErrorDomain?
    public enum ErrorDomain: String, Codable, Sendable { case serviceManagement, cocoa, posix, other }
    public init(version: String?, service: String, error: NSError?) {
        self.version = DiagnosticRedaction.version(version)
        self.service = DiagnosticServiceStatus(rawValue: service) ?? .unknown
        serviceErrorCode = error?.code
        serviceErrorDomain = error.map {
            switch $0.domain {
            case "SMAppServiceErrorDomain": .serviceManagement
            case NSCocoaErrorDomain: .cocoa
            case NSPOSIXErrorDomain: .posix
            default: .other
            }
        }
    }
}

/// Explicit projection, never the full runtime snapshot. New record fields do
/// not enter this schema automatically. Counts and timestamps describe omitted
/// data without exporting its contents.
public struct DiagnosticsReport: Codable, Sendable {
    public var schemaVersion = 1
    public var generatedAt = Date()
    public let observation: DiagnosticObservation
    public let observedAt: Date?
    public let runtimeID: UUID?
    public let runtimeVersion: String?
    public let runtimeState: DiagnosticRuntimeState
    public let protocolVersion: Int?
    public let mcpReady: Bool
    public let operatingSystem: String
    public let sessionCount: Int
    public let liveSessionCount: Int
    public let omittedSessions: Int
    public let sessions: [DiagnosticSession]
    public let issues: [DiagnosticIssue]
    public let omittedIssues: Int
    public var logs: DiagnosticLogs
    public var app: DiagnosticApp?
    public init(sessions: [Session], health: JSONValue, errors: [ChauffeurError], observation: DiagnosticObservation, observedAt: Date?, logs: DiagnosticLogs = .init(status: .notFetched)) {
        self.observation = observation; self.observedAt = observedAt
        runtimeID = health["runtimeID"].string.flatMap(UUID.init(uuidString:))
        runtimeVersion = DiagnosticRedaction.version(health["version"].string)
        runtimeState = observation == .unavailable ? .unavailable : (health["status"].string == "running" ? .running : .unknown)
        protocolVersion = health["protocolVersion"].int
        mcpReady = health["mcpEndpoint"].string != nil
        let os = ProcessInfo.processInfo.operatingSystemVersion
        operatingSystem = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        sessionCount = sessions.count; liveSessionCount = sessions.filter { $0.state.isLive }.count
        self.sessions = sessions.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }.prefix(100).map(DiagnosticSession.init)
        omittedSessions = sessions.count - self.sessions.count
        issues = errors.suffix(100).map(DiagnosticIssue.init); omittedIssues = errors.count - issues.count
        self.logs = logs
    }
    public func write(to destination: URL) throws {
        let data = try JSONCoding.encode(self)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".chauffeur-diagnostics-\(UUID()).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChauffeurError("diagnostics_export_failed", "Cannot create the diagnostics file in this folder") }
        defer { unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard rename(temporary.path, destination.path) == 0 else { throw ChauffeurError("diagnostics_export_failed", "Cannot save the diagnostics file") }
        } catch {
            try? handle.close()
            throw ChauffeurError("diagnostics_export_failed", "Cannot save the diagnostics file")
        }
    }
}
