import AppKit
import GopherCore
import SwiftUI

@main
@MainActor
struct NariscopeApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var appDelegate
    @StateObject private var bookmarks = BookmarkStore()

    var body: some Scene {
        let size = BrowserWindowSize.lastSize
        WindowGroup("Nariscope", id: "browser", for: WindowPage.self) { $page in
            BrowserWindow(bookmarks: bookmarks, browsing: appDelegate.browsing, page: page)
                .frame(minWidth: 500, minHeight: 360)
        }
        .defaultSize(width: size.width, height: size.height)
        .commands { BrowserCommands(bookmarks: bookmarks, browsing: appDelegate.browsing) }

        Window("History", id: "history") {
            HistoryView(history: appDelegate.browsing)
        }
        .defaultSize(width: 760, height: 480)

        Settings {
            TabView {
                HomeSettings(history: appDelegate.browsing)
                    .tabItem { Label("General", systemImage: "gearshape") }
                ReaderSettings()
                    .tabItem { Label("Stylesheet", systemImage: "paintbrush") }
                IconSettings()
                    .tabItem { Label("App Icon", systemImage: "app") }
            }
            .frame(width: 600, height: 400)
        }
    }
}

private struct BrowserActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let hasMultipleTabs: Bool
    let focusAddress: () -> Void
    let addBookmark: (() -> Void)?
    let openBookmark: (Bookmark) -> Void
    let back: (() -> Void)?
    let forward: (() -> Void)?
    let home: () -> Void
    let openAddress: (Address) -> Void
    let reopenTab: (TabSnapshot) -> Void
}

private struct BrowserActionsKey: FocusedValueKey {
    typealias Value = BrowserActions
}

private extension FocusedValues {
    var browserActions: BrowserActions? {
        get { self[BrowserActionsKey.self] }
        set { self[BrowserActionsKey.self] = newValue }
    }
}

