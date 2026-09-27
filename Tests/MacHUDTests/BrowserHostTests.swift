import XCTest
@testable import MacHUDCore

final class BrowserHostTests: XCTestCase {
    // MARK: Script sources

    func testArcOpensOneWindowPerURL() {
        let source = BrowserWindow.openSource(kind: .arc, url: "https://example.com")
        XCTAssertTrue(source.contains("tell application \"Arc\" to make new tab with properties {URL:\"https://example.com\"}"))
        XCTAssertTrue(source.hasPrefix("with timeout of 20 seconds"))
        XCTAssertTrue(source.hasSuffix("end timeout"))
    }

    func testSafariOpensANewDocument() {
        let source = BrowserWindow.openSource(kind: .safari, url: "https://example.com")
        XCTAssertTrue(source.contains("tell application \"Safari\" to make new document with properties {URL:\"https://example.com\"}"))
    }

    func testURLsAreQuotedAsAppleScriptLiterals() {
        let source = BrowserWindow.openSource(kind: .arc, url: "https://example.com/?q=\"a\"&p=c:\\x")
        XCTAssertTrue(source.contains("{URL:\"https://example.com/?q=\\\"a\\\"&p=c:\\\\x\"}"))
    }

    func testTabReadUsesEachBrowsersOwnTabProperty() {
        XCTAssertTrue(BrowserWindow.tabWindowsSource(kind: .arc).contains("URL of active tab of window gsI"))
        XCTAssertTrue(BrowserWindow.tabWindowsSource(kind: .safari).contains("URL of current tab of window gsI"))
        // `tab` names a class inside a browser tell block, so the separator is bound outside it.
        let arc = BrowserWindow.tabWindowsSource(kind: .arc)
        XCTAssertLessThan(arc.range(of: "set gsSep")!.lowerBound, arc.range(of: "tell application")!.lowerBound)
    }

    // MARK: Reading back a window's page

    func testParseTabWindows() {
        let parsed = BrowserWindow.parseTabWindows("Home / X\thttps://x.com/home\nDocs\thttps://docs.test\n")
        XCTAssertEqual(parsed, [BrowserWindow.TabWindow(name: "Home / X", url: "https://x.com/home"),
                                BrowserWindow.TabWindow(name: "Docs", url: "https://docs.test")])
    }

    func testParseTabWindowsKeepsEmptyURLs() {
        XCTAssertEqual(BrowserWindow.parseTabWindows("Empty\t\n"), [BrowserWindow.TabWindow(name: "Empty", url: "")])
        XCTAssertEqual(BrowserWindow.parseTabWindows(""), [])
    }

    func testURLByUniqueTitle() {
        let windows = [BrowserWindow.TabWindow(name: "Docs", url: "https://docs.test"),
                       BrowserWindow.TabWindow(name: "Mail", url: "https://mail.test")]
        XCTAssertEqual(BrowserWindow.url(forWindowTitled: "Mail", in: windows), "https://mail.test")
    }

    func testURLIsNilWhenNoWindowCarriesThatTitle() {
        // Arc titles a window after its space while the sidebar has focus, and its
        // AppleScript list can carry stale windows: position is not an identity, so
        // a capture that cannot name the page falls back to an app slot.
        let windows = [BrowserWindow.TabWindow(name: "Home / X", url: "https://x.com/home"),
                       BrowserWindow.TabWindow(name: "Home / X", url: "https://x.com")]
        XCTAssertNil(BrowserWindow.url(forWindowTitled: "The GNU Operating System", in: windows))
        XCTAssertNil(BrowserWindow.url(forWindowTitled: "", in: windows))
        XCTAssertNil(BrowserWindow.url(forWindowTitled: "Empty", in: [BrowserWindow.TabWindow(name: "Empty", url: "")]))
    }

    func testDuplicateTitlesOnlyAnswerWhenTheyAgree() {
        let same = [BrowserWindow.TabWindow(name: "Docs", url: "https://docs.test"),
                    BrowserWindow.TabWindow(name: "Docs", url: "https://docs.test")]
        XCTAssertEqual(BrowserWindow.url(forWindowTitled: "Docs", in: same), "https://docs.test")
        let different = [BrowserWindow.TabWindow(name: "Docs", url: "https://docs.test"),
                         BrowserWindow.TabWindow(name: "Docs", url: "https://other.test")]
        XCTAssertNil(BrowserWindow.url(forWindowTitled: "Docs", in: different))
    }

