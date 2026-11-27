import AppKit
import SwiftUI

private enum AppIcon: String, CaseIterable, Identifiable {
    case sunny = "GopherIcon"
    case violet = "GopherIcon2"
    case blue = "GopherIcon3"
    case space = "GopherIcon4"

    static let storageKey = "appIcon"
    var id: Self { self }

    var title: String {
        switch self {
        case .sunny: return "Sunny"
        case .violet: return "Violet"
        case .blue: return "Blue"
        case .space: return "Space"
        }
    }

    var image: NSImage? {
        Bundle.main.url(forResource: rawValue, withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    }

    @MainActor
    func apply() {
        if self == .sunny {
            NSApp.applicationIconImage = nil
        } else if let image {
            NSApp.applicationIconImage = image
        }
    }
}

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    let browsing = BrowsingHistory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = UserDefaults.standard.string(forKey: AppIcon.storageKey)
            .flatMap(AppIcon.init(rawValue:)) ?? .sunny
        icon.apply()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        browsing.prepareToTerminate()
        return .terminateNow
    }
}

struct IconSettings: View {
    @AppStorage(AppIcon.storageKey) private var selected: AppIcon = .sunny

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Icon").font(.headline)
            Text("Choose the icon shown in the Dock while Nariscope is open.")
                .foregroundStyle(.secondary)

            if AppIcon.sunny.image == nil {
                Text("Icon choices are available in the packaged Nariscope app.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(AppIcon.allCases) { icon in
                        if let image = icon.image {
                            Button {
                                selected = icon
                                icon.apply()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 72, height: 72)
                                        .accessibilityHidden(true)
                                    Text(icon.title)
                                    Text(icon == .sunny ? "Default" : " ")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 110)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(icon.title)
                            .accessibilityAddTraits(selected == icon ? .isSelected : [])
                            .background(Color.accentColor.opacity(selected == icon ? 0.12 : 0),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected == icon ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}