private struct BrowserCommands: Commands {
    @ObservedObject var bookmarks: BookmarkStore
    @ObservedObject var browsing: BrowsingHistory
    @FocusedValue(\.browserActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { actions?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(actions?.hasMultipleTabs == true ? "Close Tab" : "Close Window") {
                if let actions { actions.closeTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions == nil && NSApp.keyWindow == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Focus Address") { actions?.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandMenu("History") {
            Button("Show All History") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: .command)
            Divider()
            Button("Back") { actions?.back?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.back == nil)
            Button("Forward") { actions?.forward?() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.forward == nil)
            Button("Home") { actions?.home() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Reopen Last Closed Tab", action: reopenTab)
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!browsing.closed.contains(where: \.canReopenAsTab))
            Button("Reopen Last Closed Window") {
                if case .window(let snapshot) = browsing.takeClosedWindow() { reopenWindow(snapshot) }
            }
            .disabled(!browsing.closed.contains(where: \.isWindow))
            Button("Reopen All Windows from Last Session") {
                for window in browsing.takeLastSession() { reopenWindow(window) }
            }
            .disabled(browsing.lastSession.isEmpty)
            Divider()
            if browsing.visits.isEmpty {
                Text("No History")
            } else {
                ForEach(browsing.visits.prefix(15)) { visit in
                    Button(visit.url) {
                        if let actions, let address = try? Address(visit.url) {
                            actions.openAddress(address)
                        } else {
                            openWindow(id: "browser", value: WindowPage.address(visit.url, UUID()))
                        }
                    }
                }
            }
            Divider()
            Button("Clean History…", action: cleanHistory)
                .disabled(browsing.visits.isEmpty)
        }
        CommandMenu("Bookmarks") {
            Button("Add Bookmark") { actions?.addBookmark?() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(actions?.addBookmark == nil)
            Divider()
            if bookmarks.entries.isEmpty {
                Text("No Bookmarks")
            } else {
                ForEach(bookmarks.entries) { bookmark in
                    Button(bookmark.menuLabel) { actions?.openBookmark(bookmark) }
                        .disabled(actions == nil)
                }
                Divider()
                Menu("Remove Bookmark") {
                    ForEach(bookmarks.entries) { bookmark in
                        Button(bookmark.menuLabel) { bookmarks.remove(bookmark) }
                    }
                }
            }
        }
    }

    private func cleanHistory() {
        let ranges = BrowsingHistory.ClearRange.allCases
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        picker.addItems(withTitles: ranges.map(\.rawValue))
        picker.setAccessibilityLabel("Time range")

        let alert = NSAlert()
        alert.messageText = "Clean History"
        alert.informativeText = "Choose which visits to remove from your browsing history."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Clean History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, ranges.indices.contains(picker.indexOfSelectedItem) {
            browsing.clearVisits(ranges[picker.indexOfSelectedItem])
        }
    }

    private func reopenTab() {
        guard let item = browsing.takeClosedTab() else { return }
        let tab: TabSnapshot
        switch item {
        case .tab(let snapshot): tab = snapshot
        case .window(let window):
            guard let snapshot = window.tabs.first else { return }
            tab = snapshot
        }
        if let actions { actions.reopenTab(tab) }
        else { reopenWindow(WindowSnapshot(tabs: [tab], selectedIndex: 0)) }
    }

    private func reopenWindow(_ window: WindowSnapshot) {
        openWindow(id: "browser", value: WindowPage.session(window, UUID()))
    }
}

extension Bookmark {
    var menuLabel: String {
        let scheme = "gopher://"
        var displayedURL = url.hasPrefix(scheme) ? String(url.dropFirst(scheme.count)) : url
        if displayedURL.hasSuffix("/1"), let address = try? Address(url),
           address.type == 49, address.selector.isEmpty {
            displayedURL = String(displayedURL.dropLast(2))
        }
        return "\(title) – \(displayedURL)"
    }
}

@MainActor
private struct BrowserWindow: View {
    @ObservedObject var bookmarks: BookmarkStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var window: BrowserTabs
    private var stylesheets = ReaderStylesheets()
    @FocusState private var addressFocused: Bool

    init(bookmarks: BookmarkStore, browsing: BrowsingHistory, page: WindowPage?) {
        self.bookmarks = bookmarks
        _window = StateObject(wrappedValue: BrowserTabs(browsing: browsing, page: page))
    }

    var body: some View {
        let css = stylesheets.css(for: ReaderTheme(colorScheme))
        let active = window.active
        let tabs = window.tabs
        VStack(spacing: 0) {
            BrowserToolbar(browser: active, bookmarks: bookmarks, addressFocused: $addressFocused,
                           newTab: newTab, closeTab: { closeTab(active.id) },
                           hasMultipleTabs: tabs.count > 1, reopenTab: { snapshot in
                               addressFocused = false
                               window.reopen(snapshot)
                           })
            Divider()
            if tabs.count > 1 {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabButton(browser: tab, isSelected: index == window.selectedIndex,
                                          select: { select(index) }, close: { closeTab(tab.id) })
                                    .id(tab.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: active.id) { id in scroll.scrollTo(id, anchor: .center) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 5)
                Divider()
            }
            BrowserSearch(browser: active)
            ZStack {
                ForEach(tabs) { tab in
                    let selected = tab.id == active.id
                    BrowserContent(browser: tab, css: css) { url, destination in
                        openLink(url, destination: destination, from: tab)
                    }
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                        .zIndex(selected ? 1 : 0)
                }
            }
        }
        .background {
            BrowserWindowSize(onActivate: window.activate, onClose: window.close)
                .allowsHitTesting(false)
        }
        .task { window.start() }
    }

    private func newTab() {
        window.newTab()
        addressFocused = true
    }

    private func openLink(_ url: URL, destination: LinkDestination, from tab: Browser) {
        guard url.scheme?.lowercased() == "gopher", let address = try? Address(url.absoluteString) else {
            tab.follow(url)
            return
        }
        switch destination {
        case .currentTab:
            tab.navigate(address)
        case .newTab:
            window.newTab(address: address)
        case .newWindow:
            openWindow(id: "browser", value: WindowPage.address(address.string, UUID()))
        }
    }

    private func select(_ index: Int) {
        guard index != window.selectedIndex else { return }
        addressFocused = false
        window.select(index)
    }

    private func closeTab(_ id: UUID) {
        if id == window.active.id { addressFocused = false }
        if window.closeTab(id) {
            dismiss()
        }
    }
}

@MainActor
private final class BrowserTabs: ObservableObject {
    @Published private(set) var tabs = [Browser()]
    @Published private(set) var selectedIndex = 0
    var active: Browser { tabs[selectedIndex] }

    private let id = UUID()
    private let browsing: BrowsingHistory
    private let page: WindowPage?
    private var started = false
    private var isKey = false

    init(browsing: BrowsingHistory, page: WindowPage?) {
        self.browsing = browsing
        self.page = page
    }

    func start() {
        guard !started else { return }
        started = true
        switch page {
        case .session(let snapshot, _):
            tabs = snapshot.tabs.map { makeTab($0) }
            if tabs.isEmpty { tabs = [makeTab()] }
            selectedIndex = tabs.indices.contains(snapshot.selectedIndex) ? snapshot.selectedIndex : 0
            for tab in tabs { tab.loadCurrent() }
        case .address(let url, _):
            tabs = [makeTab()]
            if let address = try? Address(url) { active.navigate(address) }
        case nil:
            tabs = [makeTab()]
            active.navigate(browsing.startAddress())
        }
        save()
        if isKey { browsing.activate(id) }
    }

    func newTab(address: Address? = nil) {
        let tab = makeTab()
        tabs.append(tab)
        if let address { tab.navigate(address) }
        else { selectedIndex = tabs.count - 1 }
        save()
    }

    func reopen(_ snapshot: TabSnapshot) {
        let tab = makeTab(snapshot)
        tabs.insert(tab, at: selectedIndex + 1)
        selectedIndex += 1
        save()
        tab.loadCurrent()
    }

    func select(_ index: Int) {
        selectedIndex = index
        save()
    }

    func closeTab(_ tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        if tabs.count == 1 {
            close()
            return true
        }
        let tab = tabs[index]
        tab.stop()
        if index < selectedIndex || index == selectedIndex && index == tabs.count - 1 {
            selectedIndex -= 1
        }
        tabs.remove(at: index)
        save(closedTab: tab.snapshot)
        return false
    }

    func activate() {
        isKey = true
        if started { browsing.activate(id) }
    }

    func close() {
        guard started else { return }
        started = false
        for tab in tabs { tab.stop() }
        browsing.closeWindow(id)
    }

    private func makeTab(_ snapshot: TabSnapshot? = nil) -> Browser {
        let tab = Browser(snapshot: snapshot)
        tab.onStateChange = { [weak self] in self?.save() }
        tab.onVisit = { [weak self] address in self?.browsing.visit(address) }
        return tab
    }

    private func save(closedTab: TabSnapshot? = nil) {
        guard started else { return }
        browsing.update(WindowSnapshot(tabs: tabs.map(\.snapshot), selectedIndex: selectedIndex),
                        id: id, closedTab: closedTab)
    }
}

private struct TabButton: View {
    @ObservedObject var browser: Browser
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: select) {
                Text(browser.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 132, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(browser.current?.string ?? "New Tab")
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .accessibilityLabel("Close \(browser.displayTitle) tab")
                .help("Close tab")
        }
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(isSelected ? 1 : 0), in: RoundedRectangle(cornerRadius: 5))
        .background(MiddleClickArea(action: close))
    }
}

