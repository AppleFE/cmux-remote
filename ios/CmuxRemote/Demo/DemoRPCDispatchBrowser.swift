import Foundation
import SharedKit

extension DemoRPCDispatch {
    func browserState(params: JSONValue) -> RPCResponse {
        guard let match = browserSurface(params: params), let fixture = match.surface.browserFixture else {
            return missingBrowserResponse()
        }
        return RPCResponse(id: "demo", result: statePayload(
            workspaceId: workspaces[match.workspaceIndex].id,
            surface: match.surface,
            fixture: fixture
        ))
    }

    func browserNavigate(params: JSONValue) -> RPCResponse {
        guard case .object(let values) = params,
              case .string(let nextURL)? = values["url"],
              let match = browserSurface(params: params),
              let fixture = match.surface.browserFixture
        else {
            return missingBrowserResponse()
        }

        let updated = DemoSurface(
            id: match.surface.id,
            title: match.surface.title,
            screen: [],
            kind: .browser,
            browserFixture: fixture.withURL(nextURL)
        )
        var surfaces = workspaces[match.workspaceIndex].surfaces
        surfaces[match.surfaceIndex] = updated
        let workspace = workspaces[match.workspaceIndex]
        workspaces[match.workspaceIndex] = DemoWorkspace(id: workspace.id, title: workspace.title, surfaces: surfaces)
        return RPCResponse(id: "demo", ok: true, result: .object([:]))
    }

    func browserScreenshot(params: JSONValue) -> RPCResponse {
        guard let match = browserSurface(params: params), let fixture = match.surface.browserFixture else {
            return missingBrowserResponse()
        }
        var payload = stateObject(
            workspaceId: workspaces[match.workspaceIndex].id,
            surface: match.surface,
            fixture: fixture
        )
        payload["mime_type"] = .string("image/png")
        payload["data_base64"] = .string(fixture.dataBase64)
        payload["width"] = .int(Int64(fixture.width))
        payload["height"] = .int(Int64(fixture.height))
        return RPCResponse(id: "demo", result: .object(payload))
    }

    private func browserSurface(params: JSONValue) -> (workspaceIndex: Int, surfaceIndex: Int, surface: DemoSurface)? {
        guard case .object(let values) = params,
              case .string(let surfaceId)? = values["surface_id"]
        else { return nil }

        let requestedWorkspaceId: String?
        if case .string(let workspaceId)? = values["workspace_id"] {
            requestedWorkspaceId = workspaceId
        } else {
            requestedWorkspaceId = nil
        }

        for (workspaceIndex, workspace) in workspaces.enumerated()
        where requestedWorkspaceId == nil || workspace.id == requestedWorkspaceId {
            if let surfaceIndex = workspace.surfaces.firstIndex(where: { $0.id == surfaceId }) {
                let surface = workspace.surfaces[surfaceIndex]
                guard surface.kind == .browser, surface.browserFixture != nil else { return nil }
                return (workspaceIndex, surfaceIndex, surface)
            }
        }
        return nil
    }

    private func statePayload(workspaceId: String, surface: DemoSurface, fixture: DemoBrowserFixture) -> JSONValue {
        .object(stateObject(workspaceId: workspaceId, surface: surface, fixture: fixture))
    }

    private func stateObject(
        workspaceId: String,
        surface: DemoSurface,
        fixture: DemoBrowserFixture
    ) -> [String: JSONValue] {
        [
            "surface_id": .string(surface.id),
            "workspace_id": .string(workspaceId),
            "url": .string(fixture.url),
            "title": .string(surface.title),
            "captured_at": .string(fixture.capturedAt),
        ]
    }

    private func missingBrowserResponse() -> RPCResponse {
        RPCResponse(
            id: "demo",
            ok: false,
            error: RPCError(code: "not_found", message: "Demo browser surface was not found.")
        )
    }
}
