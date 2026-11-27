// swift-tools-version: 5.9
import Foundation
import PackageDescription

let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Tests")
let localTests: [Target] = [
    .testTarget(name: "GopherCoreTests", dependencies: ["GopherCore"]),
    .testTarget(name: "NariscopeTests", dependencies: ["Nariscope", "GopherCore"])
].filter { FileManager.default.fileExists(atPath: testsDirectory.appendingPathComponent($0.name).path) }

let package = Package(
    name: "Nariscope",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Nariscope", targets: ["Nariscope"])],
    targets: [
        .target(name: "GopherCore"),
        .executableTarget(name: "Nariscope", dependencies: ["GopherCore"],
                          resources: [.copy("Resources/Reader.css"), .copy("Resources/ReaderDark.css"),
                                      .copy("Resources/Credits.rtf")])
    ] + localTests
)
