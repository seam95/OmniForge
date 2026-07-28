import Foundation

struct QuickPhraseEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var group: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), content: String, group: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.content = content
        self.group = group
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var previewLines: [String] {
        content.components(separatedBy: .newlines).prefix(3).map { $0.isEmpty ? "..." : $0 }
    }

    var hasMoreContent: Bool {
        content.components(separatedBy: .newlines).count > 3
    }
}
