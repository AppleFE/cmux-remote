import Foundation
import XCTest
import SharedKit
import UIKit
@testable import CmuxRemote

final class DemoBrowserFixtureTests: XCTestCase {
    func testDemoSurfaceListIncludesBrowserKind() async throws {
        let rpc = DemoRPCDispatch()

        let payload = try await surfaceList(from: rpc)
        let browser = payload.surfaces.map(\.model).first { $0.title == "browser" }

        XCTAssertEqual(browser?.kind, .browser)
    }

    func testDemoBrowserSurfaceReturnsDeterministicScreenshot() async throws {
        let rpc = DemoRPCDispatch()
        let browser = try await demoBrowserSurface(from: rpc)

        let response = try await rpc.call(
            method: "browser.screenshot.read",
            params: .object([
                "workspace_id": .string("WS-DEMO-1"),
                "surface_id": .string(browser.id),
            ])
        )
        let screenshot = try BrowserScreenshotPayload.decodeRPCResult(response.unwrapResult())

        XCTAssertEqual(screenshot.surfaceId, browser.id)
        XCTAssertEqual(screenshot.workspaceId, "WS-DEMO-1")
        XCTAssertEqual(screenshot.url, "https://example.test/cmux-browser")
        XCTAssertEqual(screenshot.title, "browser")
        XCTAssertEqual(screenshot.mimeType, "image/png")
        XCTAssertEqual(Array(screenshot.imageData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertNotNil(UIImage(data: screenshot.imageData))
    }

    func testDemoBrowserNavigateMutatesURLState() async throws {
        let rpc = DemoRPCDispatch()
        let browser = try await demoBrowserSurface(from: rpc)
        let nextURL = "https://example.test/cmux-browser/after-nav"

        _ = try await rpc.call(
            method: "browser.navigate",
            params: .object([
                "workspace_id": .string("WS-DEMO-1"),
                "surface_id": .string(browser.id),
                "url": .string(nextURL),
            ])
        ).requireOk()
        let state = try await browserState(from: rpc, surfaceId: browser.id)

        XCTAssertEqual(state.url, nextURL)
    }

    func testDemoBrowserSurfaceDoesNotReturnTerminalScreenText() async throws {
        let rpc = DemoRPCDispatch()
        let browser = try await demoBrowserSurface(from: rpc)

        let result = try await rpc.call(
            method: "surface.read_text",
            params: .object(["surface_id": .string(browser.id)])
        ).unwrapResult()
        let text = try result.decode(ReadTextPayload.self).text

        XCTAssertEqual(text, "")
        XCTAssertFalse(text.contains("$ claude code"))
    }

    private func demoBrowserSurface(from rpc: DemoRPCDispatch) async throws -> Surface {
        let payload = try await surfaceList(from: rpc)
        guard let browser = payload.surfaces.map(\.model).first(where: { $0.title == "browser" }) else {
            throw DemoBrowserFixtureTestError.missingBrowserSurface
        }
        return browser
    }

    private func surfaceList(from rpc: DemoRPCDispatch) async throws -> SurfaceListPayload {
        let response = try await rpc.call(
            method: "surface.list",
            params: .object(["workspace_id": .string("WS-DEMO-1")])
        )
        return try response.unwrapResult().decode(SurfaceListPayload.self)
    }

    private func browserState(from rpc: DemoRPCDispatch, surfaceId: String) async throws -> BrowserStatePayload {
        let response = try await rpc.call(
            method: "browser.url.get",
            params: .object([
                "workspace_id": .string("WS-DEMO-1"),
                "surface_id": .string(surfaceId),
            ])
        )
        return try response.unwrapResult().decode(BrowserStatePayload.self)
    }
}

private enum DemoBrowserFixtureTestError: Error {
    case missingBrowserSurface
}
