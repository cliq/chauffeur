import Foundation
import Testing
import ChauffeurCore

struct TicketReferenceTests {
    @Test(arguments: [
        ("https://signoshealth.atlassian.net/browse/MBL-8593", "MBL-8593", "8593"),
        ("  https://acme.atlassian.net/browse/MBL-8593?focusedCommentId=1  ", "MBL-8593", "8593"),
        ("https://acme.atlassian.net/jira/software/projects/MBL/boards/3?selectedIssue=MBL-12", "MBL-12", "12"),
        ("https://linear.app/acme/issue/CLI-42/remove-the-tab-strip", "CLI-42", "42"),
        ("https://youtrack.example.com/issue/APP_2-7", "APP_2-7", "7"),
        ("https://github.com/acme/app-2/issues/123", nil, "123"),
        ("https://github.com/acme/app/pull/45#discussion_r1", nil, "45"),
        ("https://gitlab.com/acme/group/app/-/issues/9", nil, "9"),
        ("https://gitlab.com/acme/app/-/merge_requests/10", nil, "10")
    ] as [(String, String?, String)]) func linksNameTheirTicket(text: String, key: String?, number: String) {
        let ticket = TicketReference.parse(text)
        #expect(ticket == TicketReference(key: key, number: number, url: text.trimmingCharacters(in: .whitespaces)))
    }

    @Test(arguments: [("MBL-8593", "MBL-8593"), ("mbl-8593", "MBL-8593"), (" cli-7\n", "CLI-7")])
    func bareKeysNameTheirTicketWithoutALink(text: String, key: String) {
        #expect(TicketReference.parse(text) == TicketReference(key: key, number: String(key.split(separator: "-").last!)))
    }

    @Test(arguments: [
        "", "Fix login flow", "Fix MBL-8593 crash", "MBL-", "M-1", "-12", "1A-2", "MBL-12a", "hot-fix-2",
        "https://github.com/acme/app", "https://linear.app/acme/issue/remove-the-tab-strip", "https://example.com/release-2",
        "ftp://example.com/browse/MBL-1", "MBL-1 https://example.com/browse/MBL-1"
    ]) func otherTextIsNotATicket(text: String) {
        #expect(TicketReference.parse(text) == nil)
    }

    @Test(arguments: [
        (nil, "mbl-8593"), ("", "mbl-8593"), ("feature/{key}", "feature/mbl-8593"), ("feat/{KEY}", "feat/MBL-8593"),
        (" {number}-{key} ", "8593-mbl-8593"), ("feat/{key}-{slug}", "feat/mbl-8593-{slug}")
    ] as [(String?, String)]) func templatesRenderKeyedTickets(template: String?, expected: String) {
        #expect(TicketBranchTemplate.render(template, ticket: TicketReference(key: "MBL-8593", number: "8593")) == expected)
    }

    @Test func numberedTicketsUseTheirNumberForKeys() {
        let ticket = TicketReference(key: nil, number: "123", url: "https://github.com/acme/app/issues/123")
        #expect(TicketBranchTemplate.render("fix/{key}-{KEY}-{number}", ticket: ticket) == "fix/123-123-123")
    }

    @Test func resolutionAppliesTheFolderSettings() throws {
        var folder = ProjectFolder(path: "/tmp/repo")
        folder.branchTemplate = "feat/{key}"
        let link = "https://acme.atlassian.net/browse/MBL-8593"
        #expect(TicketResolution.resolve(link, folder: folder) == TicketResolution(key: "MBL-8593", number: "8593", url: link, branch: "feat/mbl-8593", title: "MBL-8593", task: link))
        #expect(TicketResolution.resolve("MBL-8593", folder: folder)?.task == nil)
        #expect(TicketResolution.resolve("https://github.com/acme/app/pull/4", folder: folder)?.title == "#4")
        #expect(TicketResolution.resolve("Fix login flow", folder: folder) == nil)
        folder.ticketLinkInTask = false
        #expect(TicketResolution.resolve(link, folder: folder)?.task == nil)
    }

    @Test func foldersSavedBeforeTicketSettingsDecode() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"repo","selectedPath":"/tmp/repo","canonicalPath":"/tmp/repo","availability":"available","registered":true}"#
        let folder = try JSONCoding.decode(ProjectFolder.self, from: Data(saved.utf8))
        #expect(folder.branchTemplate == nil && folder.putsTicketLinkInTask)
    }
}
