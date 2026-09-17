import Foundation
import Testing
@testable import ChauffeurTerminalInterface
import ChauffeurTerminalTesting

@MainActor
private final class RecordingDelegate: TerminalEngineAdapterDelegate {
    private(set) var generatedInput: [Data] = []
    private(set) var cellSizes: [TerminalCellSize] = []
    private(set) var titles: [String] = []
    private(set) var bellCount = 0

    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data) {
        generatedInput.append(data)
    }

    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) {
        cellSizes.append(size)
    }

    func terminal(_ adapter: any TerminalEngineAdapter, didChangeTitle title: String) {
        titles.append(title)
    }

    func terminalDidRingBell(_ adapter: any TerminalEngineAdapter) {
        bellCount += 1
    }
}

@MainActor
struct FakeAdapterTests {
    @Test func feedingRecordsOrderAndScreenTextStripsColorSequence() {
        let adapter = FakeTerminalEngineAdapter()
        adapter.feed(Data("\u{1b}[31mhello\u{1b}[0m ".utf8))
        adapter.feed(Data("world".utf8))
        #expect(adapter.feedCount == 2)
        #expect(adapter.fed.count == 2)
        #expect(adapter.screenText == "hello world")
    }

    @Test func sendKeyEncodesWithCurrentModesAndReachesDelegate() {
        let adapter = FakeTerminalEngineAdapter()
        let delegate = RecordingDelegate()
        adapter.delegate = delegate
        adapter.modes = TerminalModes(applicationCursor: true)

        adapter.sendKey(.up)

        #expect(adapter.sentKeys == [.up])
        #expect(adapter.generatedInput == [Data("\u{1b}OA".utf8)])
        #expect(delegate.generatedInput == [Data("\u{1b}OA".utf8)])
    }

    @Test func inputDisabledDropsGeneratedInput() {
        let adapter = FakeTerminalEngineAdapter()
        let delegate = RecordingDelegate()
        adapter.delegate = delegate

        adapter.setInputEnabled(false)
        adapter.sendKey(.escape)
        adapter.paste("hi")

        #expect(adapter.generatedInput.isEmpty)
        #expect(delegate.generatedInput.isEmpty)
    }

    @Test func simulateResizeNotifiesDelegate() {
        let adapter = FakeTerminalEngineAdapter()
        let delegate = RecordingDelegate()
        adapter.delegate = delegate

        adapter.simulateResize(cols: 100, rows: 40)

        #expect(adapter.cellSize == TerminalCellSize(cols: 100, rows: 40))
        #expect(delegate.cellSizes == [TerminalCellSize(cols: 100, rows: 40)])
    }

    @Test func conformanceCheckPassesForFakeAndReportsMissingCapabilities() {
        let adapter = FakeTerminalEngineAdapter()
        #expect(TerminalAdapterConformance.check(adapter).isEmpty)

        adapter.capabilities = []
        let problems = TerminalAdapterConformance.check(adapter)
        #expect(!problems.isEmpty)
    }

    @Test func makeViewReturnsSameInstance() {
        let adapter = FakeTerminalEngineAdapter()
        #expect(adapter.makeView() === adapter.makeView())
    }
}
