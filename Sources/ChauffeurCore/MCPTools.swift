import Foundation

public enum MCPTools {
    public static func validate(name: String, arguments: JSONValue) throws {
        guard let definition = definitions.first(where: { $0["name"].string == name }) else { throw ChauffeurError("unknown_tool", "Unknown Chauffeur tool") }
        guard case .object(let fields) = arguments, case .object(let allowed) = definition["inputSchema"]["properties"], fields.keys.allSatisfy({ allowed[$0] != nil }) else { throw ChauffeurError("invalid_arguments", "Arguments do not match this tool's schema") }
        for required in definition["inputSchema"]["required"].array.compactMap(\.string) {
            try Validation.require(fields[required] != nil, "\(required) is required")
        }
        for (name, value) in fields {
            let schema = allowed[name]!
            switch (schema["type"].string, value) {
            case ("string", .string): break
            case ("boolean", .bool): break
            case ("integer", .number(let number)):
                try Validation.require(number.rounded() == number && number >= Double(schema["minimum"].int ?? Int.min) && number <= Double(schema["maximum"].int ?? Int.max), "\(name) is outside its allowed integer range")
            case ("array", .array(let items)):
                try Validation.require(items.allSatisfy { $0.string != nil }, "\(name) must be an array of strings")
            default: throw ChauffeurError("invalid_arguments", "\(name) has the wrong value type")
            }
        }
    }
    public static var definitions: [JSONValue] {
        let string: JSONValue = .object(["type": .string("string")])
        let strings: JSONValue = .object(["type": .string("array"), "items": string])
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
            .object(["name": .string(name), "description": .string(description), "inputSchema": .object([
                "type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
            ])])
        }
        return [
            tool("chauffeur_discover", "Discover your authenticated project/group, registered repository paths and same-group sessions. Group membership is enforced by the server. Shared paths do not provide file isolation.", [:], []),
            tool("chauffeur_send_message", "Durably queue a message for a same-group session, including explicit context references. Supply a stable retryKey and reuse it only for the identical message. Queued does not mean read. Never paste messages into a terminal.", ["recipientID": string, "body": string, "references": strings, "retryKey": string], ["recipientID", "body", "retryKey"]),
            tool("chauffeur_inbox", "Read your own queued/received messages, optionally wait up to 25 seconds, and acknowledge IDs after processing them. Busy or exited recipients retain their inbox. Waiting does not submit terminal input.", ["waitSeconds": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(25)]), "acknowledge": strings], []),
            tool("chauffeur_reply", "Reply to a message received by this session. The server attributes the reply to you and routes it to the original sender in your group.", ["messageID": string, "body": string, "references": strings, "retryKey": string], ["messageID", "body", "retryKey"]),
            tool("chauffeur_delegate", "Launch a visible child in your project/group using a preset from your project's set and a registered folder. Default is a new Git worktree; set shareCheckout=true to explicitly share. Only user-created sessions may delegate, with a configurable live child limit (default four). Reuse retryKey after timeouts to avoid duplicate launches.", ["task": string, "presetID": string, "folderID": string, "shareCheckout": .object(["type": .string("boolean"), "default": .bool(false)]), "retryKey": string], ["task", "presetID", "folderID", "retryKey"]),
            tool("chauffeur_delegation_status", "Read a same-group delegation's launch state and separately reported task result. Process exit is not proof of task success.", ["delegationID": string], ["delegationID"]),
            tool("chauffeur_report_result", "As the delegated child, report a summary/result to your parent using a stable retryKey. This sends an attributable durable message; your interactive session remains available for follow-up.", ["delegationID": string, "result": string, "retryKey": string], ["delegationID", "result", "retryKey"])
        ]
    }
}
