import AppKit

struct InputSource: Equatable, Identifiable {
    let id: String
    let name: String
    let isSelectable: Bool
    let isEnabled: Bool
    let icon: NSImage?

    var identifier: String { id }
}
