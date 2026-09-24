import Foundation
import Testing
import GhosttyKit
import ChauffeurTerminalInterface
@testable import ChauffeurTerminalGhostty

@MainActor
struct GhosttyEngineTests {
    @Test func ghosttyAcceptsTheGeneratedConfiguration() {
        for appearance in [
            TerminalAppearance(fontSize: 13, scrollbackLines: 10_000, followsSystemColors: true),
            TerminalAppearance(fontName: "Menlo", fontSize: 12.5, scrollbackLines: 1_000, followsSystemColors: false),
            TerminalAppearance(fontSize: 14, followsSystemColors: true, lightColors: TerminalThemeCatalog.theme(named: "Solarized Light"),
                               darkColors: TerminalThemeCatalog.theme(named: "Tokyo Night")),
        ] {
            #expect(GhosttyTerminalAdapter(appearance: appearance).configurationDiagnostics == [])
        }
    }

    @Test func configurationBudgetsScrollbackInBytesAndClearsDefaultBindings() {
        let rendered = GhosttyConfiguration(TerminalAppearance(fontSize: 13, scrollbackLines: 500, followsSystemColors: false))
            .rendered(dark: false)
        #expect(rendered.contains("scrollback-limit = \(500 * GhosttyConfiguration.bytesPerScrollbackLine)\n"))
        #expect(rendered.contains("keybind = clear\n"))
        #expect(rendered.contains("keybind = alt+left=esc:b\n"))
        #expect(!rendered.contains("background ="))
        #expect(!rendered.contains("font-family"))
    }

    @Test func numbersUseAPeriodWhateverTheLocale() {
        #expect(GhosttyConfiguration.literal(13) == "13")
        #expect(GhosttyConfiguration.literal(12.5) == "12.5")
    }

    @Test func systemColorsProduceThemeFilesForBothAppearances() {
        let pair = GhosttyColorPair.system()
        #expect(pair.light.background != pair.dark.background)
        #expect(pair.light.configLines.contains { $0.hasPrefix("palette = 15=") })
        #expect(pair.dark.configLines.first?.hasPrefix("background = #") == true)
    }

    @Test func themesReplaceSystemColorsPerMode() {
        let dracula = TerminalThemeCatalog.theme(named: "Dracula")!
        let colors = GhosttyConfiguration(TerminalAppearance(followsSystemColors: true, darkColors: dracula)).colors
        #expect(colors?.dark.background == dracula.background)
        #expect(colors?.dark.configLines.contains("palette = 1=\(dracula.palette[1])") == true)
        let configuration = GhosttyConfiguration(TerminalAppearance(followsSystemColors: true, darkColors: dracula))
        #expect(configuration.rendered(dark: true).contains("background = \(dracula.background)\n"))
        #expect(!configuration.rendered(dark: false).contains("background = \(dracula.background)\n"))
        #expect(colors?.light == GhosttyPalette.resolved(in: .aqua))
        #expect(GhosttyConfiguration(TerminalAppearance(followsSystemColors: false)).colors == nil)
        #expect(GhosttyConfiguration(TerminalAppearance(followsSystemColors: false, lightColors: TerminalThemeCatalog.theme(named: "Nord Light"))).colors != nil)
    }

    @Test func semanticKeysMapToMacKeyCodes() {
        #expect(GhosttyKeyPress(.up)?.keycode == 0x7E)
        #expect(GhosttyKeyPress(.escape)?.keycode == 0x35)
        #expect(GhosttyKeyPress(.backTab)?.mods == GHOSTTY_MODS_SHIFT)
        #expect(GhosttyKeyPress(.function(12))?.keycode == 0x6F)
        #expect(GhosttyKeyPress(.function(13)) == nil)
        let controlC = GhosttyKeyPress(.control("C"))
        #expect(controlC?.keycode == 0x08)
        #expect(controlC?.mods == GHOSTTY_MODS_CTRL)
        #expect(controlC?.text == "c")
        #expect(GhosttyKeyPress(.control("[")) == nil)
    }

    @Test func droppedFilesAreSingleQuoted() {
        let files = [URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/it's")]
        #expect(GhosttySurfaceView.shellQuoted(files) == "'/tmp/a b' '/tmp/it'\\''s' ")
    }

    @Test func adapterSatisfiesTheContract() {
        let adapter = GhosttyTerminalAdapter()
        #expect(TerminalAdapterConformance.check(adapter) == [])
    }

    @Test func inputGateDropsFallbackInputWithoutASurface() {
        let adapter = GhosttyTerminalAdapter()
        let recorder = InputRecorder()
        adapter.delegate = recorder
        adapter.sendKey(.up)
        adapter.paste("a\nb")
        #expect(recorder.input == [Data("\u{1b}[A".utf8), Data("a\rb".utf8)])
        adapter.setInputEnabled(false)
        adapter.sendKey(.enter)
        adapter.paste("dropped")
        adapter.setInputEnabled(true)
        #expect(recorder.input.count == 2)
    }
}

@MainActor
private final class InputRecorder: TerminalEngineAdapterDelegate {
    var input: [Data] = []
    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data) { input.append(data) }
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) {}
}
