import XCTest
@testable import MacHUDCore

/// Whether an app can open another window is read from its menus by title: an enabled "New
/// Window" or "New <something> Window" item, a private or incognito one only when nothing else
/// matches. Never by ⌘N, which makes a note, a message, an event or a file in many apps.
final class NewWindowMenuTests: XCTestCase {
    private struct Item: NewWindowMenuItem {
        var menuTitle: String
        var menuEnabled = true
        var submenuItems: [Item] = []

        init(_ title: String, enabled: Bool = true, submenu: [Item] = []) {
            menuTitle = title
            menuEnabled = enabled
            submenuItems = submenu
        }
    }

    private func found(_ menus: [[Item]]) -> String? { NewWindowMenu.item(in: menus.map { ("File", $0) })?.menuTitle }
    private func found(titled menus: [(String, [Item])]) -> String? {
        NewWindowMenu.item(in: menus.map { (title: $0.0, items: $0.1) })?.menuTitle
    }

    func testNotesNewNoteIsNotAWindow() {
        // Notes: ⌘N is "New Note".
        XCTAssertNil(found([[Item("About Notes")], [Item("New Note"), Item("New Folder"), Item("Close")]]))
    }

    func testMailOpensAViewerWindowNotAMessage() {
        // Mail: ⌘N is "New Message"; ⌥⌘N is "New Viewer Window".
        XCTAssertEqual(found([[Item("New Message"), Item("New Viewer Window"), Item("Open Message")]]), "New Viewer Window")
    }

    func testFinder() {
        XCTAssertEqual(found([[Item("New Finder Window"), Item("New Folder"), Item("New Smart Folder"), Item("New Tab")]]),
                       "New Finder Window")
    }

    func testABrowserOpensAnOrdinaryWindowBeforeAPrivateOne() {
        XCTAssertEqual(found([[Item("New Tab"), Item("New Incognito Window"), Item("New Window")]]), "New Window")
        XCTAssertEqual(found([[Item("New Private Window")], [Item("New InPrivate Window")], [Item("New Window…")]]), "New Window…")
    }

    func testOnlyAPrivateWindowIsStillAWindow() {
        XCTAssertEqual(found([[Item("New Private Window"), Item("Close Window")]]), "New Private Window")
    }

    func testNothingToOpen() {
        XCTAssertNil(found([]))
        XCTAssertNil(found([[Item("Open…"), Item("Open in New Window"), Item("New Tab"), Item("New Window from Clipboard")]]))
    }

    func testADisabledItemDoesNotCount() {
        XCTAssertNil(found([[Item("New Window", enabled: false)]]))
        XCTAssertEqual(found([[Item("New Window", enabled: false), Item("New Viewer Window")]]), "New Viewer Window")
    }

    func testASubmenuNamedNewWindowGivesItsFirstItem() {
        // Terminal: Shell › New Window › one item per profile.
        let terminal = [[Item("New Window", submenu: [Item("New Window with Profile – Basic"), Item("New Window with Profile – Pro")]),
                         Item("New Tab")]]
        XCTAssertEqual(found(terminal), "New Window with Profile – Basic")
        XCTAssertNil(found([[Item("New Window", submenu: [Item("Basic", enabled: false)])]]))
    }

    func testOneSubmenuLevelIsSearched() {
        // Xcode: File › New › Window. The submenu's title and the item's make "New Window".
        let xcode = [[Item("New", submenu: [Item("File…"), Item("Target…"), Item("Project…"), Item("Window"), Item("Tab")]),
                      Item("Open…")]]
        XCTAssertEqual(found(xcode), "Window")
        XCTAssertEqual(found([[Item("Open Recent", submenu: [Item("New Window")])]]), "New Window")
        // Two levels down is not searched.
        XCTAssertNil(found([[Item("Other", submenu: [Item("Deeper", submenu: [Item("New Window")])])]]))
        // A submenu's private window waits behind an ordinary one anywhere.
        XCTAssertEqual(found([[Item("New", submenu: [Item("Private Window")])], [Item("New Viewer Window")]]),
                       "New Viewer Window")
    }

    /// The Window menu ends with a list of the app's open windows; one titled "New Finder Window"
    /// would bring that window forward, perhaps on another desktop, not open one.
    func testTheWindowMenusListOfWindowsIsSkipped() {
        let open = [Item("Minimize"), Item("Zoom"), Item(""), Item("Bring All to Front"), Item(""), Item("New Finder Window")]
        XCTAssertNil(found(titled: [("File", [Item("New Folder")]), ("Window", open)]))
        XCTAssertNil(found(titled: [("Window", [Item("New Finder Window")])]), "no separator: all of it is the list")
        let above = [Item("New Window"), Item(""), Item("Bring All to Front"), Item(""), Item("Untitled")]
        XCTAssertEqual(found(titled: [("Window", above)]), "New Window", "an item above the list counts")
    }

    func testTitlesAreMatchedInEnglishOnly() {
        // A localised menu ("Nouvelle fenêtre") is not recognised: the app counts as single-window.
        XCTAssertNil(found([[Item("Nouvelle fenêtre"), Item("Neues Fenster")]]))
    }

    /// Arc opens a new window on its own desktop, not the one showing: for getting a window here
    /// it is single-window, and its window is fetched.
    func testABrowserThatOpensWindowsOnItsOwnDesktopIsFetched() {
        XCTAssertTrue(BrowserWindow.Kind.arc.opensNewWindowsOnItsOwnDesktop)
        XCTAssertFalse(BrowserWindow.Kind.safari.opensNewWindowsOnItsOwnDesktop)
        XCTAssertEqual(NewWindowClass.of(bundleID: "company.thebrowser.Browser", hasNewWindowMenu: true), .single)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.Safari", hasNewWindowMenu: true), .browser)
        // A web page's window: by its host, or the browser a Chrome-app page falls back to.
        XCTAssertEqual(NewWindowClass.forWeb(host: .arc, configuredBrowser: nil), .single)
        XCTAssertEqual(NewWindowClass.forWeb(host: .chromeApp, configuredBrowser: "company.thebrowser.Browser"), .single)
        XCTAssertEqual(NewWindowClass.forWeb(host: .chromeApp, configuredBrowser: "com.google.Chrome"), .browser)
        XCTAssertEqual(NewWindowClass.forWeb(host: .safari, configuredBrowser: nil), .browser)
    }

    func testTheClassComesFromTheMenuAndTheBrowserList() {
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.google.Chrome", hasNewWindowMenu: false), .browser)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.mail", hasNewWindowMenu: true), .menu)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.Notes", hasNewWindowMenu: false), .single)
        // No app is kept single-window by name: one with a New Window item opens one.
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.apple.MobileSMS", hasNewWindowMenu: true), .menu)
        XCTAssertEqual(NewWindowClass.of(bundleID: "com.tinyspeck.slackmacgap", hasNewWindowMenu: true), .menu)
    }
}
