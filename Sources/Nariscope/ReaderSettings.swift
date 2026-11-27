import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "Light", dark = "Dark"

    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
    var id: Self { self }
    var defaultCSS: String { Self.defaults[self] ?? "" }

    private static let defaults: [Self: String] = {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        return Dictionary(uniqueKeysWithValues: allCases.map { theme in
            let name = theme == .light ? "Reader" : "ReaderDark"
            guard let url = bundle.url(forResource: name, withExtension: "css"),
                  let css = try? String(contentsOf: url, encoding: .utf8) else {
                assertionFailure("\(name).css is missing from the application resources.")
                return (theme, "")
            }
            return (theme, css)
        })
    }()
}

struct ReaderStylesheets: DynamicProperty {
    // Keep the existing stylesheet preference as the Light override.
    @AppStorage("readerStylesheet") private var light: String?
    @AppStorage("readerDarkStylesheet") private var dark: String?
    @AppStorage("customReaderCSS") private var legacyLight = ""

    func css(for theme: ReaderTheme) -> String {
        switch theme {
        case .light:
            if let light { return light }
            return legacyLight.isEmpty ? theme.defaultCSS
                : theme.defaultCSS + "\n/* Custom rules from the previous version */\n" + legacyLight
        case .dark:
            return dark ?? theme.defaultCSS
        }
    }

    func save(_ css: String, for theme: ReaderTheme) {
        let override = css == theme.defaultCSS ? nil : css
        switch theme {
        case .light:
            light = override
            legacyLight = ""
        case .dark:
            dark = override
        }
    }
}

struct ReaderSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    private var stylesheets = ReaderStylesheets()
    @State private var editingTheme: ReaderTheme?
    @State private var drafts: [ReaderTheme: String] = [:]

    var body: some View {
        let theme = editingTheme ?? ReaderTheme(colorScheme)
        let savedCSS = stylesheets.css(for: theme)
        let draft = Binding(get: { drafts[theme] ?? savedCSS }, set: { drafts[theme] = $0 })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom CSS").font(.headline)
                Spacer()
                Picker("Stylesheet", selection: Binding(
                    get: { editingTheme ?? ReaderTheme(colorScheme) },
                    set: { editingTheme = $0 }
                )) {
                    ForEach(ReaderTheme.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text("Nariscope uses the stylesheet that matches your Mac’s appearance.")
                .foregroundStyle(.secondary)
            TextEditor(text: draft)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .border(.quaternary)
                .accessibilityLabel("\(theme.rawValue) stylesheet")
                .id(theme)
            HStack {
                Button("Load CSS File…") { loadFile(for: theme) }
                Button("Restore Defaults") { draft.wrappedValue = theme.defaultCSS }
                    .disabled(draft.wrappedValue == theme.defaultCSS)
                Spacer()
                Button("Apply") {
                    stylesheets.save(draft.wrappedValue, for: theme)
                    drafts[theme] = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.wrappedValue == savedCSS)
            }
        }
        .padding(20)
    }

    private func loadFile(for theme: ReaderTheme) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "css") ?? .plainText]
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { drafts[theme] = try String(contentsOf: url, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}
