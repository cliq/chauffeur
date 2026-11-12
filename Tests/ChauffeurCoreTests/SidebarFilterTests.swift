import Testing
@testable import ChauffeurCore

struct SidebarFilterTests {
    @Test func blankQueryFiltersNothing() {
        #expect(SidebarFilter.query("") == nil)
        #expect(SidebarFilter.query("  \t ") == nil)
    }

    @Test func matchesAnyFieldIgnoringCaseAndDiacritics() throws {
        let query = try #require(SidebarFilter.query(" API "))
        #expect(SidebarFilter.matches(query, "playden-api", "main"))
        #expect(SidebarFilter.matches(query, "playden-ps5", "feat/api-client"))
        #expect(!SidebarFilter.matches(query, "playden-ps5", "develop"))
        #expect(SidebarFilter.matches(try #require(SidebarFilter.query("cafe")), "Café"))
    }

    @Test func everyWordMustMatchSomeField() throws {
        let query = try #require(SidebarFilter.query("ps5 nfs3"))
        #expect(SidebarFilter.matches(query, "playden-ps5", "fix/nfs3-780", "fix-nfs3-780"))
        #expect(!SidebarFilter.matches(query, "playden-ps5", "fix/08-repo-online"))
    }
}
