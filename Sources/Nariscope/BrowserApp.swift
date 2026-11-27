import AppKit
import GopherCore
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct NariscopeApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var appDelegate
    @StateObject private var bookmarks = BookmarkStore()

    var body: some Scene {
        WindowGroup("Nariscope", id: "browser", for: WindowPage.self) { $page in
            BrowserWindow(bookmarks: bookmarks, initialAddress: page.flatMap { try? Address($0.url) })
                .frame(minWidth: 500, minHeight: 360)
        }
        .defaultSize(width: 960, height: 750)
        .commands { BrowserCommands(bookmarks: bookmarks) }

        Settings {
            TabView {
                ReaderSettings()
                    .tabItem { Label("Stylesheet", systemImage: "paintbrush") }
                IconSettings()
                    .tabItem { Label("App Icon", systemImage: "app") }
            }
            .frame(width: 600, height: 400)
        }
    }
}

private struct WindowPage: Codable, Hashable {
    let url: String
    let id: UUID
}

private struct ReaderSettings: View {
    @AppStorage(ReaderTheme.stylesheetKey) private var stylesheet: String?
    @AppStorage(ReaderTheme.legacyKey) private var legacyCSS = ""
    @State private var draft = ""

    private var currentCSS: String { ReaderTheme.resolve(stylesheet, legacy: legacyCSS) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom CSS").font(.headline)
            Text("This stylesheet controls the appearance of every Gopher page.")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .border(.quaternary)
                .accessibilityLabel("Custom CSS")
            HStack {
                Button("Load CSS File…", action: loadFile)
                Button("Restore Defaults") { draft = ReaderTheme.defaultCSS }
                    .disabled(draft == ReaderTheme.defaultCSS)
                Spacer()
                Button("Apply") {
                    stylesheet = draft == ReaderTheme.defaultCSS ? nil : draft
                    legacyCSS = ""
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == currentCSS)
            }
        }
        .padding(20)
        .onAppear { draft = currentCSS }
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "css") ?? .plainText]
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { draft = try String(contentsOf: url, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

private enum ReaderTheme {
    static let stylesheetKey = "readerStylesheet"
    static let legacyKey = "customReaderCSS"
    static let defaultCSS: String = {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "Reader", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Reader.css is missing from the application resources.")
            return ""
        }
        return css
    }()

    static func resolve(_ stylesheet: String?, legacy: String) -> String {
        if let stylesheet { return stylesheet }
        if legacy.isEmpty { return defaultCSS }
        return defaultCSS + "\n/* Custom rules from the previous version */\n" + legacy
    }
}

private struct BrowserActions {
    let newTab: () -> Void
    let closeTab: () -> Void
    let hasMultipleTabs: Bool
    let focusAddress: () -> Void
    let addBookmark: (() -> Void)?
    let openBookmark: (Bookmark) -> Void
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
    @FocusedValue(\.browserActions) private var actions

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
        CommandMenu("Bookmarks") {
            Button("Add Bookmark") { actions?.addBookmark?() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(actions?.addBookmark == nil)
            Divider()
            if bookmarks.entries.isEmpty {
                Text("No Bookmarks")
            } else {
                ForEach(bookmarks.entries) { bookmark in
                    Button(bookmark.title) { actions?.openBookmark(bookmark) }
                        .disabled(actions == nil)
                }
                Divider()
                Menu("Remove Bookmark") {
                    ForEach(bookmarks.entries) { bookmark in
                        Button(bookmark.title) { bookmarks.remove(bookmark) }
                    }
                }
            }
        }
    }
}

@MainActor
private struct BrowserWindow: View {
    @ObservedObject var bookmarks: BookmarkStore
    let initialAddress: Address?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var tabs = [Browser()]
    @State private var selectedIndex = 0
    @AppStorage(ReaderTheme.stylesheetKey) private var stylesheet: String?
    @AppStorage(ReaderTheme.legacyKey) private var legacyCSS = ""
    @FocusState private var addressFocused: Bool

    private var active: Browser { tabs[selectedIndex] }

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(browser: active, bookmarks: bookmarks, addressFocused: $addressFocused,
                           newTab: newTab, closeTab: { closeTab(active.id) },
                           hasMultipleTabs: tabs.count > 1)
            Divider()
            if tabs.count > 1 {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabButton(browser: tab, isSelected: index == selectedIndex,
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
                    BrowserContent(browser: tab, css: ReaderTheme.resolve(stylesheet, legacy: legacyCSS)) { url, destination in
                        openLink(url, destination: destination, from: tab)
                    }
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                        .zIndex(selected ? 1 : 0)
                }
            }
        }
        .task { tabs.first?.start(at: initialAddress) }
    }

    private func newTab() {
        tabs.append(Browser())
        selectedIndex = tabs.count - 1
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
            let newTab = Browser()
            newTab.navigate(address)
            tabs.append(newTab)
        case .newWindow:
            openWindow(id: "browser", value: WindowPage(url: address.string, id: UUID()))
        }
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        addressFocused = false
        selectedIndex = index
    }

    private func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].stop()
        if tabs.count == 1 {
            dismiss()
            return
        }
        if index == selectedIndex { addressFocused = false }
        if index < selectedIndex || selectedIndex == tabs.count - 1 && index == selectedIndex {
            selectedIndex -= 1
        }
        tabs.remove(at: index)
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

    var body: some View {
        let current = browser.current
        let saved = current.map { bookmarks.contains($0) } ?? false
        let starLabel = saved ? "Remove bookmark" : "Add bookmark"
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: browser.back) { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).help("Back")
                    .keyboardShortcut("[", modifiers: .command)
                Button(action: browser.forward) { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
                Button {
                    if browser.loading { browser.stop() } else { browser.reload() }
                } label: { Image(systemName: browser.loading ? "xmark" : "arrow.clockwise") }
                    .help(browser.loading ? "Stop" : "Reload")
                    .keyboardShortcut("r", modifiers: .command)
                Button(action: browser.home) { Image(systemName: "house") }.help("Floodgap home")
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
        .focusedSceneValue(\.browserActions, BrowserActions(
            newTab: newTab,
            closeTab: closeTab,
            hasMultipleTabs: hasMultipleTabs,
            focusAddress: { addressFocused = true },
            addBookmark: saved ? nil : current.map { address in
                { bookmarks.add(address, title: browser.displayTitle) }
            },
            openBookmark: { bookmark in
                addressFocused = false
                if let address = try? Address(bookmark.url) { browser.navigate(address) }
            }
        ))
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
    private static let homeAddress = Address(host: "gopher.floodgap.com")
    let id = UUID()
    @Published var addressField = ""
    @Published var searchQuery = ""
    @Published var original = false { didSet { if canToggleOriginal { updateReader() } } }
    @Published private(set) var content = "<h1>New Tab</h1><p>Enter a Gopher address or choose a bookmark.</p>"
    @Published private(set) var loading = false
    @Published private(set) var searchAddress: Address?
    @Published private(set) var downloadAddress: Address?
    @Published private(set) var downloading = false
    @Published private(set) var canToggleOriginal = false
    @Published private var history: [Address] = []
    @Published private var index = -1
    private var transfer: Task<Void, Never>?
    private var showingSavePanel = false
    private var rendered = ""
    private var originalRendered = ""

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }
    var current: Address? { history.indices.contains(index) ? history[index] : nil }
    var displayTitle: String { current.map(ReaderPage.displayTitle) ?? "New Tab" }

    deinit { transfer?.cancel() }

    func start(at initialAddress: Address?) {
        guard history.isEmpty else { return }
        if let initialAddress { navigate(initialAddress); return }
        let arguments = CommandLine.arguments
        if let input = arguments.dropFirst().first(where: { $0.hasPrefix("gopher://") }),
           let address = try? Address(input) {
            navigate(address)
        } else { home() }
    }

    func home() { navigate(Self.homeAddress) }
    func back() { if canGoBack { index -= 1; load(history[index]) } }
    func forward() { if canGoForward { index += 1; load(history[index]) } }
    func reload() { if let current { load(current) } }

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
        content = "<h1>\(ReaderPage.title(address))</h1><p>Downloading…</p>"
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

    func navigate(_ address: Address) {
        if current != address {
            history = Array(history.prefix(index + 1))
            history.append(address)
            index = history.count - 1
        }
        load(address)
    }

    private func load(_ address: Address) {
        transfer?.cancel()
        transfer = nil
        addressField = address.string
        canToggleOriginal = false
        searchAddress = nil
        downloadAddress = nil
        loading = false
        downloading = false
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
        content = "<h1>Opening \(Renderer.escape(address.host))…</h1>"
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
        <style>\(Renderer.styleElementText(css))</style>
        <body>\(body)</body></html>
        """
    }
}
