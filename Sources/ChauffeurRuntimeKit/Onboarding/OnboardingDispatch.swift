import Foundation
import ChauffeurCore

public extension OnboardingCoordinator {
    static let methods: Set<String> = ["previewTeamConfiguration", "addTeam", "setupInventory", "setupDraft", "saveSetupDraft", "previewSetupCopy", "createSetupConfiguration", "verifySetupAuthentication", "startSetupLogin", "cancelSetupLogin", "attachSetupLogin", "readSetupLogin", "inputSetupLogin", "resizeSetupLogin", "detachSetupLogin", "activeSetupLogin", "finishSetup", "discardSetup"]

    func handle(_ request: IPCRequest) async throws -> JSONValue {
        let params = request.params
        switch request.method {
        case "setupInventory": return try .from(await inventory())
        case "setupDraft": return try .from(await store.setupDraft())
        case "activeSetupLogin":
            guard let activeLogin else { return .null }
            return .object(["pairID": .string(activeLogin.pairID.uuidString), "handle": try .from(await loginHost.status(operationID: activeLogin.operationID))])
        case "attachSetupLogin": return try .from(await loginHost.attach(operationID: params.uuid("operationID"), takeControl: params["takeControl"].bool ?? false))
        case "readSetupLogin": return try .from(await loginHost.read(operationID: params.uuid("operationID"), generation: generation(params), cursor: UInt64(max(0, params["cursor"].int ?? 0))))
        case "inputSetupLogin":
            guard let encoded = params["bytes"].string, let data = Data(base64Encoded: encoded), data.count <= 64 * 1024 else { throw ChauffeurError("setup_input", "Invalid terminal input.") }
            try await loginHost.input(operationID: params.uuid("operationID"), generation: generation(params), bytes: data)
            return .object(["sent": .bool(true)])
        case "resizeSetupLogin":
            try await loginHost.resize(operationID: params.uuid("operationID"), generation: generation(params), cols: params["cols"].int ?? 100, rows: params["rows"].int ?? 30)
            return .object(["resized": .bool(true)])
        case "detachSetupLogin":
            await loginHost.detach(operationID: try params.uuid("operationID"), generation: try generation(params))
            return .object(["detached": .bool(true)])
        default: break
        }
        guard !mutating else { throw ChauffeurError("setup_busy", "Setup is processing another change. Try again shortly.") }
        mutating = true; defer { mutating = false }
        switch request.method {
        case "previewTeamConfiguration": return try .from(previewTeamConfiguration(params))
        case "addTeam": return try .from(await addTeam(params))
        case "saveSetupDraft": return try .from(await saveDraft(params))
        case "previewSetupCopy": return try .from(await preview(params))
        case "createSetupConfiguration": return try .from(await createConfiguration(params))
        case "verifySetupAuthentication": return try .from(await verify(params))
        case "startSetupLogin": return try .from(await startLogin(params))
        case "cancelSetupLogin": try await cancelLogin(params); return .object(["cancelled": .bool(true)])
        case "finishSetup": return try .from(await finish(params))
        case "discardSetup":
            var saved = try await requireDraft(params)
            if let activeLogin { try await cancelLogin(.object(["operationID": .string(activeLogin.operationID.uuidString)])); saved = try await requireDraft(params, versioned: false) }
            for operation in try await store.setupOperations() where operation.value.draftID == saved.value.id {
                try await publisher.discardStaging(operation: operation.value)
            }
            saved.value.dismissed = true; saved.value.completed = true
            _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
            return .object(["discarded": .bool(true)])
        default: throw ChauffeurError("unknown_method", "Unknown setup operation.")
        }
    }

    private func generation(_ params: JSONValue) throws -> UInt64 {
        guard let value = params["generation"].int, value > 0 else { throw ChauffeurError("setup_generation", "Reopen the sign-in terminal.") }
        return UInt64(value)
    }
}
