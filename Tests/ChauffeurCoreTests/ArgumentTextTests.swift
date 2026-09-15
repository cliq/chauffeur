import Foundation
import Testing
import ChauffeurCore

struct ArgumentTextTests {
    @Test func spacesNewlinesQuotesAndEscapesProduceLiteralArguments() throws {
        #expect(try ArgumentText.parse("--model sonnet --verbose\n--effort high") == ["--model", "sonnet", "--verbose", "--effort", "high"])
        #expect(try ArgumentText.parse(#"--model "name with spaces" --name 'client work'"#) == ["--model", "name with spaces", "--name", "client work"])
        #expect(try ArgumentText.parse(#"--name owner\'s\ work"#) == ["--name", "owner's work"])
        #expect(try ArgumentText.parse(#"--name "a\"b" --model "a\db""#) == ["--name", "a\"b", "--model", #"a\db"#])
        #expect(try ArgumentText.parse("--model \\\nsonnet") == ["--model", "sonnet"])
        #expect(try ArgumentText.parse("  \t\n") == [])
        #expect(try ArgumentText.parse("--name ''") == ["--name", ""])
        #expect(try ArgumentText.parse("--name pre'fixed value'post") == ["--name", "prefixed valuepost"])
        #expect(try ArgumentText.parse(#"--name '$(touch /tmp/never-run)' --model "$HOME""#) == ["--name", "$(touch /tmp/never-run)", "--model", "$HOME"])
    }
    @Test func incompleteInputIsRejectedAndExistingArgumentArraysRoundTrip() throws {
        for text in ["--model 'unfinished", "--model \"unfinished", "--name ends\\"] {
            #expect(throws: ChauffeurError.self) { try ArgumentText.parse(text) }
        }
        let existing = ["--model", "model name", "--name", "owner's 日本語 café", "", "a\\b", "\"quoted\"", "$HOME", "--value=a=b", "semi;colon"]
        #expect(try ArgumentText.parse(ArgumentText.format(existing)) == existing)
    }
    @Test func nativeYoloAliasIsAcceptedAndManagedFieldsRemainProtected() throws {
        try LaunchPolicy.validateArguments(ArgumentText.parse("--yolo --model chosen-model"), kind: .codex)
        for text in ["--cd '/some folder'", "-C/somewhere", "--config 'mcp_servers.chauffeur.url=bad'", "resume --last", "—yolo", "–yolo"] {
            #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments(ArgumentText.parse(text), kind: .codex) }
        }
        #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments([""], kind: .codex) }
    }
}
