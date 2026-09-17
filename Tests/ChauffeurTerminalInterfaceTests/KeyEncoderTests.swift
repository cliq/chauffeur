import Foundation
import Testing
@testable import ChauffeurTerminalInterface

struct KeyEncoderTests {
    private let normal = TerminalModes()
    private let applicationCursor = TerminalModes(applicationCursor: true)

    @Test func simpleKeys() {
        #expect(TerminalKeyEncoder.encode(.escape, modes: normal) == Data([0x1b]))
        #expect(TerminalKeyEncoder.encode(.tab, modes: normal) == Data([0x09]))
        #expect(TerminalKeyEncoder.encode(.backTab, modes: normal) == Data([0x1b, 0x5b, 0x5a]))
        #expect(TerminalKeyEncoder.encode(.enter, modes: normal) == Data([0x0d]))
        #expect(TerminalKeyEncoder.encode(.forwardDelete, modes: normal) == Data("\u{1b}[3~".utf8))
    }

    @Test func backspaceRespectsMode() {
        #expect(TerminalKeyEncoder.encode(.backspace, modes: normal) == Data([0x7f]))
        #expect(TerminalKeyEncoder.encode(.backspace, modes: TerminalModes(backspaceSendsControlH: true)) == Data([0x08]))
    }

    @Test func arrowsNormalMode() {
        #expect(TerminalKeyEncoder.encode(.up, modes: normal) == Data("\u{1b}[A".utf8))
        #expect(TerminalKeyEncoder.encode(.down, modes: normal) == Data("\u{1b}[B".utf8))
        #expect(TerminalKeyEncoder.encode(.right, modes: normal) == Data("\u{1b}[C".utf8))
        #expect(TerminalKeyEncoder.encode(.left, modes: normal) == Data("\u{1b}[D".utf8))
    }

    @Test func arrowsApplicationCursorMode() {
        #expect(TerminalKeyEncoder.encode(.up, modes: applicationCursor) == Data("\u{1b}OA".utf8))
        #expect(TerminalKeyEncoder.encode(.down, modes: applicationCursor) == Data("\u{1b}OB".utf8))
        #expect(TerminalKeyEncoder.encode(.right, modes: applicationCursor) == Data("\u{1b}OC".utf8))
        #expect(TerminalKeyEncoder.encode(.left, modes: applicationCursor) == Data("\u{1b}OD".utf8))
    }

    @Test func homeEndNormalMode() {
        #expect(TerminalKeyEncoder.encode(.home, modes: normal) == Data("\u{1b}[H".utf8))
        #expect(TerminalKeyEncoder.encode(.end, modes: normal) == Data("\u{1b}[F".utf8))
    }

    @Test func homeEndApplicationCursorMode() {
        #expect(TerminalKeyEncoder.encode(.home, modes: applicationCursor) == Data("\u{1b}OH".utf8))
        #expect(TerminalKeyEncoder.encode(.end, modes: applicationCursor) == Data("\u{1b}OF".utf8))
    }

    @Test func pageUpDown() {
        #expect(TerminalKeyEncoder.encode(.pageUp, modes: normal) == Data("\u{1b}[5~".utf8))
        #expect(TerminalKeyEncoder.encode(.pageDown, modes: normal) == Data("\u{1b}[6~".utf8))
    }

    @Test func controlLettersCaseInsensitive() {
        #expect(TerminalKeyEncoder.encode(.control("c"), modes: normal) == Data([0x03]))
        #expect(TerminalKeyEncoder.encode(.control("C"), modes: normal) == Data([0x03]))
        #expect(TerminalKeyEncoder.encode(.control("a"), modes: normal) == Data([0x01]))
        #expect(TerminalKeyEncoder.encode(.control("z"), modes: normal) == Data([0x1a]))
    }

    @Test func controlPunctuation() {
        #expect(TerminalKeyEncoder.encode(.control("@"), modes: normal) == Data([0x00]))
        #expect(TerminalKeyEncoder.encode(.control(" "), modes: normal) == Data([0x00]))
        #expect(TerminalKeyEncoder.encode(.control("["), modes: normal) == Data([0x1b]))
        #expect(TerminalKeyEncoder.encode(.control("\\"), modes: normal) == Data([0x1c]))
        #expect(TerminalKeyEncoder.encode(.control("]"), modes: normal) == Data([0x1d]))
        #expect(TerminalKeyEncoder.encode(.control("^"), modes: normal) == Data([0x1e]))
        #expect(TerminalKeyEncoder.encode(.control("_"), modes: normal) == Data([0x1f]))
        #expect(TerminalKeyEncoder.encode(.control("?"), modes: normal) == Data([0x7f]))
    }

    @Test func unencodableControlReturnsEmpty() {
        #expect(TerminalKeyEncoder.encode(.control("1"), modes: normal).isEmpty)
        #expect(TerminalKeyEncoder.encode(.control("!"), modes: normal).isEmpty)
    }

    @Test func functionKeys() {
        #expect(TerminalKeyEncoder.encode(.function(1), modes: normal) == Data("\u{1b}OP".utf8))
        #expect(TerminalKeyEncoder.encode(.function(2), modes: normal) == Data("\u{1b}OQ".utf8))
        #expect(TerminalKeyEncoder.encode(.function(3), modes: normal) == Data("\u{1b}OR".utf8))
        #expect(TerminalKeyEncoder.encode(.function(4), modes: normal) == Data("\u{1b}OS".utf8))
        #expect(TerminalKeyEncoder.encode(.function(5), modes: normal) == Data("\u{1b}[15~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(6), modes: normal) == Data("\u{1b}[17~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(7), modes: normal) == Data("\u{1b}[18~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(8), modes: normal) == Data("\u{1b}[19~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(9), modes: normal) == Data("\u{1b}[20~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(10), modes: normal) == Data("\u{1b}[21~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(11), modes: normal) == Data("\u{1b}[23~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(12), modes: normal) == Data("\u{1b}[24~".utf8))
        #expect(TerminalKeyEncoder.encode(.function(13), modes: normal).isEmpty)
    }

    @Test func pasteWithoutBracketedModeNormalizesNewlines() {
        let data = TerminalKeyEncoder.encodePaste("a\r\nb\nc", modes: normal)
        #expect(data == Data("a\rb\rc".utf8))
    }

    @Test func pasteWithBracketedModeWrapsAndKeepsTextVerbatim() {
        let data = TerminalKeyEncoder.encodePaste("a\r\nb\nc", modes: TerminalModes(bracketedPaste: true))
        var expected = Data("\u{1b}[200~".utf8)
        expected.append(contentsOf: Array("a\r\nb\nc".utf8))
        expected.append(contentsOf: Array("\u{1b}[201~".utf8))
        #expect(data == expected)
    }
}
