import Testing
import ChauffeurCore

struct WorktreeBranchNameTests {
    @Test(arguments: [
        ("Fix login flow", "fix-login-flow"),
        ("  Fix...login @{flow} / retry.lock?  ", "fix-login-flow-retry-lock"),
        ("--HEAD", "head"),
        ("Café 日本語", "cafe-日本語"),
        ("", ""),
        (" \n\t...@{}[]?!🚗", "")
    ]) func titlesBecomeBranchSuggestions(title: String, expected: String) {
        #expect(WorktreeBranchName.suggested(from: title) == expected)
    }
}
