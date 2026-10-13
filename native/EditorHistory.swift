import Foundation

/// A reset starts a new editing baseline and invalidates earlier snapshots.
struct EditorUndoHistory<Value: Equatable> {
    private var snapshots: [Value] = []
    var isEmpty: Bool { snapshots.isEmpty }
    mutating func append(_ value: Value) {
        guard snapshots.last != value else { return }
        snapshots.append(value)
        if snapshots.count > 50 { snapshots.removeFirst() }
    }
    mutating func popLast() -> Value? { snapshots.popLast() }
    mutating func reset() { snapshots.removeAll() }
}

enum HistorySelection {
    static func visible(_ selected: Set<UUID>, ids: [UUID]) -> Set<UUID> {
        selected.intersection(Set(ids))
    }
    static func toggleAll(_ selected: Set<UUID>, ids: [UUID]) -> Set<UUID> {
        let visibleIDs = Set(ids)
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selected) ? [] : visibleIDs
    }
}
