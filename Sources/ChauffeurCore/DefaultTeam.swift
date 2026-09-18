import Foundation

public extension StoreSnapshot {
    /// The team used when nothing selects one: the flagged default, otherwise the first
    /// non-archived team by name. Nil only when there are no usable teams.
    var defaultPresetSet: PresetSet? {
        let usable = presetSets.map(\.value).filter { !$0.archived }
        return usable.first { $0.isDefault }
            ?? usable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.first
    }
}
