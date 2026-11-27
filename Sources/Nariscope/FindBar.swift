import SwiftUI

struct FindRequest: Equatable {
    let text: String
    var backwards = false
    var step = 0
}

struct FindBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let matchFound: Bool?
    let move: (Bool) -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Find on Page", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !text.isEmpty { move(false) } }
                .onExitCommand(perform: close)
            if matchFound == false {
                Text("No matches").foregroundStyle(.secondary)
            }
            Button { move(true) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous match")
                .help("Previous match (⇧⌘G)")
                .disabled(text.isEmpty || matchFound == false)
            Button { move(false) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next match")
                .help("Next match (⌘G)")
                .disabled(text.isEmpty || matchFound == false)
            Button("Done", action: close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .onAppear { DispatchQueue.main.async { focused = true } }
        Divider()
    }
}
