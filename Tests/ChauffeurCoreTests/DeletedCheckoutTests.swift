import Foundation
import Testing
@testable import ChauffeurCore

/// Suspension ends sessions whose checkout is gone, so only a confirmed absence may count.
struct DeletedCheckoutTests {
    @Test func onlyAConfirmedAbsenceCountsAsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-missing-\(UUID())")
        let checkout = root.appendingPathComponent("locked").appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: checkout.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(!Paths.directoryIsMissing(checkout.path))
        #expect(Paths.directoryIsMissing(root.appendingPathComponent("gone").path))
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(Paths.directoryIsMissing(file.path))

        // A folder that can't be searched hides its checkout without it being deleted.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: checkout.deletingLastPathComponent().path)
        #expect(!Paths.directoryIsMissing(checkout.path))
    }
}