private struct BrowserToolbar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: BookmarkStore
    @FocusState.Binding var addressFocused: Bool
    let newTab: () -> Void
    let closeTab: () -> Void
    let hasMultipleTabs: Bool
    let reopenTab: (TabSnapshot) -> Void

    var body: some View {
        let current = browser.current
        let saved = current.map { bookmarks.contains($0) } ?? false
        let starLabel = saved ? "Remove bookmark" : "Add bookmark"
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: browser.back) { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).help("Back")
                Button(action: browser.forward) { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).help("Forward")
                Button {
                    if browser.loading { browser.stop() } else { browser.reload() }
                } label: { Image(systemName: browser.loading ? "xmark" : "arrow.clockwise") }
                    .help(browser.loading ? "Stop" : "Reload")
                    .keyboardShortcut("r", modifiers: .command)
                Button(action: browser.home) { Image(systemName: "house") }.help("Home")
                Button(action: newTab) { Image(systemName: "plus") }
                    .accessibilityLabel("New tab").help("New tab (⌘T)")
            }
            TextField("Gopher address", text: $browser.addressField)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { browser.submit(); addressFocused = false }
            Button {
                if let address = current {
                    bookmarks.toggle(address, title: browser.displayTitle)
                }
            } label: {
                Image(systemName: saved ? "star.fill" : "star")
                    .foregroundStyle(saved ? Color.accentColor : Color.secondary)
            }
            .disabled(current == nil)
            .accessibilityLabel(starLabel)
            .help(starLabel)
            if browser.canToggleOriginal {
                Button {
                    browser.original.toggle()
                } label: {
                    Image(systemName: browser.original ? "doc.plaintext.fill" : "doc.plaintext")
                        .foregroundStyle(browser.original ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Original layout")
                .accessibilityAddTraits(browser.original ? .isSelected : [])
                .help(browser.original ? "Show rendered layout" : "Show original layout")
            }
            if browser.downloadAddress != nil {
                Button("Save…", action: browser.saveFile).disabled(browser.downloading)
            }
            if browser.loading { ProgressView().controlSize(.small) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .focusedSceneValue(\.browserActions, actions(current: current, saved: saved))
    }

    private func actions(current: Address?, saved: Bool) -> BrowserActions {
        let addBookmark: (() -> Void)?
        if let current, !saved {
            addBookmark = { bookmarks.add(current, title: browser.displayTitle) }
        } else {
            addBookmark = nil
        }
        return BrowserActions(
            newTab: newTab,
            closeTab: closeTab,
            hasMultipleTabs: hasMultipleTabs,
            focusAddress: { addressFocused = true },
            addBookmark: addBookmark,
            openBookmark: { bookmark in
                addressFocused = false
                if let address = try? Address(bookmark.url) { browser.navigate(address) }
            },
            back: browser.canGoBack ? { browser.back() } : nil,
            forward: browser.canGoForward ? { browser.forward() } : nil,
            home: browser.home,
            openAddress: { address in
                addressFocused = false
                browser.navigate(address)
            },
            reopenTab: reopenTab
        )
    }
}

private struct BrowserSearch: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if browser.searchAddress != nil {
            HStack {
                TextField("Search this Gopher index", text: $browser.searchQuery)
                    .onSubmit { browser.search(browser.searchQuery) }
                Button("Search") { browser.search(browser.searchQuery) }
                    .disabled(browser.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            Divider()
        }
    }
}

private struct BrowserContent: View {
    @ObservedObject var browser: Browser
    let css: String
    let follow: (URL, LinkDestination) -> Void

    var body: some View {
        ReaderView(html: ReaderPage.wrap(browser.content, css: css), follow: follow)
    }
}

@MainActor
private final class Browser: ObservableObject, Identifiable {
    let id = UUID()
    @Published var addressField = ""
    @Published var searchQuery = ""
    @Published var original = false {
        didSet {
            if canToggleOriginal { updateReader() }
            onStateChange?()
        }
    }
    @Published private(set) var content = "<h1>New Tab</h1><p>Enter a Gopher address or choose a bookmark.</p>"
    @Published private(set) var loading = false
    @Published private(set) var searchAddress: Address?
    @Published private(set) var downloadAddress: Address?
    @Published private(set) var downloading = false
    @Published private(set) var canToggleOriginal = false
    @Published private var history: [Address?] = []
    @Published private var index = -1
    var onStateChange: (() -> Void)?
    var onVisit: ((Address) -> Void)?
    private var transfer: Task<Void, Never>?
    private var showingSavePanel = false
    private var rendered = ""
    private var originalRendered = ""

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }
    var current: Address? { history.indices.contains(index) ? history[index] : nil }
    var displayTitle: String { current.map(ReaderPage.displayTitle) ?? "New Tab" }
    var snapshot: TabSnapshot {
        TabSnapshot(addresses: history.map { $0?.string }, index: index, original: original)
    }

    init(snapshot: TabSnapshot? = nil) {
        guard let snapshot else { return }
        history = snapshot.addresses.map { $0.flatMap { try? Address($0) } }
        index = history.indices.contains(snapshot.index) ? snapshot.index : -1
        original = snapshot.original
    }

    deinit { transfer?.cancel() }

    func home() { navigate(HomePage.address()) }
    func back() { if canGoBack { move(to: index - 1) } }
    func forward() { if canGoForward { move(to: index + 1) } }
    func reload() { loadCurrent() }

    func loadCurrent() {
        if history.indices.contains(index) { load(current) }
    }

    private func move(to newIndex: Int) {
        index = newIndex
        onStateChange?()
        if let current { onVisit?(current) }
        loadCurrent()
    }

    func stop() {
        transfer?.cancel()
        transfer = nil
        loading = false
        content = downloading ? "<h1>Download canceled</h1>" : "<h1>Loading stopped</h1>"
        downloading = false
    }

    func submit() {
        do { navigate(try Address(addressField)) }
        catch {
            stop()
            canToggleOriginal = false
            searchAddress = nil
            downloadAddress = nil
            showError(error)
        }
    }

    func search(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let searchAddress, !value.isEmpty { navigate(searchAddress.searching(value)) }
    }

    func follow(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "gopher":
            do { navigate(try Address(url.absoluteString)) }
            catch { showError(error) }
        case "http", "https": NSWorkspace.shared.open(url)
        default: break
        }
    }

    func saveFile() {
        guard let address = downloadAddress, !downloading, !showingSavePanel else { return }
        showingSavePanel = true
        let panel = NSSavePanel()
        let selector = GopherProtocol.decode(address.selector)
        let proposed = selector.split(separator: "/").last.map(String.init) ?? "download"
        panel.nameFieldStringValue = proposed == "." || proposed == ".." ? "download" : proposed
        panel.begin { [weak self] response in
            guard let self else { return }
            self.showingSavePanel = false
            guard response == .OK, let url = panel.url, self.downloadAddress == address else { return }
            self.download(address, to: url)
        }
    }

    private func download(_ address: Address, to url: URL) {
        transfer?.cancel()
        loading = true
        downloading = true
        content = "<h1 class=\"loadingtext\">\(ReaderPage.title(address))</h1><p>Downloading…</p>"
        transfer = Task { [weak self] in
            let result: Result<Int64, Error>
            do { result = .success(try await GopherClient.download(address, to: url)) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let count):
                let size = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
                self.content = "<h1>\(ReaderPage.title(address))</h1><p>Saved \(Renderer.escape(url.lastPathComponent)) (\(size)).</p>"
            case .failure(let error):
                self.content = "<h1>Couldn’t save this item</h1><p>\(Renderer.escape(error.localizedDescription))</p>"
            }
            self.loading = false
            self.downloading = false
        }
    }

    func navigate(_ address: Address?) {
        if index < 0 || current != address {
            history = Array(history.prefix(index + 1))
            history.append(address)
            index = history.count - 1
            onStateChange?()
        }
        if let address { onVisit?(address) }
        load(address)
    }

    private func load(_ address: Address?) {
        transfer?.cancel()
        transfer = nil
        addressField = address?.string ?? ""
        canToggleOriginal = false
        searchAddress = nil
        downloadAddress = nil
        loading = false
        downloading = false
        guard let address else {
            content = ""
            rendered = ""
            originalRendered = ""
            return
        }
        if address.type == 55, address.query == nil {
            searchAddress = address
            content = "<h1>Search \(Renderer.escape(address.host))</h1><p>Enter a query above to search this Gopher index.</p>"
            return
        }

        let isPage = [48, 49, 55, 104].contains(address.type)
        if !isPage {
            downloadAddress = address
            if !ReaderPage.isImage(address) {
                content = "<h1>\(ReaderPage.title(address))</h1><p>Click Save… to download this file.</p>"
                return
            }
        }

        loading = true
        content = "<h1 class=\"loadingtext\">Opening \(Renderer.escape(address.host))…</h1>"
        transfer = Task {
            do {
                let data = try await GopherClient.fetch(address)
                try Task.checkCancellation()
                switch address.type {
                case 49, 55:
                    let contents = await Task.detached(priority: .userInitiated) {
                        let menu = GopherProtocol.menu(data)
                        return (ReaderPage.menu(menu, address: address),
                                ReaderPage.menu(menu, address: address, original: true),
                                menu.contains { $0.type == 105 })
                    }.value
                    try Task.checkCancellation()
                    rendered = contents.0
                    originalRendered = contents.1
                    canToggleOriginal = contents.2
                    updateReader()
                case 48, 104:
                    let result = await Task.detached(priority: .userInitiated) {
                        let text = GopherProtocol.text(data)
                        return (text, Renderer.document(text, links: true))
                    }.value
                    try Task.checkCancellation()
                    let title = "<h1>\(ReaderPage.title(address))</h1>"
                    rendered = title + result.1
                    originalRendered = title + Renderer.pre(result.0)
                    canToggleOriginal = true
                    updateReader()
                default:
                    if let mime = ReaderPage.imageType(data, address: address) {
                        content = "<h1>\(ReaderPage.title(address))</h1><img alt=\"Gopher image\" src=\"data:\(mime);base64,\(data.base64EncodedString())\">"
                    } else {
                        content = "<h1>\(ReaderPage.title(address))</h1><p>No preview is available. Click Save… to download this file.</p>"
                    }
                }
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                if ReaderPage.isImage(address) {
                    content = "<h1>Preview unavailable</h1><p>\(Renderer.escape(error.localizedDescription)) Click Save… to download the original.</p>"
                } else {
                    showError(error)
                }
                loading = false
            }
        }
    }

    private func updateReader() {
        content = original && canToggleOriginal ? originalRendered : rendered
    }

    private func showError(_ error: Error) {
        content = "<h1>Couldn’t open this item</h1><p>\(Renderer.escape(error.localizedDescription))</p>"
    }
}

