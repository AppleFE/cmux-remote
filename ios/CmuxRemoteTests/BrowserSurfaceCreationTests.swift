import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class BrowserSurfaceCreationTests: XCTestCase {
    func testBrowserCreationDispatchesBrowserOpenSplitAndTerminalCreationStillUsesSurfaceCreate() async throws {
        let rpc = BrowserCreationRPCRecorder()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()

        let terminal = try await store.createSurface(workspaceId: "workspace-1")
        let browser = try await store.createBrowserSurface(
            workspaceId: "workspace-1",
            initialURL: "https://example.test/cmux-browser"
        )
        await rpc.setSurfaceListLaggingBrowser()
        let fallback = try await store.createBrowserSurface(workspaceId: "workspace-1", initialURL: nil)

        XCTAssertEqual(terminal.kind, .terminal)
        XCTAssertEqual(browser.id, "browser-surface-1")
        XCTAssertEqual(browser.kind, .browser)
        XCTAssertEqual(fallback.id, "browser-surface-2")
        XCTAssertEqual(fallback.kind, .browser)
        XCTAssertEqual(fallback.title, "browser")

        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "surface.create",
                  case .object(let params) = call.params,
                  case .string("workspace-1")? = params["workspace_id"],
                  case .string("terminal")? = params["type"],
                  case .bool(true)? = params["focus"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "browser.open_split",
                  case .object(let params) = call.params,
                  case .string("workspace-1")? = params["workspace_id"],
                  case .string("https://example.test/cmux-browser")? = params["url"],
                  case .bool(true)? = params["focus"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { call in
            guard call.method == "browser.open_split",
                  case .object(let params) = call.params,
                  case .string("workspace-1")? = params["workspace_id"],
                  params["url"] == nil,
                  case .bool(true)? = params["focus"]
            else { return false }
            return true
        })
    }

    func testDemoRPCDispatchBrowserOpenSplitAddsBrowserSurface() async throws {
        let rpc = DemoRPCDispatch()

        let response = try await rpc.call(method: "browser.open_split", params: .object([
            "workspace_id": .string("WS-DEMO-1"),
            "url": .string("https://example.test/cmux-browser"),
            "focus": .bool(true),
        ]))
        let surfaceId = try response.unwrapResult().decode(SurfaceMutationPayload.self).surfaceId
        let list = try await rpc.call(
            method: "surface.list",
            params: .object(["workspace_id": .string("WS-DEMO-1")])
        ).unwrapResult()
        let payload = try list.decode(SurfaceListPayload.self)

        let created = payload.surfaces.map(\.model).first { $0.id == surfaceId }
        XCTAssertEqual(created?.kind, .browser)
        XCTAssertEqual(created?.title, "browser")
    }

    func testBrowserCreationKeepsFallbackBrowserSurfaceRouteVisibleWhenSurfaceListLags() async throws {
        let rpc = BrowserCreationRPCRecorder()
        let store = WorkspaceStore(rpc: rpc)
        await store.refresh()
        await rpc.setSurfaceListLaggingBrowser()

        let fallback = try await store.createBrowserSurface(workspaceId: "workspace-1", initialURL: nil)
        let routeVisibleSurface = store.surfaces(for: "workspace-1").first { $0.id == fallback.id }

        XCTAssertEqual(fallback.id, "browser-surface-1")
        XCTAssertEqual(fallback.kind, .browser)
        XCTAssertEqual(routeVisibleSurface?.kind, .browser)
        XCTAssertEqual(routeVisibleSurface?.title, "browser")
    }
}

private actor BrowserCreationRPCRecorder: RPCDispatch {
    private(set) var calls: [(method: String, params: JSONValue)] = []
    private var surfaces: [Surface] = [
        Surface(id: "terminal-surface-1", title: "shell", index: 0, kind: .terminal)
    ]
    private var nextBrowserIndex = 1
    private var lagBrowserSurfaceList = false

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append((method, params))
        switch method {
        case "workspace.list":
            return RPCResponse(id: "browser-creation", result: .object([
                "workspaces": .array([
                    .object([
                        "id": .string("workspace-1"),
                        "title": .string("Demo"),
                        "index": .int(0),
                    ]),
                ]),
            ]))
        case "surface.list":
            let listed = lagBrowserSurfaceList
                ? surfaces.filter { $0.kind != .browser }
                : surfaces
            return RPCResponse(id: "browser-creation", result: .object([
                "surfaces": .array(listed.map(Self.surfaceValue)),
            ]))
        case "surface.create":
            let surface = Surface(
                id: "terminal-surface-\(surfaces.count + 1)",
                title: "shell \(surfaces.count + 1)",
                index: surfaces.count,
                kind: .terminal
            )
            surfaces.append(surface)
            return RPCResponse(id: "browser-creation", result: .object([
                "surface_id": .string(surface.id),
            ]))
        case "browser.open_split":
            let surface = Surface(
                id: "browser-surface-\(nextBrowserIndex)",
                title: "browser",
                index: surfaces.count,
                kind: .browser
            )
            nextBrowserIndex += 1
            surfaces.append(surface)
            return RPCResponse(id: "browser-creation", result: .object([
                "surface_id": .string(surface.id),
            ]))
        default:
            return RPCResponse(id: "browser-creation", ok: true, result: .object([:]))
        }
    }

    func setSurfaceListLaggingBrowser() {
        lagBrowserSurfaceList = true
    }

    private static func surfaceValue(_ surface: Surface) -> JSONValue {
        .object([
            "id": .string(surface.id),
            "title": .string(surface.title),
            "index": .int(Int64(surface.index)),
            "kind": .string(surface.kind.rawValue),
        ])
    }
}
