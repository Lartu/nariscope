// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nariscope",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Nariscope", targets: ["Nariscope"])],
    targets: [
        .target(name: "GopherCore"),
        .executableTarget(name: "Nariscope", dependencies: ["GopherCore"],
                          resources: [.copy("Resources/Reader.css"), .copy("Resources/ReaderDark.css")]),
        .testTarget(name: "GopherCoreTests", dependencies: ["GopherCore"]),
        .testTarget(name: "NariscopeTests", dependencies: ["Nariscope", "GopherCore"])
    ]
)
