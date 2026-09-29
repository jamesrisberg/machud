import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class CapabilityRouterTests: XCTestCase {
    private let capability = "some-capability"
    private let plainID = "xyz.plain"
    private let providerID = "xyz.machud.provider"
    private let providerSock = "/tmp/router-provider-test.sock"
    private var dir: URL!
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var externals: ExternalPanels!
    private var router: CapabilityRouter!

    private var plain: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: plainID, name: "Plain", socket: "/tmp/router-plain-test.sock",
                                          panels: [HUDManifest.Panel(id: "main", title: "Plain")]),
                    bundleURL: dir.appendingPathComponent("Plain.app"))
    }
    private var provider: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: providerID, name: "Provider", socket: providerSock, panels: [
            HUDManifest.Panel(id: "main", title: "Provider", capabilities: [capability],
                              verbs: ["show", "hide", "frame"])]),
                    bundleURL: dir.appendingPathComponent("Provider.app"))
    }

    override func setUpWithError() throws {
        dir = FakeBundles.tempDir("router")
        workspace = FakeWorkspace()
        workspace.installed = [plainID, providerID]
        connector = FakeConnector()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: { _, _ in })
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        router = CapabilityRouter(capability: capability, externals: externals)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOnlyPanelsDeclaringTheCapabilityAreProviders() {
        externals.install([plain, provider], autoLaunch: [])
        XCTAssertEqual(router.providers.map(\.id), [providerID])
    }

    func testRunningProvidersIsEmptyBeforeTheProcessComesUp() {
        externals.install([provider], autoLaunch: [])
        XCTAssertEqual(router.runningProviders, [])
        XCTAssertEqual(router.providersJSON[0]["running"] as? Bool, false)
    }

    func testRunningProvidersIncludesAnUpProcessEvenWithoutASubscription() {
        workspace.running[providerID] = [4242]
        // Not `connector.reachable`, so it stays socketUnreachable rather than running.
        externals.install([provider], autoLaunch: [])
        XCTAssertEqual(router.runningProviders.map(\.id), [providerID])
        XCTAssertEqual(router.providersJSON[0]["running"] as? Bool, true)
    }

    func testTargetIsNilWithNoProvider() {
        externals.install([plain], autoLaunch: [])
        XCTAssertNil(router.target())
    }

    func testTargetFallsBackToTheFirstDiscoveredProviderWhenNoneRuns() {
        externals.install([provider], autoLaunch: [])
        XCTAssertEqual(router.target()?.id, providerID)
    }
}
