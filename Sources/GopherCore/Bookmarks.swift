import Combine
import Foundation

public struct Bookmark: Codable, Identifiable, Equatable {
    public let url: String
    public let title: String
    public var id: String { url }
}

@MainActor
public final class BookmarkStore: ObservableObject {
    @Published public private(set) var entries: [Bookmark]

    private static let storageKey = "gopherBookmarks"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey)
        entries = stored.flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    public func contains(_ address: Address) -> Bool {
        let url = Self.key(for: address)
        return entries.contains { $0.url == url }
    }

    public func add(_ address: Address, title: String) {
        guard !contains(address) else { return }
        entries.append(Bookmark(url: Self.key(for: address), title: title.isEmpty ? address.host : title))
        save()
    }

    public func toggle(_ address: Address, title: String) {
        let url = Self.key(for: address)
        if let entry = entries.first(where: { $0.url == url }) {
            remove(entry)
        } else {
            add(address, title: title)
        }
    }

    public func remove(_ bookmark: Bookmark) {
        entries.removeAll { $0.id == bookmark.id }
        save()
    }

    private static func key(for address: Address) -> String {
        Address(host: address.host.lowercased(), port: address.port, type: address.type,
                selector: address.selector, query: address.query).string
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
    }
}
