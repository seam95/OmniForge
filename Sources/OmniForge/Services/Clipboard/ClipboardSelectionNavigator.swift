import Foundation

struct ClipboardSelectionNavigator {
    static func nextSelection(in entries: [ClipboardEntry], currentID: UUID?, direction: Int) -> UUID? {
        guard !entries.isEmpty else { return nil }

        guard let currentID, let currentIndex = entries.firstIndex(where: { $0.id == currentID }) else {
            return entries.first?.id
        }

        let normalizedDirection: Int
        if direction > 0 {
            normalizedDirection = 1
        } else if direction < 0 {
            normalizedDirection = -1
        } else {
            normalizedDirection = 0
        }

        let nextIndex = min(max(currentIndex + normalizedDirection, 0), entries.count - 1)
        return entries[nextIndex].id
    }
}
