import Foundation
import CryptoKit
import Security
import CSQLite
import ChauffeurCore

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ChauffeurError("ledger_open", "Cannot open coordination ledger", path: path)
        }
        handle = database
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }
}

/// All authorization and mailbox/delegation transactions run on this actor.
/// There is no caller-supplied group selector in any authorized operation.
public actor Ledger {
    private let connection: SQLiteConnection
    private var transactionCounter = 0
    private var inboxWaiters: [UUID: (UUID, AsyncStream<Bool>.Continuation)] = [:]
    var pendingInboxWaitCount: Int { inboxWaiters.count }

    private func wakeInbox(_ sessionID: UUID, healthCheck: Bool = false) {
        for (recipient, continuation) in inboxWaiters.values where recipient == sessionID {
            continuation.yield(healthCheck)
        }
    }

    /// Register before reading on this actor so arrival cannot race subscription.
    /// The durable mailbox remains authoritative; notifications are only wake hints.
    public func waitForInbox(token: String, acknowledge: [UUID] = [], waitSeconds: Int) async throws -> [Message] {
        try Validation.require((0...300).contains(waitSeconds), "Inbox wait must be between 0 and 300 seconds")
        try Task.checkCancellation()
        let caller = try authenticate(token)
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let id = UUID()
        let progressWatchers = try allDelegations()
            .filter { $0.controllingParentID == caller.sessionID && $0.scope == caller.scope }
            .compactMap { item -> ProgressWatcher? in
                guard let child = try? peer(item.childID, caller: caller), child.state.isLive,
                      let path = child.progress?.jsonPath else { return nil }
                return ProgressWatcher(path: path) { continuation.yield(true) }
            }
        inboxWaiters[id] = (caller.sessionID, continuation)
        let timer = Task {
            do { try await Task.sleep(for: .seconds(waitSeconds)); continuation.finish() }
            catch { /* The waiter completed or was cancelled. */ }
        }
        defer {
            withExtendedLifetime(progressWatchers) {}
            timer.cancel()
            continuation.finish()
            inboxWaiters.removeValue(forKey: id)
        }
        let initial = try inbox(caller: caller, acknowledge: acknowledge)
        if !initial.isEmpty || waitSeconds == 0 { return initial }
        for await healthCheck in stream {
            try Task.checkCancellation()
            let incoming = try inbox(caller: authenticate(token))
            if !incoming.isEmpty || healthCheck { return incoming }
        }
        try Task.checkCancellation()
        return try inbox(caller: authenticate(token))
    }
    public init(path: String) throws {
        connection = try SQLiteConnection(path: path)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, group_id TEXT NOT NULL,
          parent_id TEXT, live INTEGER NOT NULL, record TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS deleted_sessions (id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS grants (
          hash TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), revoked INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, group_id TEXT NOT NULL,
          sender_id TEXT NOT NULL REFERENCES sessions(id), recipient_id TEXT NOT NULL REFERENCES sessions(id),
          retry_key TEXT NOT NULL, request_hash TEXT NOT NULL, state TEXT NOT NULL, record TEXT NOT NULL,
          UNIQUE(sender_id, retry_key)
        );
        CREATE INDEX IF NOT EXISTS inbox ON messages(recipient_id, state);
        CREATE TABLE IF NOT EXISTS message_tombstones (
          sender_id TEXT NOT NULL, retry_key TEXT NOT NULL, request_hash TEXT NOT NULL,
          message_id TEXT NOT NULL, PRIMARY KEY(sender_id,retry_key)
        );
        CREATE TABLE IF NOT EXISTS delegations (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, group_id TEXT NOT NULL,
          parent_id TEXT NOT NULL REFERENCES sessions(id), child_id TEXT NOT NULL UNIQUE,
          retry_key TEXT NOT NULL, request_hash TEXT NOT NULL, state TEXT NOT NULL, record TEXT NOT NULL,
          UNIQUE(parent_id, retry_key)
        );
        CREATE TABLE IF NOT EXISTS control_operations (
          caller_id TEXT NOT NULL, retry_key TEXT NOT NULL, request_hash TEXT NOT NULL,
          record TEXT NOT NULL, PRIMARY KEY(caller_id,retry_key)
        );
        CREATE TABLE IF NOT EXISTS delegation_tombstones (
          parent_id TEXT NOT NULL, retry_key TEXT NOT NULL, request_hash TEXT NOT NULL,
          delegation_id TEXT NOT NULL, PRIMARY KEY(parent_id,retry_key)
        );
        CREATE TABLE IF NOT EXISTS worker_recoveries (
          previous_id TEXT PRIMARY KEY, controller_id TEXT NOT NULL, retry_key TEXT NOT NULL, adopted_ids TEXT
        );
        CREATE TABLE IF NOT EXISTS notification_preferences (id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL);
        INSERT OR IGNORE INTO notification_preferences(id,enabled) VALUES(1,0);
        CREATE TABLE IF NOT EXISTS attention_notices (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id), notice_id TEXT NOT NULL,
          delivered INTEGER NOT NULL DEFAULT 0, record TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS inbox_hints (
          message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
          recipient_id TEXT NOT NULL, event TEXT NOT NULL, native_turn_id TEXT, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS inbox_hint_receipts (
          session_id TEXT NOT NULL, event TEXT NOT NULL, native_turn_id TEXT NOT NULL, tool_use_id TEXT NOT NULL,
          record TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(session_id,event,native_turn_id,tool_use_id)
        );
        CREATE TABLE IF NOT EXISTS inbox_hint_stops (session_id TEXT PRIMARY KEY, native_turn_id TEXT NOT NULL);
        """
        guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else { throw ChauffeurError("ledger_schema", "Cannot initialize coordination ledger") }
        var column: OpaquePointer?
        if sqlite3_prepare_v2(connection.handle, "SELECT adopted_ids FROM worker_recoveries LIMIT 0", -1, &column, nil) != SQLITE_OK {
            guard sqlite3_exec(connection.handle, "ALTER TABLE worker_recoveries ADD COLUMN adopted_ids TEXT", nil, nil, nil) == SQLITE_OK else { throw ChauffeurError("ledger_schema", "Cannot migrate recovery receipts") }
        }
        sqlite3_finalize(column)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private var database: OpaquePointer { connection.handle }
    private func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ChauffeurError("ledger_write", "Coordination transaction could not be saved") }
    }
    private func prepare(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ChauffeurError("ledger_query", "Cannot prepare coordination query") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let code = value.map { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) } ?? sqlite3_bind_null(statement, Int32(index + 1))
            if code != SQLITE_OK { sqlite3_finalize(statement); throw ChauffeurError("ledger_bind", "Cannot bind coordination query") }
        }
        return statement
    }
    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append((0..<sqlite3_column_count(statement)).map { column in sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" })
            case SQLITE_DONE: return result
            default: throw ChauffeurError("ledger_read", "Cannot read coordination ledger")
            }
        }
    }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        let nested = sqlite3_get_autocommit(database) == 0
        transactionCounter += 1
        let savepoint = "nested_\(transactionCounter)"
        try execute(nested ? "SAVEPOINT \(savepoint)" : "BEGIN IMMEDIATE")
        do { let result = try operation(); try execute(nested ? "RELEASE SAVEPOINT \(savepoint)" : "COMMIT"); return result }
        catch {
            try? execute(nested ? "ROLLBACK TO SAVEPOINT \(savepoint)" : "ROLLBACK")
            if nested { try? execute("RELEASE SAVEPOINT \(savepoint)") }
            throw error
        }
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONCoding.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: Data(text.utf8)) }
    private func scopeValues(_ caller: Caller) -> [String?] { [caller.scope.projectID.uuidString, caller.scope.groupID.uuidString] }
    private func denied() -> ChauffeurError { ChauffeurError("not_found", "Record not found in this session's group") }
    public func register(_ session: Session, notification: AttentionReason? = nil) throws {
        let previous = try rows("SELECT record FROM sessions WHERE id=?", [session.id.uuidString]).first.map { try decode(Session.self, $0[0]) }
        try transaction {
            guard try !isForgotten(sessionID: session.id) else { throw ChauffeurError("missing_session", "This session was explicitly deleted") }
            if let existing = try rows("SELECT project_id,group_id,parent_id FROM sessions WHERE id=?", [session.id.uuidString]).first {
                guard existing[0] == session.projectID.uuidString, existing[1] == session.groupID.uuidString, existing[2] == (session.parentID?.uuidString ?? "") else {
                    throw ChauffeurError("immutable_membership", "Session membership and parent cannot change")
                }
            }
            try execute("INSERT INTO sessions(id,project_id,group_id,parent_id,live,record) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET live=excluded.live,record=excluded.record", [session.id.uuidString, session.projectID.uuidString, session.groupID.uuidString, session.parentID?.uuidString, session.state.isLive ? "1" : "0", try encode(session)])
            if let notification { try enqueueNotification(session: session, reason: notification) }
        }
        if !session.state.isLive { wakeInbox(session.id, healthCheck: true) }
        let workerChanged = previous?.progress != session.progress ||
            (previous?.state != session.state && [.needsAttention, .turnFinished, .exited, .failed, .interrupted].contains(session.state))
        if workerChanged,
           let row = try rows("SELECT record FROM delegations WHERE child_id=?", [session.id.uuidString]).first {
            let delegation = try decode(Delegation.self, row[0])
            wakeInbox(delegation.controllingParentID, healthCheck: true)
        }
    }
    public func notificationsEnabled() throws -> Bool {
        try rows("SELECT enabled FROM notification_preferences WHERE id=1").first?[0] == "1"
    }
    public func setNotificationsEnabled(_ enabled: Bool) throws {
        try transaction {
            try execute("UPDATE notification_preferences SET enabled=? WHERE id=1", [enabled ? "1" : "0"])
            if !enabled { try execute("DELETE FROM attention_notices") }
        }
    }
    private func enqueueNotification(session: Session, reason: AttentionReason) throws {
        guard try notificationsEnabled() else { return }
        let notice = AttentionNotice(route: SessionRoute(projectID: session.projectID, sessionID: session.id), reason: reason)
        try execute("INSERT INTO attention_notices(session_id,notice_id,record) VALUES(?,?,?) ON CONFLICT(session_id) DO UPDATE SET notice_id=excluded.notice_id,record=excluded.record,delivered=0", [session.id.uuidString, notice.id.uuidString, try encode(notice)])
    }
    public func pendingNotifications() throws -> [AttentionNotice] {
        try rows("SELECT record FROM attention_notices WHERE delivered=0 ORDER BY rowid LIMIT 100").map { try decode(AttentionNotice.self, $0[0]) }
    }
    /// A sample alert must not change a session or replace a pending real event.
    public func testNotification(sessionID: UUID) throws -> AttentionNotice {
        try transaction {
            guard try notificationsEnabled() else { throw ChauffeurError("notifications_disabled", "Enable session notifications first") }
            guard let row = try rows("SELECT record FROM sessions WHERE id=?", [sessionID.uuidString]).first else { throw ChauffeurError("missing_session", "Select an existing session") }
            let session = try decode(Session.self, row[0])
            if let pending = try rows("SELECT record FROM attention_notices WHERE session_id=? AND delivered=0", [sessionID.uuidString]).first {
                let notice = try decode(AttentionNotice.self, pending[0])
                guard notice.reason == .test else { throw ChauffeurError("notification_pending", "This session already has a notification waiting for delivery. Try again after it is delivered") }
                return notice
            }
            let notice = AttentionNotice(route: SessionRoute(projectID: session.projectID, sessionID: sessionID), reason: .test)
            try execute("INSERT INTO attention_notices(session_id,notice_id,record) VALUES(?,?,?) ON CONFLICT(session_id) DO UPDATE SET notice_id=excluded.notice_id,record=excluded.record,delivered=0", [sessionID.uuidString, notice.id.uuidString, try encode(notice)])
            return notice
        }
    }
    public func acknowledgeNotification(_ id: UUID) throws {
        // An acknowledgement for an older notice cannot swallow a newer event.
        try execute("UPDATE attention_notices SET delivered=1 WHERE notice_id=?", [id.uuidString])
    }
    public func issueGrant(sessionID: UUID) throws -> String {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw ChauffeurError("random_failure", "Cannot generate session credential") }
        let token = Data(random).base64EncodedString()
        try transaction {
            try execute("UPDATE grants SET revoked=1 WHERE session_id=?", [sessionID.uuidString])
            try execute("INSERT INTO grants(hash,session_id) VALUES(?,?)", [JSONCoding.digest(Data(token.utf8)), sessionID.uuidString])
        }
        return token
    }
    /// Deletes a finished session and everything the ledger holds for it,
    /// including messages and delegations it took part in.
    public func forget(sessionID: UUID) throws {
        defer { wakeInbox(sessionID, healthCheck: true) }
        let id = sessionID.uuidString
        try transaction {
            for item in try allDelegations() where item.controllingParentID == sessionID {
                let live = try rows("SELECT live FROM sessions WHERE id=?", [item.childID.uuidString]).first?[0] == "1"
                guard !live, ![.reserved, .launching].contains(item.state) else { throw ChauffeurError("active_session", "Close or recover this coordinator's workers before deleting its history") }
            }
            try execute("DELETE FROM attention_notices WHERE session_id=?", [id])
            try execute("DELETE FROM inbox_hint_receipts WHERE session_id=?", [id])
            try execute("DELETE FROM inbox_hint_stops WHERE session_id=?", [id])
            try execute("DELETE FROM grants WHERE session_id=?", [id])
            try execute("DELETE FROM message_tombstones WHERE sender_id=?", [id])
            try execute("DELETE FROM messages WHERE sender_id=? OR recipient_id=?", [id, id])
            // An original parent remains a hidden FK anchor for adopted workers.
            // Deleting its UI/history record must not destroy their control records.
            for item in try allDelegations() where item.childID == sessionID || (item.parentID == sessionID && item.controllerID == nil) {
                try execute("INSERT OR IGNORE INTO delegation_tombstones(parent_id,retry_key,request_hash,delegation_id) SELECT parent_id,retry_key,request_hash,id FROM delegations WHERE id=?", [item.id.uuidString])
                try execute("DELETE FROM delegations WHERE id=?", [item.id.uuidString])
            }
            try execute("INSERT OR IGNORE INTO deleted_sessions(id) VALUES(?)", [id])
            if try rows("SELECT id FROM delegations WHERE parent_id=?", [id]).isEmpty {
                try execute("DELETE FROM sessions WHERE id=?", [id])
            }
            try execute("DELETE FROM sessions WHERE id IN (SELECT id FROM deleted_sessions) AND id NOT IN (SELECT parent_id FROM delegations)")
        }
    }
    public func isForgotten(sessionID: UUID) throws -> Bool { try !rows("SELECT id FROM deleted_sessions WHERE id=?", [sessionID.uuidString]).isEmpty }
    public func revoke(sessionID: UUID) throws {
        try execute("UPDATE grants SET revoked=1 WHERE session_id=?", [sessionID.uuidString])
        wakeInbox(sessionID, healthCheck: true)
    }
    public func authenticate(_ token: String) throws -> Caller {
        guard !token.isEmpty, token.utf8.count <= 512,
              let row = try rows("SELECT s.id,s.project_id,s.group_id FROM grants g JOIN sessions s ON s.id=g.session_id WHERE g.hash=? AND g.revoked=0 AND s.live=1", [JSONCoding.digest(Data(token.utf8))]).first,
              let id = UUID(uuidString: row[0]), let projectID = UUID(uuidString: row[1]), let groupID = UUID(uuidString: row[2]) else {
            throw ChauffeurError("unauthorized", "A valid live session credential is required")
        }
        return Caller(sessionID: id, scope: GroupScope(projectID: projectID, groupID: groupID))
    }
    /// Revalidate after suspension (e.g. bounded inbox wait), including revocation.
    public func peers(_ caller: Caller) throws -> [Session] {
        try rows("SELECT record FROM sessions WHERE project_id=? AND group_id=? AND id NOT IN (SELECT id FROM deleted_sessions)", scopeValues(caller)).map { try decode(Session.self, $0[0]) }
    }
    private func peer(_ id: UUID, caller: Caller) throws -> Session {
        guard let row = try rows("SELECT record FROM sessions WHERE id=? AND project_id=? AND group_id=? AND id NOT IN (SELECT id FROM deleted_sessions)", [id.uuidString] + scopeValues(caller)).first else { throw denied() }
        return try decode(Session.self, row[0])
    }
    public func send(caller: Caller, recipientID: UUID, body: String, references: [String] = [], retryKey: String, replyToID: UUID? = nil, delegationID: UUID? = nil, turnID: UUID? = nil) throws -> Message {
        try Validation.require(!body.isEmpty && body.utf8.count <= 64 * 1024, "Message must contain 1–65,536 UTF-8 bytes")
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        try Validation.require(references.count <= 100 && references.allSatisfy { $0.utf8.count <= 4096 }, "Too many or oversized context references")
        var hashParts = [recipientID.uuidString, body, try encode(references), replyToID?.uuidString ?? "", delegationID?.uuidString ?? ""]
        if let turnID { hashParts.append(turnID.uuidString) }
        let requestHash = JSONCoding.digest(try JSONCoding.encode(hashParts))
        return try transaction {
            _ = try peer(recipientID, caller: caller)
            if let replyToID {
                let original = try message(replyToID, caller: caller)
                guard original.recipientID == caller.sessionID, original.senderID == recipientID else { throw denied() }
            }
            if let delegationID { _ = try delegation(delegationID, caller: caller) }
            if let tombstone = try rows("SELECT request_hash,message_id FROM message_tombstones WHERE sender_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                guard tombstone[0] == requestHash else { throw ChauffeurError("retry_conflict", "Retry key was already used for different message content") }
                throw ChauffeurError("message_expired", "Message \(tombstone[1]) was already accepted and its completed history was pruned. It will not be sent again")
            }
            if let row = try rows("SELECT request_hash,record FROM messages WHERE sender_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                guard row[0] == requestHash else { throw ChauffeurError("retry_conflict", "Retry key was already used for different message content") }
                return try decode(Message.self, row[1])
            }
            var message = Message(scope: caller.scope, senderID: caller.sessionID, recipientID: recipientID, body: body, references: references, replyToID: replyToID, delegationID: delegationID)
            message.turnID = turnID
            try execute("INSERT INTO messages(id,project_id,group_id,sender_id,recipient_id,retry_key,request_hash,state,record) VALUES(?,?,?,?,?,?,?,?,?)", [message.id.uuidString] + scopeValues(caller) + [caller.sessionID.uuidString, recipientID.uuidString, retryKey, requestHash, message.state.rawValue, try encode(message)])
            try enqueueNotification(session: peer(recipientID, caller: caller), reason: delegationID == nil ? .message : .result)
            wakeInbox(recipientID)
            return message
        }
    }
    public func message(_ id: UUID, caller: Caller) throws -> Message {
        guard let row = try rows("SELECT record FROM messages WHERE id=? AND project_id=? AND group_id=?", [id.uuidString] + scopeValues(caller)).first else { throw denied() }
        return try decode(Message.self, row[0])
    }
    public func inbox(caller: Caller, acknowledge: [UUID] = []) throws -> [Message] {
        try Validation.require(acknowledge.count <= 100, "Acknowledge at most 100 messages per call")
        return try transaction {
            for id in acknowledge {
                var item = try message(id, caller: caller)
                guard item.recipientID == caller.sessionID else { throw denied() }
                guard item.state == .received || item.state == .acknowledged else { throw ChauffeurError("invalid_delivery_state", "Read a message before acknowledging it") }
                item.state = .acknowledged; item.acknowledgedAt = item.acknowledgedAt ?? Date()
                try saveMessage(item)
            }
            let incoming = try rows("SELECT record FROM messages WHERE recipient_id=? AND project_id=? AND group_id=? AND state IN ('queued','received') ORDER BY rowid LIMIT 100", [caller.sessionID.uuidString] + scopeValues(caller))
            return try incoming.map { row in
                var item = try decode(Message.self, row[0]); item.state = .received; item.receivedAt = item.receivedAt ?? Date()
                try saveMessage(item); return item
            }
        }
    }
    /// Claims queued mail that no hook has mentioned yet, for a metadata-only
    /// reminder. Message state, `receivedAt` and bodies are untouched: only
    /// `chauffeur_inbox` delivers. IDs are tracked, never counts, so a new arrival
    /// is claimed even when an acknowledgement keeps the total the same.
    public func claimInboxHint(caller: Caller, event: String, nativeTurnID: String? = nil, toolUseID: String? = nil) throws -> InboxHintSummary {
        try Validation.require(InboxHintFormatter.hookEvents.contains(event), "Unsupported hook event")
        try Validation.require([nativeTurnID, toolUseID].allSatisfy { ($0?.count ?? 0) <= 200 }, "Hook identifiers are too long")
        let session = caller.sessionID.uuidString
        // A provider that retries a hook call gets the answer it was first given.
        let key: [String?]? = nativeTurnID == nil && toolUseID == nil ? nil : [session, event, nativeTurnID ?? "", toolUseID ?? ""]
        return try transaction {
            if let key, let row = try rows("SELECT record FROM inbox_hint_receipts WHERE session_id=? AND event=? AND native_turn_id=? AND tool_use_id=?", key).first {
                return try decode(InboxHintSummary.self, row[0])
            }
            if event == "UserPromptSubmit" { try execute("DELETE FROM inbox_hint_stops WHERE session_id=?", [session]) }
            // Stop continues a turn at most once. Claude reports no turn ID, so
            // its flag lasts until the next prompt; mail then waits for that prompt.
            if event == "Stop", let blocked = try rows("SELECT native_turn_id FROM inbox_hint_stops WHERE session_id=?", [session]).first,
               nativeTurnID == nil || blocked[0] == nativeTurnID {
                return InboxHintSummary()
            }
            let claimed = try rows("SELECT m.id,m.record FROM messages m WHERE m.recipient_id=? AND m.project_id=? AND m.group_id=? AND m.state='queued' AND NOT EXISTS (SELECT 1 FROM inbox_hints h WHERE h.message_id=m.id) ORDER BY m.rowid", [session] + scopeValues(caller))
            let now = String(Date().timeIntervalSince1970)
            var summary = InboxHintSummary()
            for row in claimed {
                try execute("INSERT INTO inbox_hints(message_id,recipient_id,event,native_turn_id,created_at) VALUES(?,?,?,?,?)", [row[0], session, event, nativeTurnID, now])
                summary.count += 1
                if try decode(Message.self, row[1]).delegationID != nil { summary.results += 1 }
            }
            if event == "Stop", summary.count > 0 {
                summary.block = true
                try execute("INSERT INTO inbox_hint_stops(session_id,native_turn_id) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET native_turn_id=excluded.native_turn_id", [session, nativeTurnID ?? ""])
            }
            if let key { try execute("INSERT INTO inbox_hint_receipts(session_id,event,native_turn_id,tool_use_id,record,created_at) VALUES(?,?,?,?,?,?)", key + [try encode(summary), now]) }
            return summary
        }
    }
    func hintRowCount() throws -> Int { Int(try rows("SELECT COUNT(*) FROM inbox_hints").first?[0] ?? "") ?? 0 }
    private func saveMessage(_ message: Message) throws { try execute("UPDATE messages SET state=?,record=? WHERE id=?", [message.state.rawValue, try encode(message), message.id.uuidString]) }
    public func cancelMessage(_ id: UUID, caller: Caller) throws -> Message {
        try transaction {
            var item = try message(id, caller: caller)
            guard item.senderID == caller.sessionID else { throw denied() }
            guard item.state == .queued || item.state == .cancelled else { throw ChauffeurError("already_received", "Only queued messages can be cancelled") }
            item.state = .cancelled; try saveMessage(item); return item
        }
    }
    public func reserveDelegation(caller: Caller, task: String, presetID: UUID, folderID: UUID, shareCheckout: Bool, retryKey: String, limit: Int, worktreeID: UUID? = nil, model: String? = nil, reasoningEffort: String? = nil, predecessorID: UUID? = nil) throws -> (Delegation, Bool) {
        try Validation.require(!task.isEmpty && task.utf8.count <= 64 * 1024, "Task must contain 1–65,536 UTF-8 bytes")
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        var parts = [task, presetID.uuidString, folderID.uuidString, String(shareCheckout)]
        if worktreeID != nil || model != nil || reasoningEffort != nil || predecessorID != nil {
            parts += [worktreeID?.uuidString ?? "", model ?? "", reasoningEffort ?? "", predecessorID?.uuidString ?? ""]
        }
        let hash = JSONCoding.digest(try JSONCoding.encode(parts))
        return try transaction {
            let parent = try peer(caller.sessionID, caller: caller)
            guard parent.parentID == nil else { throw ChauffeurError("delegation_depth", "Delegated sessions cannot launch further children") }
            if let tombstone = try rows("SELECT request_hash FROM delegation_tombstones WHERE parent_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                guard tombstone[0] == hash else { throw ChauffeurError("retry_conflict", "Retry key was already used for another delegation") }
                throw ChauffeurError("delegation_deleted", "This delegation was explicitly deleted; it will not be launched again")
            }
            if let row = try rows("SELECT request_hash,record FROM delegations WHERE parent_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                guard row[0] == hash else { throw ChauffeurError("retry_conflict", "Retry key was already used for a different delegation") }
                return (try decode(Delegation.self, row[1]), false)
            }
            if let predecessorID {
                let prior = try ownedDelegation(predecessorID, caller: caller)
                guard shareCheckout, folderID == prior.folderID, worktreeID == prior.worktreeID else {
                    throw ChauffeurError("checkout_changed", "A replacement must explicitly share its predecessor's registered checkout")
                }
                guard prior.closureOutcome == "replaced",
                      (try? peer(prior.childID, caller: caller).state.isLive) != true else {
                    throw ChauffeurError("stop_pending", "Confirm the previous worker stopped as replaced before launching its successor")
                }
                guard !(try allDelegations()).contains(where: {
                    $0.predecessorID == predecessorID && (($0.state != .failed && $0.state != .interrupted) || (try? peer($0.childID, caller: caller).state.isLive) == true)
                }) else {
                    throw ChauffeurError("retry_conflict", "This attempt already has a replacement; inspect its delegation before retrying")
                }
            }
            let reserved = try allDelegations().filter { item in
                item.controllingParentID == caller.sessionID &&
                ((try? peer(item.childID, caller: caller).state.isLive) == true || [.reserved, .launching].contains(item.state))
            }.count
            guard reserved < limit else { throw ChauffeurError("child_limit", "Parent already has the configured maximum of \(limit) live children") }
            var item = Delegation(scope: caller.scope, parentID: caller.sessionID, task: task, presetID: presetID, folderID: folderID, shareCheckout: shareCheckout)
            item.worktreeID = worktreeID; item.model = model; item.reasoningEffort = reasoningEffort; item.predecessorID = predecessorID
            try execute("INSERT INTO delegations(id,project_id,group_id,parent_id,child_id,retry_key,request_hash,state,record) VALUES(?,?,?,?,?,?,?,?,?)", [item.id.uuidString] + scopeValues(caller) + [caller.sessionID.uuidString, item.childID.uuidString, retryKey, hash, item.state.rawValue, try encode(item)])
            return (item, true)
        }
    }
    public func delegation(_ id: UUID, caller: Caller) throws -> Delegation {
        guard let row = try rows("SELECT record FROM delegations WHERE id=? AND project_id=? AND group_id=?", [id.uuidString] + scopeValues(caller)).first else { throw denied() }
        return try decode(Delegation.self, row[0])
    }
    public func updateDelegation(_ value: Delegation) throws {
        guard let row = try rows("SELECT record FROM delegations WHERE id=?", [value.id.uuidString]).first else { throw denied() }
        let previous = try decode(Delegation.self, row[0])
        guard previous.scope == value.scope, previous.childID == value.childID, previous.parentID == value.parentID, previous.controllingParentID == value.controllingParentID else { throw ChauffeurError("immutable_membership", "Delegation membership cannot change") }
        try execute("UPDATE delegations SET state=?,record=? WHERE id=?", [value.state.rawValue, try encode(value), value.id.uuidString])
    }
    public func reportResult(caller: Caller, delegationID: UUID, result: String, retryKey: String, turnID: UUID? = nil) throws -> Message {
        try transaction {
            var item = try delegation(delegationID, caller: caller)
            guard item.childID == caller.sessionID else { throw denied() }
            guard item.closureOutcome == nil else { throw ChauffeurError("not_live", "This delegation is closed") }
            guard turnID == item.currentTurnID || (turnID == nil && item.turnID == nil) else {
                throw ChauffeurError("stale_turn", "Report the current turnID returned by discovery")
            }
            let message = try send(caller: caller, recipientID: item.controllingParentID, body: result, retryKey: "result:\(retryKey)", delegationID: item.id, turnID: turnID)
            item.result = result; item.state = .resultReported; try updateDelegation(item)
            // A report attributed to this turn proves its prompt was consumed,
            // even if the runtime crashed before acknowledging terminal input.
            for row in try rows("SELECT retry_key,record FROM control_operations") {
                var operation = try decode(CoordinationOperation.self, row[1])
                if operation.delegationID == item.id, operation.turnID == item.currentTurnID,
                   ["submitted", "deliveryUncertain"].contains(operation.state) {
                    operation.state = "reported"; operation.error = nil; operation.errorCode = nil
                    try saveOperation(operation, retryKey: row[0])
                }
            }
            return message
        }
    }
    public func ownedDelegation(_ id: UUID, caller: Caller) throws -> Delegation {
        let item = try delegation(id, caller: caller)
        guard item.controllingParentID == caller.sessionID else { throw denied() }
        return item
    }
    public func latestOperation(delegationID: UUID) throws -> CoordinationOperation? {
        try rows("SELECT record FROM control_operations ORDER BY rowid DESC")
            .lazy.map { try decode(CoordinationOperation.self, $0[0]) }.first { $0.delegationID == delegationID }
    }
    public func unresolvedFollowUp(delegationID: UUID) throws -> CoordinationOperation? {
        try rows("SELECT record FROM control_operations ORDER BY rowid DESC")
            .lazy.map { try decode(CoordinationOperation.self, $0[0]) }.first {
                $0.delegationID == delegationID && $0.kind == "follow_up" && ["reserved", "deliveryUncertain"].contains($0.state)
            }
    }
    public func reserveOperation(caller: Caller, delegationID: UUID, kind: String, arguments: JSONValue, retryKey: String) throws -> (CoordinationOperation, Bool) {
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        let hash = JSONCoding.digest(try JSONCoding.encode(arguments))
        return try transaction {
            let item = try ownedDelegation(delegationID, caller: caller)
            if let row = try rows("SELECT request_hash,record FROM control_operations WHERE caller_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                let operation = try decode(CoordinationOperation.self, row[1])
                guard row[0] == hash, operation.kind == kind, operation.delegationID == delegationID else {
                    throw ChauffeurError("retry_conflict", "Retry key was already used for a different session operation")
                }
                return (operation, false)
            }
            if kind == "follow_up" {
                guard try unresolvedFollowUp(delegationID: delegationID) == nil else {
                    throw ChauffeurError("follow_up_delivery_uncertain", "An earlier follow-up is unresolved. Inspect its receipt, wait for its report, or replace the worker; do not submit another prompt")
                }
                guard item.closureOutcome == nil else { throw ChauffeurError("not_live", "This delegation is closed") }
                guard arguments["expectedTurnID"].string.flatMap(UUID.init(uuidString:)) == item.currentTurnID else {
                    throw ChauffeurError("stale_turn", "Refresh delegation status before submitting a correction")
                }
            }
            let operation = CoordinationOperation(callerID: caller.sessionID, delegationID: delegationID, kind: kind)
            try execute("INSERT INTO control_operations(caller_id,retry_key,request_hash,record) VALUES(?,?,?,?)", [caller.sessionID.uuidString, retryKey, hash, try encode(operation)])
            return (operation, true)
        }
    }
    public func saveOperation(_ operation: CoordinationOperation, retryKey: String) throws {
        if let row = try rows("SELECT record FROM control_operations WHERE caller_id=? AND retry_key=?", [operation.callerID.uuidString, retryKey]).first,
           try decode(CoordinationOperation.self, row[0]).state == "reported", operation.state != "reported" { return }
        try execute("UPDATE control_operations SET record=? WHERE caller_id=? AND retry_key=?", [try encode(operation), operation.callerID.uuidString, retryKey])
    }
    public func beginTurn(caller: Caller, operation: inout CoordinationOperation, retryKey: String) throws -> Delegation {
        try transaction {
            var item = try ownedDelegation(operation.delegationID, caller: caller)
            item.turnID = operation.id; item.result = nil; item.state = .running
            operation.turnID = item.turnID; operation.state = "deliveryUncertain"
            try updateDelegation(item)
            try saveOperation(operation, retryKey: retryKey)
            return item
        }
    }
    public func recoverWorkers(caller: Caller, previousCoordinatorID: UUID, retryKey: String) throws -> [Delegation] {
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        return try transaction {
            let current = try peer(caller.sessionID, caller: caller)
            guard current.parentID == nil else { throw ChauffeurError("delegation_depth", "Only user-created coordinators may recover workers") }
            if let claim = try rows("SELECT controller_id,retry_key,adopted_ids FROM worker_recoveries WHERE previous_id=?", [previousCoordinatorID.uuidString]).first {
                guard Array(claim.prefix(2)) == [caller.sessionID.uuidString, retryKey] else { throw ChauffeurError("retry_conflict", "Another recovery already claimed this coordinator") }
                guard !claim[2].isEmpty else { throw ChauffeurError("recovery_receipt_unavailable", "This legacy recovery has no stable receipt; inspect delegation status") }
                let adoptedIDs = Set(try decode([UUID].self, claim[2]))
                return try allDelegations().filter { adoptedIDs.contains($0.id) }
            }
            let previous = try peer(previousCoordinatorID, caller: caller)
            guard previous.parentID == nil, !previous.state.isLive else {
                throw ChauffeurError("active_session", "Only an ended coordinator's workers can be recovered")
            }
            var adopted: [Delegation] = []
            for var item in try allDelegations() where item.controllingParentID == previousCoordinatorID {
                guard item.scope == caller.scope else { throw denied() }
                item.controllerID = caller.sessionID
                try execute("UPDATE delegations SET record=? WHERE id=?", [try encode(item), item.id.uuidString]); adopted.append(item)
            }
            try execute("INSERT INTO worker_recoveries(previous_id,controller_id,retry_key,adopted_ids) VALUES(?,?,?,?)", [previousCoordinatorID.uuidString, caller.sessionID.uuidString, retryKey, try encode(adopted.map(\.id))])
            return adopted
        }
    }
    public func allMessages() throws -> [Message] { try rows("SELECT record FROM messages ORDER BY rowid").map { try decode(Message.self, $0[0]) } }
    public func allDelegations() throws -> [Delegation] { try rows("SELECT record FROM delegations ORDER BY rowid").map { try decode(Delegation.self, $0[0]) } }
    public func allSessions() throws -> [Session] { try rows("SELECT record FROM sessions WHERE id NOT IN (SELECT id FROM deleted_sessions)").map { try decode(Session.self, $0[0]) } }
    public func pruneCompletedMessages(olderThan date: Date) throws -> Int {
        let candidates = try allMessages().filter { [.acknowledged, .cancelled, .failed].contains($0.state) && ($0.acknowledgedAt ?? $0.createdAt) < date }
        return try transaction {
            for item in candidates {
                try execute("INSERT INTO message_tombstones(sender_id,retry_key,request_hash,message_id) SELECT sender_id,retry_key,request_hash,id FROM messages WHERE id=?", [item.id.uuidString])
                try execute("DELETE FROM messages WHERE id=?", [item.id.uuidString])
            }
            // Hint rows go with their message; receipts only answer prompt retries.
            try execute("DELETE FROM inbox_hint_receipts WHERE created_at<?", [String(date.timeIntervalSince1970)])
            return candidates.count
        }
    }
}
