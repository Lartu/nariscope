import GopherCore
@testable import Nariscope
import XCTest

final class BrowsingHistoryTests: XCTestCase {
    @MainActor
    func testRestoresOpenWindowsAndNavigationAcrossLaunches() throws {
        try withDefaults { defaults in
            let browsing = BrowsingHistory(defaults: defaults)
            let url = try Address("hole.example/0/story").string
            let reading = TabSnapshot(addresses: [nil, url, "gopher://hole.example/1"], index: 1, original: true)
            let empty = TabSnapshot(addresses: [], index: -1, original: false)
            let first = WindowSnapshot(tabs: [empty, reading], selectedIndex: 1)
            let second = WindowSnapshot(tabs: [empty], selectedIndex: 0)
            let firstID = UUID()
            let secondID = UUID()
            browsing.update(first, id: firstID)
            browsing.activate(firstID)
            XCTAssertEqual(browsing.currentURL, url)
            browsing.update(second, id: secondID)
            browsing.activate(secondID)
            XCTAssertNil(browsing.currentURL)
            browsing.visit(try Address(url))
            browsing.prepareToTerminate()
            browsing.closeWindow(secondID)

            let relaunched = BrowsingHistory(defaults: defaults)
            XCTAssertEqual(relaunched.visits.map(\.url), [url])
            XCTAssertEqual(relaunched.takeLastSession(), [first, second])
            XCTAssertTrue(relaunched.lastSession.isEmpty)
            XCTAssertTrue(relaunched.closed.isEmpty)
        }
    }

    @MainActor
    func testReopeningDoesNotOfferTheSameClosedTabTwice() throws {
        try withDefaults { defaults in
            let browsing = BrowsingHistory(defaults: defaults)
            let first = TabSnapshot(addresses: ["gopher://one.example/1"], index: 0, original: false)
            let second = TabSnapshot(addresses: ["gopher://two.example/1"], index: 0, original: false)
            let window = WindowSnapshot(tabs: [first], selectedIndex: 0)
            let id = UUID()
            browsing.update(window, id: id, closedTab: second)
            browsing.closeWindow(id)

            let relaunched = BrowsingHistory(defaults: defaults)
            XCTAssertEqual(relaunched.takeClosedTab(), .window(window))
            XCTAssertNil(relaunched.takeClosedWindow())
            XCTAssertEqual(relaunched.takeClosedTab(), .tab(second))
            XCTAssertNil(relaunched.takeClosedTab())

            let multiTab = WindowSnapshot(tabs: [first, second], selectedIndex: 1)
            relaunched.update(multiTab, id: id)
            relaunched.closeWindow(id)
            XCTAssertNil(relaunched.takeClosedTab())
            XCTAssertEqual(relaunched.takeClosedWindow(), .window(multiTab))
            XCTAssertNil(relaunched.takeClosedWindow())
        }
    }

    @MainActor
    func testBlankHomepageIsDistinctFromTheDefault() throws {
        try withDefaults { defaults in
            XCTAssertEqual(HomePage.address(in: defaults)?.string, HomePage.defaultURL)
            defaults.set("", forKey: HomePage.key)
            XCTAssertNil(HomePage.address(in: defaults))
            let url = try Address("hole.example/1/news").string
            defaults.set(url, forKey: HomePage.key)
            XCTAssertEqual(HomePage.address(in: defaults)?.string, url)
        }
    }

    @MainActor
    func testCleaningHistoryKeepsOlderVisitsAndPersists() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let ages: [TimeInterval] = [40 * day, 14 * day, 3 * day, 2 * 3_600, 3_600, 0]
        let expectations: [(BrowsingHistory.ClearRange, Int)] = [
            (.lastHour, 4), (.last24Hours, 3), (.lastWeek, 2), (.lastMonth, 1), (.all, 0)
        ]
        let address = try Address("hole.example")

        for (range, kept) in expectations {
            try withDefaults { defaults in
                let browsing = BrowsingHistory(defaults: defaults)
                let visitDates = ages.map { now.addingTimeInterval(-$0) }
                for date in visitDates { browsing.visit(address, at: date) }
                browsing.clearVisits(range, now: now)
                let relaunched = BrowsingHistory(defaults: defaults)
                XCTAssertEqual(relaunched.visits.map(\.date), Array(visitDates.prefix(kept).reversed()), range.rawValue)
            }
        }
    }

    @MainActor
    func testBookmarkMenuLabelsKeepNonRootSelectors() throws {
        try withDefaults { defaults in
            let bookmarks = BookmarkStore(defaults: defaults)
            bookmarks.add(try Address("lartu.net"), title: "lartunet")
            bookmarks.add(try Address("lartu.net:7070/0/news"), title: "News")
            XCTAssertEqual(bookmarks.entries.map(\.menuLabel), [
                "lartunet – lartu.net", "News – lartu.net:7070/0/news"
            ])
        }
    }

    private func withDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let name = "NariscopeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults)
    }
}
