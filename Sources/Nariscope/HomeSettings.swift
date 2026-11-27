import GopherCore
import SwiftUI

enum HomePage {
    static let key = "homepage"
    static let defaultURL = Address(host: "gopher.floodgap.com").string

    static func address(in defaults: UserDefaults = .standard) -> Address? {
        let url = defaults.string(forKey: key) ?? defaultURL
        return url.isEmpty ? nil : try? Address(url)
    }
}

struct HomeSettings: View {
    @ObservedObject var history: BrowsingHistory
    @AppStorage(HomePage.key) private var homepage = HomePage.defaultURL
    @State private var draft: String?

    var body: some View {
        let input = Binding(get: { draft ?? homepage }, set: { draft = $0 })
        let value = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = try? Address(value)

        VStack(alignment: .leading, spacing: 12) {
            Text("Homepage").font(.headline)
            Text("The Home button and new windows use this page.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Gopher address", text: input, prompt: Text("Blank page"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Homepage address")
                Button("Apply") { save(address?.string ?? "") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value == homepage || (!value.isEmpty && address == nil))
            }
            if !value.isEmpty, address == nil {
                Text("Enter a Gopher hostname or URL.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Set to Current Page") {
                    if let url = history.currentURL { save(url) }
                }
                .disabled(history.currentURL == nil)
                Button("Use Blank Page") { save("") }
            }
            Spacer()
        }
        .padding(20)
    }

    private func save(_ url: String) {
        homepage = url
        draft = nil
    }
}
