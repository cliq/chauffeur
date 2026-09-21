import Foundation

/// Browser-style selection history shared by all project windows.
public struct SessionSelectionHistory {
    private var entries: [UUID] = []
    private var cursor = -1
    public init() {}
    public var current: UUID? { entries.indices.contains(cursor) ? entries[cursor] : nil }

    public mutating func record(_ id: UUID) {
        guard current != id else { return }
        entries.removeSubrange((cursor + 1)..<entries.count)
        entries.append(id)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        cursor = entries.count - 1
    }
    public mutating func remove(_ id: UUID) {
        for index in entries.indices.reversed() where entries[index] == id {
            entries.remove(at: index)
            if index <= cursor { cursor -= 1 }
        }
    }
    public mutating func move(_ direction: Int, available: Set<UUID>) -> UUID? {
        guard direction == -1 || direction == 1 else { return nil }
        var next = cursor + direction
        while entries.indices.contains(next) {
            if available.contains(entries[next]) {
                cursor = next
                return entries[next]
            }
            next += direction
        }
        return nil
    }
}
