import Foundation

/// Decides whether a runtime snapshot carries anything a window would show
/// differently. Every inventory scan restamps `observedAt` and the storage
/// size drifts as terminals save history; neither alone warrants a new push
/// or a redraw of every project window.
public enum SnapshotChange {
    public static func key(_ snapshot: JSONValue) throws -> String {
        JSONCoding.digest(try JSONCoding.encode(significant(snapshot)))
    }
    static func significant(_ snapshot: JSONValue) -> JSONValue {
        guard case .object(var fields) = snapshot else { return snapshot }
        fields["snapshotStorage"] = nil
        if case .array(let inventories)? = fields["repositoryInventories"] {
            fields["repositoryInventories"] = .array(inventories.map { inventory in
                guard case .object(var inventory) = inventory else { return inventory }
                inventory["observedAt"] = nil
                return .object(inventory)
            })
        }
        return .object(fields)
    }
}
