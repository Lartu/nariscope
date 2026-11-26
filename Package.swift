// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GopherBrowser",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GopherBrowser", targets: ["GopherBrowser"])],
    targets: [
        .target(name: "GopherCore"),
        .executableTarget(name: "GopherBrowser", dependencies: ["GopherCore"],
                          resources: [.copy("Resources/Reader.css")]),
        .testTarget(name: "GopherCoreTests", dependencies: ["GopherCore"])
    ]
)
