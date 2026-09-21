import Foundation
import Testing
@testable import ChauffeurCore

struct SessionSelectionHistoryTests {
    @Test func retracesSelectionsAndBranchesAfterGoingBack() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let available: Set<UUID> = [a, b, c, d]
        var history = SessionSelectionHistory()
        for id in [a, a, b, c] { history.record(id) }
        #expect(history.move(-1, available: available) == b)
        history.record(b) // Activation while navigating must not erase forward history.
        #expect(history.move(-1, available: available) == a)
        #expect(history.move(-1, available: available) == nil)
        #expect(history.move(1, available: available) == b)
        history.record(d)
        #expect(history.move(1, available: available) == nil)
        #expect(history.move(-1, available: available) == b)
    }
    @Test func skipsDeletedSessionsAndRemovesClosedTabs() {
        let a = UUID(), b = UUID(), c = UUID()
        var history = SessionSelectionHistory()
        for id in [a, b, c] { history.record(id) }
        #expect(history.move(-1, available: [a, c]) == a)
        #expect(history.move(1, available: [a, c]) == c)
        history.remove(b)
        #expect(history.move(-1, available: [a, b, c]) == a)
        history.remove(a)
        #expect(history.move(1, available: [a, b, c]) == c)
    }
}
