import Foundation
import GopherCore
import XCTest

final class CoreTests: XCTestCase {
    func testAddressRoundTripsLegacySelectorBytesAndSearch() throws {
        let address = try Address("gopher://[::1]:7070/7/index/%E9%2520%09two%20words")
        XCTAssertEqual(address.host, "::1")
        XCTAssertEqual(address.port, 7070)
        XCTAssertEqual(try address.request, Data("/index/".utf8) + Data([0xE9]) + Data("%20\ttwo words\r\n".utf8))
        XCTAssertEqual(try Address(address.string), address)
        XCTAssertEqual(try Address("floodgap.com").request, Data("\r\n".utf8))
        XCTAssertThrowsError(try Address("gopher://example.org/0/file%0D%0A"))
    }

    func testMenuSeparatesInfoAndDestinations() throws {
        let input = Data("iWelcome\tfake\t(null)\t0\r\n0Résumé\t/read\texample.org\t7070\r\nhWeb\tURL:https://example.org/\texample.org\t70\r\n.\r\n0Fake\t/x\tignored\t70\r\n".utf8)
        let items = GopherProtocol.menu(input)
        XCTAssertEqual(items.count, 3)
        XCTAssertNil(items[0].address)
        XCTAssertEqual(items[1].label, "Résumé")
        XCTAssertEqual(items[1].address?.string, "gopher://example.org:7070/0/read")
        XCTAssertEqual(items[2].webURL?.absoluteString, "https://example.org/")
        XCTAssertEqual(GopherProtocol.text(Data("one\r\n..two\r\n.\r\n".utf8)), "one\n.two\n")
    }

    func testParagraphAndFixedLayout() {
        let source = """
        About the server itself
        =======================

        The old road  leads through the forest and eventually reaches
        a small  village beside the river.  Travellers usually stop here
        before continuing north.

        +------+
        | <hi> |
        +------+
        """
        let html = Renderer.document(source)
        XCTAssertTrue(html.contains("<h2>About the server itself</h2>"))
        XCTAssertTrue(html.contains("<p>The old road leads through the forest and eventually reaches a small village beside the river. Travellers usually stop here before continuing north.</p>"))
        XCTAssertTrue(html.contains(Renderer.pre("+------+\n| <hi> |\n+------+")))
        XCTAssertEqual(Renderer.document(source, original: true), Renderer.pre(source))
    }

    func testEscapingAndLinkification() {
        let html = Renderer.document("See gopher://example.org/1/overview, or <script>alert('x')</script>.", links: true)
        XCTAssertTrue(html.contains("<a href=\"gopher://example.org/1/overview\">gopher://example.org/1/overview</a>,"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testCustomStylesheetPreservesCSSAndKeepsClosingTagInStyleElement() {
        let css = "@media (width < 600px) { p::after { content: \"</sTyLe>\" } }"
        XCTAssertEqual(Renderer.styleElementText(css),
                       "@media (width < 600px) { p::after { content: \"\\3C /style>\" } }")
    }

    func testMenuSuppressesStandaloneRulesWhileKeepingOriginalAndArtwork() {
        let art = "+------+\n| ART! |\n+------+"
        let source = "Welcome to this menu.\n\n-----\n\n" + art
        let menu = Renderer.document(source, showRules: false)
        XCTAssertFalse(menu.contains("<hr>"))
        XCTAssertTrue(menu.contains(Renderer.pre(art)))
        XCTAssertTrue(Renderer.document(source).contains("<hr>"))
        XCTAssertEqual(Renderer.document(source, original: true, showRules: false), Renderer.pre(source))
    }

    func testPythonCorpusParity() throws {
        guard let path = ProcessInfo.processInfo.environment["GOPHER_PARITY_FIXTURE"] else {
            throw XCTSkip("Set GOPHER_PARITY_FIXTURE to a JSON array of text and expected HTML.")
        }
        struct Fixture: Decodable { let name: String; let source: String; let expected: String }
        let pages = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(pages.isEmpty)
        for page in pages {
            let rendered = Renderer.document(page.source)
            XCTAssertTrue(rendered == page.expected, "Swift and Python differed on \(page.name)")
        }
    }

    func testNetworkFixture() async throws {
        guard let url = ProcessInfo.processInfo.environment["GOPHER_TEST_URL"] else {
            throw XCTSkip("Set GOPHER_TEST_URL to the root of a Gopher test server.")
        }
        let address = try Address(url)
        let menu = GopherProtocol.menu(try await GopherClient.fetch(address))
        let text = try XCTUnwrap(menu.first(where: { $0.type == 48 })?.address)
        let body = GopherProtocol.text(try await GopherClient.fetch(text))
        XCTAssertFalse(body.isEmpty)
        if let search = menu.first(where: { $0.type == 55 })?.address,
           ProcessInfo.processInfo.environment["GOPHER_TEST_SEARCH"] != nil {
            let results = GopherProtocol.menu(try await GopherClient.fetch(search.searching("forest trail")))
            XCTAssertTrue(results.contains { $0.label.contains("forest trail") })
        }
    }

    private func binaryFixture(_ selector: String) throws -> Address {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["GOPHER_TEST_URL"], env["GOPHER_TEST_SEARCH"] != nil else {
            throw XCTSkip("Start Tests/Fixtures/gopher_fixture.py and set GOPHER_TEST_URL and GOPHER_TEST_SEARCH.")
        }
        let root = try Address(url)
        return Address(host: root.host, port: root.port, type: 57, selector: Data(selector.utf8))
    }

    func testDownloadsBinaryLargerThanPreviewLimit() async throws {
        let address = try binaryFixture("/large.bin")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("large.bin")
        try Data("old bytes".utf8).write(to: destination)

        do {
            _ = try await GopherClient.fetch(address)
            XCTFail("Buffered fetch should still reject files larger than 16 MiB")
        } catch GopherError.tooLarge {
            // Expected for the same response that the download path can save.
        }
        let count = try await GopherClient.download(address, to: destination)
        XCTAssertEqual(count, 20 * 1024 * 1024)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["large.bin"])

        let input = try FileHandle(forReadingFrom: destination)
        defer { try? input.close() }
        let pattern = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        for _ in 0..<320 {
            XCTAssertEqual(try input.read(upToCount: pattern.count), pattern)
        }
        XCTAssertTrue((try input.read(upToCount: 1) ?? Data()).isEmpty)
    }

    func testCancellationRemovesPartialDownloadAndPreservesDestination() async throws {
        let address = try binaryFixture("/slow.bin")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.bin")
        let oldBytes = Data("keep this file".utf8)
        try oldBytes.write(to: destination)

        let download = Task { try await GopherClient.download(address, to: destination) }
        defer { download.cancel() }
        var received = false
        for _ in 0..<100 {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )
            if let partial = files.first(where: { $0.lastPathComponent.hasPrefix(".gopher-download.") }),
               let bytes = try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 {
                received = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(received, "The file should already be on disk before the server closes")
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        download.cancel()
        do {
            _ = try await download.value
            XCTFail("Expected the download to be canceled")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.bin"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
