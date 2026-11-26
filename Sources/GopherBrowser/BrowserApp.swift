import AppKit
import GopherCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
struct GopherBrowserApp: App {
    var body: some Scene {
        WindowGroup("Gopher Browser") {
            BrowserWindow()
                .frame(minWidth: 500, minHeight: 360)
        }
        .defaultSize(width: 960, height: 750)

        Settings { ReaderSettings() }
    }
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
        .frame(width: 600, height: 370)
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

private struct BrowserWindow: View {
    @StateObject private var browser = Browser()
    @AppStorage(ReaderTheme.stylesheetKey) private var stylesheet: String?
    @AppStorage(ReaderTheme.legacyKey) private var legacyCSS = ""
    @FocusState private var addressFocused: Bool
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
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

                TextField("Gopher address", text: $browser.addressField)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { browser.submit(); addressFocused = false }
                Button("Focus address") { addressFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)

                if browser.loading { ProgressView().controlSize(.small) }
                if browser.canToggleOriginal {
                    Toggle("Original layout", isOn: $browser.original)
                        .toggleStyle(.button).help("Show or hide the original line breaks")
                }
                if browser.file != nil {
                    Button("Save…", action: browser.saveFile)
                }
            }
            .buttonStyle(.borderless)
            .padding(12)

            if browser.searchAddress != nil {
                HStack {
                    TextField("Search this Gopher index", text: $search)
                        .onSubmit { browser.search(search) }
                    Button("Search") { browser.search(search) }
                        .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider()
            ReaderView(html: ReaderPage.wrap(browser.content, css: ReaderTheme.resolve(stylesheet, legacy: legacyCSS)),
                       follow: browser.follow)
        }
        .task { browser.start() }
    }
}

@MainActor
private final class Browser: ObservableObject {
    private static let homeAddress = Address(host: "gopher.floodgap.com")
    @Published var addressField = homeAddress.string
    @Published var original = false { didSet { if canToggleOriginal { updateReader() } } }
    @Published private(set) var content = ""
    @Published private(set) var loading = false
    @Published private(set) var searchAddress: Address?
    @Published private(set) var file: Data?
    @Published private(set) var canToggleOriginal = false
    @Published private var history: [Address] = []
    @Published private var index = -1
    private var transfer: Task<Void, Never>?
    private var rendered = ""
    private var originalRendered = ""

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }
    private var current: Address? { history.indices.contains(index) ? history[index] : nil }

    func start() {
        guard history.isEmpty else { return }
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
        content = "<h1>Loading stopped</h1>"
    }

    func submit() {
        do { navigate(try Address(addressField)) }
        catch {
            stop()
            canToggleOriginal = false
            searchAddress = nil
            file = nil
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
        guard let file, let current else { return }
        let panel = NSSavePanel()
        let selector = GopherProtocol.decode(current.selector)
        let proposed = selector.split(separator: "/").last.map(String.init) ?? "download"
        panel.nameFieldStringValue = proposed == "." || proposed == ".." ? "download" : proposed
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try file.write(to: url, options: .atomic) }
            catch { self?.showError(error) }
        }
    }

    private func navigate(_ address: Address) {
        if current != address {
            history = Array(history.prefix(index + 1))
            history.append(address)
            index = history.count - 1
        }
        load(address)
    }

    private func load(_ address: Address) {
        transfer?.cancel()
        addressField = address.string
        canToggleOriginal = false
        searchAddress = nil
        file = nil
        loading = false
        if address.type == 55, address.query == nil {
            searchAddress = address
            content = "<h1>Search \(Renderer.escape(address.host))</h1><p>Enter a query above to search this Gopher index.</p>"
            return
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
                    rendered = title + "<article>\(result.1)</article>"
                    originalRendered = title + "<article>\(Renderer.pre(result.0))</article>"
                    canToggleOriginal = true
                    updateReader()
                default:
                    file = data
                    if let mime = ReaderPage.imageType(data, address: address) {
                        content = "<h1>\(ReaderPage.title(address))</h1><img alt=\"Gopher image\" src=\"data:\(mime);base64,\(data.base64EncodedString())\">"
                    } else {
                        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                        content = "<h1>\(ReaderPage.title(address))</h1><p>\(size) downloaded. Use Save to keep a copy.</p>"
                    }
                }
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                showError(error)
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

private struct ReaderView: NSViewRepresentable {
    let html: String
    let follow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(follow: follow) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        let follow: (URL) -> Void
        init(follow: @escaping (URL) -> Void) { self.follow = follow }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                decisionHandler(.cancel)
                follow(url)
            } else {
                decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }
    }
}

private enum ReaderPage {
    static func title(_ address: Address) -> String {
        let selector = GopherProtocol.decode(address.selector)
        let name = selector == "/" || selector.isEmpty ? address.host : selector.split(separator: "/").last.map(String.init) ?? selector
        return Renderer.escape(name)
    }

    static func imageType(_ data: Data, address: Address) -> String? {
        guard [103, 73, 112, 58].contains(address.type) else { return nil }
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
            if !info.isEmpty {
                let description = Renderer.document(info.joined(separator: "\n"), original: original,
                                                    links: true, showRules: false)
                if !description.isEmpty { content += "<section class=\"info\">\(description)</section>" }
                info.removeAll(keepingCapacity: true)
            }
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
                <div class="entry"><span class="entry-icon" role="img" aria-label="\(kind)">\(icon)</span>\
                <a href="\(Renderer.escape(destination))">\(label)</a></div>
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
        <main>\(body)</main></html>
        """
    }
}
