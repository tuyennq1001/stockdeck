import Foundation

/// A user-authored note attached to a symbol, shared across watchlist and portfolio views.
struct SymbolNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String  // Defaults to "" for backward compatibility with old data
    var content: String
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", content: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    // Custom decoder to handle old data without a `title` field (added in v2.1)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, content, createdAt, updatedAt
    }
}
