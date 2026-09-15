import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CoordinationDiscoveryTests {
    @Test func childCanDiscoverItsDelegationAndReportAnAttributedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-discover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: [:])
        try await runtime.ledger.setNotificationsEnabled(true)
        let set = PresetSet(name: "Fixture")
        let project = Project(name: "Fixture", presetSetID: set.id)
        try await runtime.store.save(set)
        try await runtime.store.save(project)
        let parent = LedgerTests().session(project: project.id, group: project.groups[0].id)
        let outsider = LedgerTests().session(project: project.id, group: UUID())
        try await runtime.ledger.register(parent)
        try await runtime.ledger.register(outsider)
        let parentToken = try await runtime.ledger.issueGrant(sessionID: parent.id)
        let parentCaller = try await runtime.ledger.authenticate(parentToken)
        let reservation = try await runtime.ledger.reserveDelegation(caller: parentCaller, task: "Fixture task", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "fixture", limit: 4).0
        var child = LedgerTests().session(project: project.id, group: parent.groupID, parent: parent.id)
        child.id = reservation.childID; child.delegationID = reservation.id
        try await runtime.ledger.register(child)
        let childToken = try await runtime.ledger.issueGrant(sessionID: child.id)
        let discovery = try await runtime.callTool(token: childToken, name: "chauffeur_discover", arguments: .object([:]))
        #expect(discovery["sessionID"].string == child.id.uuidString)
        #expect(discovery["parentID"].string == parent.id.uuidString)
        #expect(discovery["delegationID"].string == reservation.id.uuidString)
        #expect(Set(discovery["peers"].array.compactMap { $0["id"].string }) == Set([parent.id.uuidString, child.id.uuidString]))
        let parentDiscovery = try await runtime.callTool(token: parentToken, name: "chauffeur_discover", arguments: .object([:]))
        #expect(parentDiscovery["delegationID"] == .null && parentDiscovery["parentID"] == .null)
        let report = try await runtime.callTool(token: childToken, name: "chauffeur_report_result", arguments: .object(["delegationID": discovery["delegationID"], "result": .string("Verified fixture result"), "retryKey": .string("fixture-result")]))
        #expect(report["senderID"].string == child.id.uuidString && report["recipientID"].string == parent.id.uuidString)
        #expect(try await runtime.ledger.inbox(caller: parentCaller).first?.body == "Verified fixture result")
        let notice = try #require(await runtime.ledger.pendingNotifications().first)
        #expect(notice.reason == .result && notice.route.sessionID == parent.id && notice.route.projectID == project.id)
    }
}
