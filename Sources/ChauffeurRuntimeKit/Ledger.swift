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
        """
        guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else { throw ChauffeurError("ledger_schema", "Cannot initialize coordination ledger") }
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
    public func register(_ session: Session) throws {
        if let existing = try rows("SELECT project_id,group_id,parent_id FROM sessions WHERE id=?", [session.id.uuidString]).first {
            guard existing[0] == session.projectID.uuidString, existing[1] == session.groupID.uuidString, existing[2] == (session.parentID?.uuidString ?? "") else {
                throw ChauffeurError("immutable_membership", "Session membership and parent cannot change")
            }
        }
        try execute("INSERT INTO sessions(id,project_id,group_id,parent_id,live,record) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET live=excluded.live,record=excluded.record", [session.id.uuidString, session.projectID.uuidString, session.groupID.uuidString, session.parentID?.uuidString, session.state.isLive ? "1" : "0", try encode(session)])
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
    public func revoke(sessionID: UUID) throws { try execute("UPDATE grants SET revoked=1 WHERE session_id=?", [sessionID.uuidString]) }
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
        try rows("SELECT record FROM sessions WHERE project_id=? AND group_id=?", scopeValues(caller)).map { try decode(Session.self, $0[0]) }
    }
    private func peer(_ id: UUID, caller: Caller) throws -> Session {
        guard let row = try rows("SELECT record FROM sessions WHERE id=? AND project_id=? AND group_id=?", [id.uuidString] + scopeValues(caller)).first else { throw denied() }
        return try decode(Session.self, row[0])
    }
    public func send(caller: Caller, recipientID: UUID, body: String, references: [String] = [], retryKey: String, replyToID: UUID? = nil, delegationID: UUID? = nil) throws -> Message {
        try Validation.require(!body.isEmpty && body.utf8.count <= 64 * 1024, "Message must contain 1–65,536 UTF-8 bytes")
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        try Validation.require(references.count <= 100 && references.allSatisfy { $0.utf8.count <= 4096 }, "Too many or oversized context references")
        let requestHash = JSONCoding.digest(try JSONCoding.encode([recipientID.uuidString, body, try encode(references), replyToID?.uuidString ?? "", delegationID?.uuidString ?? ""]))
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
            let message = Message(scope: caller.scope, senderID: caller.sessionID, recipientID: recipientID, body: body, references: references, replyToID: replyToID, delegationID: delegationID)
            try execute("INSERT INTO messages(id,project_id,group_id,sender_id,recipient_id,retry_key,request_hash,state,record) VALUES(?,?,?,?,?,?,?,?,?)", [message.id.uuidString] + scopeValues(caller) + [caller.sessionID.uuidString, recipientID.uuidString, retryKey, requestHash, message.state.rawValue, try encode(message)])
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
    private func saveMessage(_ message: Message) throws { try execute("UPDATE messages SET state=?,record=? WHERE id=?", [message.state.rawValue, try encode(message), message.id.uuidString]) }
    public func cancelMessage(_ id: UUID, caller: Caller) throws -> Message {
        try transaction {
            var item = try message(id, caller: caller)
            guard item.senderID == caller.sessionID else { throw denied() }
            guard item.state == .queued || item.state == .cancelled else { throw ChauffeurError("already_received", "Only queued messages can be cancelled") }
            item.state = .cancelled; try saveMessage(item); return item
        }
    }
    public func reserveDelegation(caller: Caller, task: String, presetID: UUID, folderID: UUID, shareCheckout: Bool, retryKey: String, limit: Int) throws -> (Delegation, Bool) {
        try Validation.require(!task.isEmpty && task.utf8.count <= 64 * 1024, "Task must contain 1–65,536 UTF-8 bytes")
        try Validation.require(!retryKey.isEmpty && retryKey.count <= 200, "A retry key of 1–200 characters is required")
        let hash = JSONCoding.digest(try JSONCoding.encode([task, presetID.uuidString, folderID.uuidString, String(shareCheckout)]))
        return try transaction {
            let parent = try peer(caller.sessionID, caller: caller)
            guard parent.parentID == nil else { throw ChauffeurError("delegation_depth", "Delegated sessions cannot launch further children") }
            if let row = try rows("SELECT request_hash,record FROM delegations WHERE parent_id=? AND retry_key=?", [caller.sessionID.uuidString, retryKey]).first {
                guard row[0] == hash else { throw ChauffeurError("retry_conflict", "Retry key was already used for a different delegation") }
                return (try decode(Delegation.self, row[1]), false)
            }
            let reserved = try rows("SELECT COUNT(*) FROM delegations d LEFT JOIN sessions s ON s.id=d.child_id WHERE d.parent_id=? AND (s.live=1 OR d.state IN ('reserved','launching'))", [caller.sessionID.uuidString]).first?[0] ?? "0"
            guard (Int(reserved) ?? 0) < limit else { throw ChauffeurError("child_limit", "Parent already has the configured maximum of \(limit) live children") }
            let item = Delegation(scope: caller.scope, parentID: caller.sessionID, task: task, presetID: presetID, folderID: folderID, shareCheckout: shareCheckout)
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
        guard previous.scope == value.scope, previous.childID == value.childID, previous.parentID == value.parentID else { throw ChauffeurError("immutable_membership", "Delegation membership cannot change") }
        try execute("UPDATE delegations SET state=?,record=? WHERE id=?", [value.state.rawValue, try encode(value), value.id.uuidString])
    }
    public func reportResult(caller: Caller, delegationID: UUID, result: String, retryKey: String) throws -> Message {
        try transaction {
            var item = try delegation(delegationID, caller: caller)
            guard item.childID == caller.sessionID else { throw denied() }
            let message = try send(caller: caller, recipientID: item.parentID, body: result, retryKey: "result:\(retryKey)", delegationID: item.id)
            item.result = result; item.state = .resultReported; try updateDelegation(item)
            return message
        }
    }
    public func allMessages() throws -> [Message] { try rows("SELECT record FROM messages ORDER BY rowid").map { try decode(Message.self, $0[0]) } }
    public func allDelegations() throws -> [Delegation] { try rows("SELECT record FROM delegations ORDER BY rowid").map { try decode(Delegation.self, $0[0]) } }
    public func allSessions() throws -> [Session] { try rows("SELECT record FROM sessions").map { try decode(Session.self, $0[0]) } }
    public func pruneCompletedMessages(olderThan date: Date) throws -> Int {
        let candidates = try allMessages().filter { [.acknowledged, .cancelled, .failed].contains($0.state) && ($0.acknowledgedAt ?? $0.createdAt) < date }
        return try transaction {
            for item in candidates {
                try execute("INSERT INTO message_tombstones(sender_id,retry_key,request_hash,message_id) SELECT sender_id,retry_key,request_hash,id FROM messages WHERE id=?", [item.id.uuidString])
                try execute("DELETE FROM messages WHERE id=?", [item.id.uuidString])
            }
            return candidates.count
        }
    }
}