    // MARK: Host choice

    func testKindMapsToAndFromHosts() {
        XCTAssertEqual(BrowserWindow.Kind(host: .arc), .arc)
        XCTAssertEqual(BrowserWindow.Kind(host: .safari), .safari)
        XCTAssertNil(BrowserWindow.Kind(host: .chromeApp))
        XCTAssertNil(BrowserWindow.Kind(host: .builtin))
        XCTAssertEqual(BrowserWindow.Kind(bundleID: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(BrowserWindow.Kind(bundleID: "com.apple.Safari"), .safari)
        XCTAssertNil(BrowserWindow.Kind(bundleID: "com.google.Chrome"))
        XCTAssertNil(BrowserWindow.Kind(bundleID: nil))
    }

    func testHostForBrowserBundleID() {
        XCTAssertEqual(WebHost(browserBundleID: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(WebHost(browserBundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(WebHost(browserBundleID: "com.google.Chrome"), .chromeApp)
        XCTAssertEqual(WebHost(browserBundleID: "com.brave.Browser"), .chromeApp)
        XCTAssertNil(WebHost(browserBundleID: "org.mozilla.firefox"))
    }

    func testPreferredHostFollowsConfigThenDefaultBrowser() {
        XCTAssertEqual(WebHost.preferred(configuredBrowser: "com.google.Chrome",
                                         defaultHandler: "company.thebrowser.Browser"), .chromeApp)
        XCTAssertEqual(WebHost.preferred(configuredBrowser: nil,
                                         defaultHandler: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(WebHost.preferred(configuredBrowser: "", defaultHandler: "com.apple.Safari"), .safari)
        // An unknown default browser is no help; a Chromium app window is the default.
        XCTAssertEqual(WebHost.preferred(configuredBrowser: nil, defaultHandler: "org.mozilla.firefox"), .chromeApp)
        XCTAssertEqual(WebHost.preferred(configuredBrowser: nil, defaultHandler: nil), .chromeApp)
    }

    func testChromeAppFallsBackWhenTheConfiguredBrowserHasNoAppMode() {
        XCTAssertEqual(WebHost.chromeAppFallback(configuredBrowser: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(WebHost.chromeAppFallback(configuredBrowser: "com.apple.Safari"), .safari)
        XCTAssertNil(WebHost.chromeAppFallback(configuredBrowser: "com.google.Chrome"))
        XCTAssertNil(WebHost.chromeAppFallback(configuredBrowser: nil))
        XCTAssertNil(WebHost.chromeAppFallback(configuredBrowser: "org.mozilla.firefox"))
    }

    func testArcIsNotOfferedAsAChromiumAppHost() {
        XCTAssertFalse(ChromeApp.knownBundleIDs.contains("company.thebrowser.Browser"))
    }

    // MARK: Failures

    func testFailureReasonsAreReportable() {
        XCTAssertEqual(AppleScriptRunner.Failure.automationDenied.reason, "automationDenied")
        XCTAssertEqual(AppleScriptRunner.Failure.timedOut.reason, "timed out")
        XCTAssertEqual(AppleScriptRunner.Failure.failed("Arc got an error").reason, "Arc got an error")
        // The Apple event error for "not authorized to send Apple events".
        XCTAssertEqual(AppleScriptRunner.notAuthorized, -1743)
    }

    // MARK: Model

    func testOccupantRoundTripsTheNewHosts() throws {
        for host in [WebHost.arc, .safari, .chromeApp, .builtin] {
            let occupant = Occupant.web(url: "https://example.com", host: host)
            let data = try JSONEncoder().encode(occupant)
            XCTAssertEqual(try JSONDecoder().decode(Occupant.self, from: data), occupant)
        }
    }

    func testOldConfigsWithoutAHostStillMeanChromeApp() throws {
        let json = Data(#"{"kind":"web","url":"https://example.com"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Occupant.self, from: json),
                       .web(url: "https://example.com", host: .chromeApp))
    }
}
