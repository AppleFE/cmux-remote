import Foundation
import Observation
import SharedKit
import UIKit

@MainActor
@Observable
public final class BrowserRemoteStore {
    public var selectedWorkspaceId: String?
    public var selectedSurfaceId: String?
    public var url: String?
    public var title: String?
    public var isLoading = false
    public var isRefreshingState = false
    public var isRefreshingScreenshot = false
    public var isNavigating = false
    public var errorMessage: String?
    public var screenshotImageData: Data?
    public var screenshotImage: UIImage?
    public var lastRefreshTime: Date?

    private let rpc: any RPCDispatch

    public init(rpc: any RPCDispatch) {
        self.rpc = rpc
    }

    public func selectBrowserSurface(workspaceId: String, surfaceId: String) async {
        selectedWorkspaceId = workspaceId
        selectedSurfaceId = surfaceId
        clearBrowserState()
        await refreshState()
        await refreshScreenshot()
    }

    public func refreshState() async {
        guard let selection else { return }
        isLoading = true
        isRefreshingState = true
        defer {
            isRefreshingState = false
            isLoading = isRefreshingScreenshot || isNavigating
        }

        do {
            let response = try await rpc.call(
                method: "browser.url.get",
                params: selection.params
            )
            let payload = try response.unwrapResult().decode(BrowserStatePayload.self)
            url = payload.url
            title = payload.title
            errorMessage = nil
        } catch {
            errorMessage = browserErrorMessage(error)
        }
    }

    public func refreshScreenshot() async {
        guard let selection else { return }
        isLoading = true
        isRefreshingScreenshot = true
        screenshotImageData = nil
        screenshotImage = nil
        defer {
            isRefreshingScreenshot = false
            isLoading = isRefreshingState || isNavigating
        }

        do {
            let response = try await rpc.call(
                method: "browser.screenshot.read",
                params: selection.params
            )
            let payload = try BrowserScreenshotPayload.decodeRPCResult(try response.unwrapResult())
            url = payload.url ?? url
            title = payload.title ?? title
            guard let decodedImage = UIImage(data: payload.imageData) else {
                screenshotImageData = nil
                screenshotImage = nil
                errorMessage = "Browser screenshot response was invalid."
                return
            }
            screenshotImageData = payload.imageData
            screenshotImage = decodedImage
            lastRefreshTime = Date()
            errorMessage = nil
        } catch {
            errorMessage = browserErrorMessage(error)
        }
    }

    public func navigate(to destination: String) async {
        await performBrowserAction(
            method: "browser.navigate",
            params: actionParams(["url": .string(destination)])
        )
    }

    public func back() async {
        await performBrowserAction(method: "browser.back", params: actionParams())
    }

    public func forward() async {
        await performBrowserAction(method: "browser.forward", params: actionParams())
    }

    public func reload() async {
        await performBrowserAction(method: "browser.reload", params: actionParams())
    }

    public func reset() {
        selectedWorkspaceId = nil
        selectedSurfaceId = nil
        clearBrowserState()
    }

    private var selection: BrowserSurfaceSelection? {
        guard let selectedWorkspaceId, let selectedSurfaceId else { return nil }
        return BrowserSurfaceSelection(workspaceId: selectedWorkspaceId, surfaceId: selectedSurfaceId)
    }

    private func performBrowserAction(method: String, params: JSONValue) async {
        isLoading = true
        isNavigating = true
        defer {
            isNavigating = false
            isLoading = isRefreshingState || isRefreshingScreenshot
        }

        do {
            _ = try await rpc.call(method: method, params: params).requireOk()
            errorMessage = nil
            await refreshState()
            await refreshScreenshot()
        } catch {
            errorMessage = browserErrorMessage(error)
        }
    }

    private func actionParams(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        guard let selection else { return .object(extra) }
        var params = selection.rawParams
        for (key, value) in extra {
            params[key] = value
        }
        return .object(params)
    }

    private func clearBrowserState() {
        url = nil
        title = nil
        isLoading = false
        isRefreshingState = false
        isRefreshingScreenshot = false
        isNavigating = false
        errorMessage = nil
        screenshotImageData = nil
        screenshotImage = nil
        lastRefreshTime = nil
    }

    private func browserErrorMessage(_ error: Error) -> String {
        switch BrowserScreenshotPayloadError.map(error) {
        case .invalidBase64, .missingImageBytes, .oversizedImageBytes, .unsupportedResponse:
            return "Browser screenshot response was invalid."
        case .timeout:
            return "Browser request timed out."
        case .upstreamError:
            return "Browser request failed."
        }
    }
}

private struct BrowserSurfaceSelection {
    let workspaceId: String
    let surfaceId: String

    var rawParams: [String: JSONValue] {
        [
            "workspace_id": .string(workspaceId),
            "surface_id": .string(surfaceId),
        ]
    }

    var params: JSONValue {
        .object(rawParams)
    }
}
