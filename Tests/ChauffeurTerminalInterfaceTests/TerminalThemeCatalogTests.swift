import Testing
import ChauffeurTerminalInterface

struct TerminalThemeCatalogTests {
    @Test func everyThemeIsCompleteAndUniquelyNamed() {
        let themes = TerminalThemeCatalog.all
        #expect(Set(themes.map(\.name)).count == themes.count)
        for theme in themes {
            #expect(theme.palette.count == 16, "\(theme.name)")
            #expect(([theme.background, theme.foreground] + theme.palette).allSatisfy { $0.count == 7 && $0.hasPrefix("#") }, "\(theme.name)")
        }
    }

    @Test func themesAreClassifiedByBackground() {
        #expect(TerminalThemeCatalog.theme(named: "Solarized Light")?.isDark == false)
        #expect(TerminalThemeCatalog.theme(named: "Tokyo Night")?.isDark == true)
        #expect(TerminalThemeCatalog.theme(named: "Missing") == nil)
        #expect(TerminalThemeCatalog.theme(named: nil) == nil)
    }
}
