import SSHCore
import XCTest

@testable import SSHClient

@MainActor
final class WorkspaceViewModelTests: XCTestCase {
    private func makeWorkspace() throws -> (WorkspaceViewModel, HostListViewModel) {
        let (env, _, _) = try TestSupport.makeEnvironment(testCase: self)
        let hostList = HostListViewModel(env: env)
        let workspace = WorkspaceViewModel(env: env, hostList: hostList)
        addTeardownBlock { @MainActor in
            for tab in workspace.tabs {
                tab.prompter.cancelCurrent()  // unblock a connect waiting for a password prompt
                await tab.terminal.disconnect()
            }
        }
        return (workspace, hostList)
    }

    /// Unreachable local host so connection attempts fail fast without network.
    private func profile(_ name: String) -> HostProfile {
        HostProfile(name: name, hostname: "127.0.0.1", port: 1, username: "u")
    }

    func testOpenTabsSelectsNewestAndKeepsOrder() throws {
        let (workspace, _) = try makeWorkspace()
        let a = workspace.openTab(for: profile("a"))
        let b = workspace.openTab(for: profile("b"))
        let c = workspace.openTab(for: profile("c"))
        XCTAssertEqual(workspace.tabs.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(workspace.selectedTabID, c.id)
    }

    func testFiveTabsAreIndependent() throws {
        let (workspace, _) = try makeWorkspace()
        let tabs = (0..<5).map { workspace.openTab(for: profile("host\($0)")) }
        XCTAssertEqual(Set(tabs.map(\.id)).count, 5)
        XCTAssertEqual(Set(tabs.map { ObjectIdentifier($0.terminal) }).count, 5, "each tab owns its terminal/session")
        XCTAssertEqual(Set(tabs.map { ObjectIdentifier($0.prompter) }).count, 5)
    }

    func testClosingTabRemovesOnlyThatTabAndFixesSelection() throws {
        let (workspace, _) = try makeWorkspace()
        let a = workspace.openTab(for: profile("a"))
        let b = workspace.openTab(for: profile("b"))
        let c = workspace.openTab(for: profile("c"))
        workspace.selectedTabID = b.id

        workspace.requestClose(b.id)
        workspace.confirmClose()  // no-op if it closed immediately
        XCTAssertEqual(workspace.tabs.map(\.id), [a.id, c.id])
        XCTAssertEqual(workspace.selectedTabID, c.id, "selection moves to the neighbouring tab")

        workspace.requestClose(c.id)
        workspace.confirmClose()
        workspace.requestClose(a.id)
        workspace.confirmClose()
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selectedTabID)
    }

    func testCancelCloseKeepsTab() throws {
        let (workspace, _) = try makeWorkspace()
        let tab = workspace.openTab(for: profile("a"))
        workspace.closeCandidateID = tab.id
        workspace.cancelClose()
        XCTAssertNil(workspace.closeCandidateID)
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testMoveTabReorders() throws {
        let (workspace, _) = try makeWorkspace()
        let a = workspace.openTab(for: profile("a"))
        let b = workspace.openTab(for: profile("b"))
        let c = workspace.openTab(for: profile("c"))
        workspace.moveTab(c.id, before: a.id)
        XCTAssertEqual(workspace.tabs.map(\.id), [c.id, a.id, b.id])
        workspace.moveTab(c.id, before: b.id)
        XCTAssertEqual(workspace.tabs.map(\.id), [a.id, c.id, b.id])
        workspace.moveTab(a.id, before: a.id)  // no-op
        XCTAssertEqual(workspace.tabs.map(\.id), [a.id, c.id, b.id])
    }

    func testKeyboardSelectionHelpers() throws {
        let (workspace, _) = try makeWorkspace()
        let a = workspace.openTab(for: profile("a"))
        let b = workspace.openTab(for: profile("b"))
        let c = workspace.openTab(for: profile("c"))
        workspace.selectTab(at: 0)
        XCTAssertEqual(workspace.selectedTabID, a.id)
        workspace.selectNext()
        XCTAssertEqual(workspace.selectedTabID, b.id)
        workspace.selectPrevious()
        workspace.selectPrevious()
        XCTAssertEqual(workspace.selectedTabID, c.id, "wraps around")
        workspace.selectTab(at: 99)  // out of range: ignored
        XCTAssertEqual(workspace.selectedTabID, c.id)
    }

    func testDuplicateTabOpensSameHost() throws {
        let (workspace, _) = try makeWorkspace()
        let a = workspace.openTab(for: profile("a"))
        workspace.duplicateTab(a.id)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.tabs[1].profile.id, a.profile.id)
        XCTAssertNotEqual(workspace.tabs[1].id, a.id)
    }
}