private enum ReaderPage {
    static func displayTitle(_ address: Address) -> String {
        let selector = GopherProtocol.decode(address.selector)
        return selector == "/" || selector.isEmpty ? address.host : selector.split(separator: "/").last.map(String.init) ?? selector
    }

    static func title(_ address: Address) -> String { Renderer.escape(displayTitle(address)) }

    static func isImage(_ address: Address) -> Bool { [103, 73, 112, 58].contains(address.type) }

    static func imageType(_ data: Data, address: Address) -> String? {
        guard isImage(address) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: "GIF87a".utf8) || data.starts(with: "GIF89a".utf8) { return "image/gif" }
        if data.starts(with: "RIFF".utf8), data.dropFirst(8).starts(with: "WEBP".utf8) { return "image/webp" }
        return nil
    }

    static func menu(_ entries: [MenuItem], address: Address, original: Bool = false) -> String {
        var content = "<h1>\(title(address))</h1>"
        var info: [String] = []
        func flushInfo() {
            guard !info.isEmpty else { return }
            content += Renderer.document(info.joined(separator: "\n"), original: original, links: true)
            info.removeAll(keepingCapacity: true)
        }
        for entry in entries {
            if entry.type == 105 { info.append(entry.label); continue }
            flushInfo()
            let label = Renderer.escape(entry.label)
            if let destination = entry.address?.string ?? entry.webURL?.absoluteString {
                let (icon, kind): (String, String)
                switch entry.type {
                case 49: (icon, kind) = ("📁", "Folder")
                case 48: (icon, kind) = ("📄", "Text document")
                case 55: (icon, kind) = ("🔍", "Search")
                case 104: (icon, kind) = ("🌐", "Web")
                case 103, 73, 112, 58: (icon, kind) = ("🖼️", "Image")
                default: (icon, kind) = ("📦", "File")
                }
                content += """
                <p class="entry"><a href="\(Renderer.escape(destination))" \
                aria-label="\(label) (\(kind))">\(icon)&nbsp;\(label)</a></p>
                """
            } else {
                content += "<p>\(label)</p>"
            }
        }
        flushInfo()
        if entries.isEmpty { content += "<p>This menu is empty.</p>" }
        return content
    }

    static func wrap(_ body: String, css: String) -> String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <style>.loadingtext { line-height: 1.2; overflow-wrap: anywhere; }
        \(Renderer.styleElementText(css))</style>
        <body>\(body)</body></html>
        """
    }
}
