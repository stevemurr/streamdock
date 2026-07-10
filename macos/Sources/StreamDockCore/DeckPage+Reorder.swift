import Foundation

extension DeckPage {
    /// Moves the key at slot `from` to slot `to`, as used by drag-and-drop
    /// reordering in the deck editor.
    ///
    /// - If `to` is empty, the key simply adopts the new position.
    /// - If `to` is occupied, the two keys swap positions, so no key is ever
    ///   lost.
    /// - Does nothing when `from == to`, when no key exists at `from`, or when
    ///   either slot lies outside `0..<slotCount`.
    ///
    /// - Parameter slotCount: Number of slots on the deck. Defaults to 15,
    ///   matching the 3 × 5 layout the editor renders.
    public mutating func moveKey(from: Int, to: Int, slotCount: Int = 15) {
        guard from != to,
              (0..<slotCount).contains(from),
              (0..<slotCount).contains(to),
              let sourceIndex = keys.firstIndex(where: { $0.position == from })
        else { return }
        if let destinationIndex = keys.firstIndex(where: { $0.position == to }) {
            keys[destinationIndex].position = from
        }
        keys[sourceIndex].position = to
    }
}
