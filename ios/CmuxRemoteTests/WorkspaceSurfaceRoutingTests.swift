import SwiftUI
import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class WorkspaceSurfaceRoutingTests: XCTestCase {
    func testBrowserSelectionBypassesTerminalSubscription() async {
        let surfaceRPC = WorkspaceRoutingRPC()
        let browserRPC = BrowserRPCRecorder()
        let workspaceStore = WorkspaceStore(rpc: surfaceRPC)
        workspaceStore.workspaces = [Workspace(id: "workspace-1", name: "Demo", index: 0)]
        workspaceStore.selectedId = "workspace-1"
        workspaceStore.surfacesByWorkspaceId = [
            "workspace-1": [
                Surface(id: "surface-browser", title: "browser", index: 0, kind: .browser),
            ],
        ]
        let surfaceStore = SurfaceStore(rpc: surfaceRPC)
        let browserStore = BrowserRemoteStore(rpc: browserRPC)

        let model = WorkspaceRoutingHarnessModel()
        let window = host(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            model: model
        )
        addTeardownBlock { window.isHidden = true }

        await waitUntil {
            browserStore.selectedSurfaceId == "surface-browser"
                && browserStore.screenshotImageData != nil
        }

        let surfaceCalls = await surfaceRPC.calls
        XCTAssertFalse(surfaceCalls.contains { $0.method == "surface.subscribe" })
        XCTAssertFalse(surfaceCalls.contains { $0.method == "surface.read_text" })
        XCTAssertNil(surfaceStore.subscribed)
        XCTAssertEqual(browserStore.selectedWorkspaceId, "workspace-1")
        XCTAssertEqual(browserStore.selectedSurfaceId, "surface-browser")

        let browserCalls = await browserRPC.calls
        XCTAssertEqual(browserCalls.map(\.method), ["browser.url.get", "browser.screenshot.read"])
    }

    func testTerminalSelectionUsesBoundedSubscriptionAndTerminalControls() async {
        let surfaceRPC = WorkspaceRoutingRPC()
        let browserRPC = BrowserRPCRecorder()
        let workspaceStore = WorkspaceStore(rpc: surfaceRPC)
        workspaceStore.workspaces = [Workspace(id: "workspace-1", name: "Demo", index: 0)]
        workspaceStore.selectedId = "workspace-1"
        workspaceStore.surfacesByWorkspaceId = [
            "workspace-1": [
                Surface(id: "surface-terminal", title: "shell", index: 0),
            ],
        ]
        let surfaceStore = SurfaceStore(rpc: surfaceRPC)
        let browserStore = BrowserRemoteStore(rpc: browserRPC)

        let model = WorkspaceRoutingHarnessModel()
        let window = host(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            model: model
        )
        addTeardownBlock { window.isHidden = true }

        await waitUntil { surfaceStore.subscribed == "surface-terminal" }

        let surfaceCalls = await surfaceRPC.calls
        XCTAssertTrue(surfaceCalls.contains { call in
            guard call.method == "surface.subscribe",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
        XCTAssertTrue(surfaceCalls.contains { call in
            guard call.method == "surface.read_text",
                  case .object(let params) = call.params,
                  case .int(let lines)? = params["lines"]
            else { return false }
            return lines == Int64(SurfaceStore.defaultSubscriptionLines)
        })
        XCTAssertNil(browserStore.selectedSurfaceId)
    }

    func testSwitchingBrowserToTerminalClearsStaleBrowserStateAndSubscribesTerminal() async {
        let surfaceRPC = WorkspaceRoutingRPC()
        let browserRPC = BrowserRPCRecorder()
        let workspaceStore = WorkspaceStore(rpc: surfaceRPC)
        workspaceStore.workspaces = [Workspace(id: "workspace-1", name: "Demo", index: 0)]
        workspaceStore.selectedId = "workspace-1"
        workspaceStore.surfacesByWorkspaceId = [
            "workspace-1": [
                Surface(id: "surface-browser", title: "browser", index: 0, kind: .browser),
                Surface(id: "surface-terminal", title: "shell", index: 1),
            ],
        ]
        let surfaceStore = SurfaceStore(rpc: surfaceRPC)
        let browserStore = BrowserRemoteStore(rpc: browserRPC)

        let model = WorkspaceRoutingHarnessModel()
        let window = host(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            model: model
        )
        addTeardownBlock { window.isHidden = true }
        await waitUntil { browserStore.selectedSurfaceId == "surface-browser" }

        model.preferredSurfaceId = "surface-terminal"
        await waitUntil { surfaceStore.subscribed == "surface-terminal" }

        XCTAssertNil(browserStore.selectedSurfaceId)
        XCTAssertNil(browserStore.screenshotImageData)
    }

    func testSwitchingTerminalToBrowserUnsubscribesTerminalAndClearsSubscription() async {
        let surfaceRPC = WorkspaceRoutingRPC()
        let browserRPC = BrowserRPCRecorder()
        let workspaceStore = WorkspaceStore(rpc: surfaceRPC)
        workspaceStore.workspaces = [Workspace(id: "workspace-1", name: "Demo", index: 0)]
        workspaceStore.selectedId = "workspace-1"
        workspaceStore.surfacesByWorkspaceId = [
            "workspace-1": [
                Surface(id: "surface-terminal", title: "shell", index: 0),
                Surface(id: "surface-browser", title: "browser", index: 1, kind: .browser),
            ],
        ]
        let surfaceStore = SurfaceStore(rpc: surfaceRPC)
        let browserStore = BrowserRemoteStore(rpc: browserRPC)

        let model = WorkspaceRoutingHarnessModel()
        let window = host(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            model: model
        )
        addTeardownBlock { window.isHidden = true }
        await waitUntil { surfaceStore.subscribed == "surface-terminal" }

        model.preferredSurfaceId = "surface-browser"
        await waitUntil { browserStore.selectedSurfaceId == "surface-browser" }

        let surfaceCalls = await surfaceRPC.calls
        XCTAssertTrue(surfaceCalls.contains { $0.method == "surface.unsubscribe" })
        XCTAssertNil(surfaceStore.subscribed)
    }

    func testMissingSurfaceKindRoutesAsTerminal() async {
        let surface = try! JSONDecoder().decode(
            Surface.self,
            from: Data(#"{"id":"surface-terminal","title":"shell","index":0}"#.utf8)
        )

        XCTAssertEqual(surface.kind, SurfaceKind.terminal)
    }

    private func host(
        workspaceStore: WorkspaceStore,
        surfaceStore: SurfaceStore,
        browserStore: BrowserRemoteStore,
        model: WorkspaceRoutingHarnessModel
    ) -> UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: WorkspaceRoutingHarness(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            model: model
        ))
        window.makeKeyAndVisible()
        return window
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

}

@MainActor
private final class WorkspaceRoutingHarnessModel: ObservableObject {
    @Published var preferredSurfaceId: String?
}

private struct WorkspaceRoutingHarness: View {
    let workspaceStore: WorkspaceStore
    let surfaceStore: SurfaceStore
    let browserStore: BrowserRemoteStore
    @ObservedObject var model: WorkspaceRoutingHarnessModel

    var body: some View {
        WorkspaceView(
            workspaceStore: workspaceStore,
            surfaceStore: surfaceStore,
            browserStore: browserStore,
            notifStore: NotificationStore(),
            hostStatusStore: HostStatusStore(rpc: WorkspaceRoutingRPC()),
            preferredSurfaceId: $model.preferredSurfaceId,
            onBack: {}
        )
    }
}

actor WorkspaceRoutingRPC: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        switch method {
        case "surface.read_text":
            return RPCResponse(id: method, result: .object(["text": .string("fresh terminal")]))
        case "surface.subscribe", "surface.unsubscribe", "surface.focus":
            return RPCResponse(id: method, ok: true, result: .object([:]))
        default:
            return RPCResponse(id: method, ok: true, result: .object([:]))
        }
    }
}
