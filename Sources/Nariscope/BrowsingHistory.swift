import Foundation
import GopherCore
import SwiftUI

struct TabSnapshot: Codable, Hashable {
    let addresses: [String?]
    let index: Int
    let original: Bool

    var currentURL: String? { addresses.indices.contains(index) ? addresses[index] : nil }
}

struct WindowSnapshot: Codable, Hashable {
    let tabs: [TabSnapshot]
    let selectedIndex: Int

    var currentURL: String? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].currentURL : nil }
}

enum WindowPage: Codable, Hashable {
    case address(String, UUID)
    case session(WindowSnapshot, UUID)
}

enum ClosedBrowserItem: Codable, Equatable {
    case tab(TabSnapshot)
    case window(WindowSnapshot)

    var canReopenAsTab: Bool {
        switch self {
        case .tab: return true
        case .window(let window): return window.tabs.count == 1
        }
    }

    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }
}

@MainActor
final class BrowsingHistory: ObservableObject {
    struct Visit: Codable, Identifiable {
        let id = UUID()
        let url: String
        let date: Date

        private enum CodingKeys: String, CodingKey { case url, date }
    }

    private struct Saved: Codable {
        var visits: [Visit] = []
        var closed: [ClosedBrowserItem] = []
        var lastSession: [WindowSnapshot] = []
        var openWindows: [WindowSnapshot] = []
    }

    @Published private(set) var visits: [Visit]
    @Published private(set) var closed: [ClosedBrowserItem]
    @Published private(set) var lastSession: [WindowSnapshot]
    @Published private(set) var currentURL: String?
    private let defaults: UserDefaults
    private let key = "browsingHistory"
    private var windows: [UUID: WindowSnapshot] = [:]
    private var windowOrder: [UUID] = []
    private var activeWindow: UUID?
    private var didStart = false
    private var terminating = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        visits = saved.visits
        closed = saved.closed
        lastSession = saved.openWindows.isEmpty ? saved.lastSession : saved.openWindows
        persist()
    }

    func startAddress() -> Address? {
        defer { didStart = true }
        if !didStart, let url = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("gopher://") }),
           let address = try? Address(url) {
            return address
        }
        return HomePage.address(in: defaults)
    }

    func update(_ window: WindowSnapshot, id: UUID, closedTab: TabSnapshot? = nil) {
        guard !terminating else { return }
        if windows[id] == nil { windowOrder.insert(id, at: 0) }
        guard windows[id] != window || closedTab != nil else { return }
        windows[id] = window
        if activeWindow == id { updateCurrentURL() }
        if let closedTab { addClosed(.tab(closedTab)) }
        persist()
    }

    func activate(_ id: UUID) {
        guard !terminating, windows[id] != nil else { return }
        activeWindow = id
        windowOrder.removeAll { $0 == id }
        windowOrder.append(id)
        updateCurrentURL()
        persist()
    }

    func closeWindow(_ id: UUID) {
        guard !terminating, let window = windows.removeValue(forKey: id) else { return }
        windowOrder.removeAll { $0 == id }
        if activeWindow == id {
            activeWindow = windowOrder.last
            updateCurrentURL()
        }
        addClosed(.window(window))
        persist()
    }

    func takeClosedTab() -> ClosedBrowserItem? { takeClosed(where: { $0.canReopenAsTab }) }
    func takeClosedWindow() -> ClosedBrowserItem? { takeClosed(where: { $0.isWindow }) }

    func takeLastSession() -> [WindowSnapshot] {
        let session = lastSession
        lastSession = []
        persist()
        return session
    }

    func visit(_ address: Address) {
        guard visits.first?.url != address.string else { return }
        visits.insert(Visit(url: address.string, date: Date()), at: 0)
        if visits.count > 500 { visits.removeLast() }
        persist()
    }

    func prepareToTerminate() {
        persist()
        terminating = true
    }

    private func updateCurrentURL() {
        let url = activeWindow.flatMap { windows[$0]?.currentURL }
        if currentURL != url { currentURL = url }
    }

    private func addClosed(_ item: ClosedBrowserItem) {
        closed.append(item)
        if closed.count > 30 { closed.removeFirst() }
    }

    private func takeClosed(where matches: (ClosedBrowserItem) -> Bool) -> ClosedBrowserItem? {
        guard let index = closed.lastIndex(where: matches) else { return nil }
        let item = closed.remove(at: index)
        persist()
        return item
    }

    private func persist() {
        let saved = Saved(visits: visits, closed: closed, lastSession: lastSession,
                          openWindows: windowOrder.compactMap { windows[$0] })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }
}

struct HistoryView: View {
    @ObservedObject var history: BrowsingHistory
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search history", text: $filter)
                .textFieldStyle(.roundedBorder)
            if history.visits.isEmpty {
                Text("No browsing history yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(history.visits.filter { filter.isEmpty || $0.url.localizedCaseInsensitiveContains(filter) }) { visit in
                    HStack {
                        Button(visit.url) {
                            openWindow(id: "browser", value: WindowPage.address(visit.url, UUID()))
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .help(visit.url)
                        Spacer()
                        Text(visit.date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 340)
    }
}
