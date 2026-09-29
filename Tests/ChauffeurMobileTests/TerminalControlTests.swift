import XCTest
import ChauffeurTerminalInterface
import ChauffeurTerminalSwiftTerm

@MainActor
final class TerminalControlTests: XCTestCase {
    func testCursorPositionReplyPreservesArmedControlForNextTypedKey() {
        let adapter = SwiftTermAdapter()
        let recorder = InputRecorder()
        adapter.delegate = recorder
        var consumedCount = 0
        adapter.armControl { consumedCount += 1 }

        // Codex queries the cursor while redrawing after the Ctrl row changes the size.
        adapter.feed(Data("\u{1b}[6n".utf8))

        XCTAssertEqual(consumedCount, 0)
        XCTAssertEqual(recorder.inputs, [Data("\u{1b}[1;1R".utf8)])

        adapter.view.insertText("c")
        XCTAssertEqual(consumedCount, 1)
        XCTAssertEqual(recorder.inputs.last, Data([0x03]))

        adapter.view.insertText("d")
        XCTAssertEqual(consumedCount, 1)
        XCTAssertEqual(recorder.inputs.last, Data("d".utf8))
    }
}

@MainActor
private final class InputRecorder: TerminalEngineAdapterDelegate {
    var inputs: [Data] = []

    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput bytes: Data) {
        inputs.append(bytes)
    }

    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) {}
}
