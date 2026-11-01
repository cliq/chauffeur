import Testing
@testable import ChauffeurRuntimeKit

struct DocumentPathHarvesterTests {
    @Test func recoversPathsHardWrappedByClaudeWithIndentedContinuations() {
        let text = """
        ⏺ /Users/leolobato/Documents/Projetos/Personal/pla
          yden/ps5/playden-ps5/build/release-v0.7.1-beta.1
          /RELEASE_NOTES.md

          The GitHub release body is the same text without
          the top heading: /Users/leolobato/Documents/Pro
          jetos/Personal/playden/ps5/playden-ps5/build/rel
          ease-v0.7.1-beta.1/release-body.md
        """
        #expect(DocumentPathHarvester.paths(in: text) == [
            "/Users/leolobato/Documents/Projetos/Personal/playden/ps5/playden-ps5/build/release-v0.7.1-beta.1/release-body.md",
            "/Users/leolobato/Documents/Projetos/Personal/playden/ps5/playden-ps5/build/release-v0.7.1-beta.1/RELEASE_NOTES.md"
        ])
    }

    @Test func keepsSeparatePathsAndDoesNotJoinAcrossProseOrBlankLines() {
        let text = """
        /work/first.md
          /work/second.md
        /work/incomplete
          prose with spaces
          final.md
        /work/another

          separate.md
        """
        #expect(DocumentPathHarvester.paths(in: text) == ["separate.md", "final.md", "/work/second.md", "/work/first.md"])
    }

    @Test func extractsClaudeAndCodexStylePathsMostRecentFirst() {
        let text = """
        ⏺ Write(planning/implementation/foo-plan.md)
        See `docs/mobile-remote.md` for details.
        Opened /Users/x/notes.md:12 and /Users/x/other.MD:3:4
        see [plan](./a/b.md).
        ref <../up/c.markdown>, "~/home/d.mdx";
        file:///Users/a/b%20c.md
        """
        #expect(DocumentPathHarvester.paths(in: text) == [
            "/Users/a/b c.md", "~/home/d.mdx", "../up/c.markdown", "./a/b.md",
            "/Users/x/other.MD", "/Users/x/notes.md", "docs/mobile-remote.md", "planning/implementation/foo-plan.md"
        ])
    }

    @Test func extractsImagePaths() {
        let text = """
        Saved screenshot to /tmp/shots/home.png.
        ![diagram](docs/flow.JPEG) and `assets/icon@2x.webp`
        not an image: logo.pngx or v1.2
        """
        #expect(DocumentPathHarvester.paths(in: text) == ["assets/icon@2x.webp", "docs/flow.JPEG", "/tmp/shots/home.png"])
    }

    @Test func ignoresWebURLsAndDeduplicatesWithLatestMentionWinning() {
        let text = """
        https://github.com/o/r/blob/main/README.md
        a.md
        b.md
        a.md
        """
        #expect(DocumentPathHarvester.paths(in: text) == ["a.md", "b.md"])
    }

    @Test func pathsWithSpacesAreNotMatchedWholeAndOtherExtensionsAreIgnored() {
        let paths = DocumentPathHarvester.paths(in: "my notes/plan one.md and src/main.swift and v1.2")
        #expect(!paths.contains("my notes/plan one.md"))
        #expect(!paths.contains("src/main.swift"))
    }
}
