import Foundation
import XCTest
import SharedKit
@testable import CmuxRemote

final class BrowserRemoteStoreTests: XCTestCase {
    func testScreenshotPayloadDecodesValidImage() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let payload = try screenshotValue(dataBase64: bytes.base64EncodedString()).decode(BrowserScreenshotPayload.self)

        XCTAssertEqual(payload.surfaceId, "surface-browser")
        XCTAssertEqual(payload.workspaceId, "workspace-1")
        XCTAssertEqual(payload.url, "https://example.test/cmux-browser")
        XCTAssertEqual(payload.title, "browser")
        XCTAssertEqual(payload.mimeType, "image/png")
        XCTAssertEqual(payload.imageData, bytes)
        XCTAssertEqual(payload.width, 640)
        XCTAssertEqual(payload.height, 360)
        XCTAssertEqual(payload.capturedAt, "2026-06-21T00:00:00Z")
    }

    func testScreenshotPayloadDecodesWhenCapturedAtIsMissing() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        var value = Self.screenshotValue(dataBase64: bytes.base64EncodedString())
        guard case .object(var object) = value else {
            return XCTFail("expected object fixture")
        }
        object.removeValue(forKey: "captured_at")
        value = .object(object)

        let payload = try value.decode(BrowserScreenshotPayload.self)

        XCTAssertEqual(payload.imageData, bytes)
        XCTAssertFalse(payload.capturedAt.isEmpty)
    }

    func testScreenshotPayloadRejectsInvalidBase64() throws {
        XCTAssertThrowsError(try screenshotValue(dataBase64: "not base64").decode(BrowserScreenshotPayload.self)) { error in
            XCTAssertEqual(error as? BrowserScreenshotPayloadError, .invalidBase64)
        }
    }

    func testScreenshotPayloadRejectsMissingImageBytes() throws {
        XCTAssertThrowsError(try screenshotValue(dataBase64: "").decode(BrowserScreenshotPayload.self)) { error in
            XCTAssertEqual(error as? BrowserScreenshotPayloadError, .missingImageBytes)
        }
    }

    func testScreenshotPayloadRejectsOversizedImageBytes() throws {
        let oversizedBytes = Data(repeating: 0x41, count: BrowserScreenshotPayload.maxDecodedBytes + 1)

        XCTAssertThrowsError(try screenshotValue(dataBase64: oversizedBytes.base64EncodedString()).decode(BrowserScreenshotPayload.self)) { error in
            XCTAssertEqual(error as? BrowserScreenshotPayloadError, .oversizedImageBytes(maxBytes: BrowserScreenshotPayload.maxDecodedBytes))
        }
    }

    func testScreenshotPayloadMapsTimeoutAndUpstreamError() {
        XCTAssertEqual(BrowserScreenshotPayloadError.map(RPCClientError.timeout), .timeout)
        XCTAssertEqual(
            BrowserScreenshotPayloadError.map(CmuxRemoteRPCError.rpc(code: "unsupported", message: "browser screenshot unavailable")),
            .upstreamError(code: "unsupported", message: "browser screenshot unavailable")
        )
    }

    func testScreenshotPayloadRejectsUnsupportedResult() {
        XCTAssertThrowsError(try BrowserScreenshotPayload.decodeRPCResult(.string("unsupported"))) { error in
            XCTAssertEqual(error as? BrowserScreenshotPayloadError, .unsupportedResponse)
        }
    }

    func testBrowserStatePayloadDecodesOptionalFields() throws {
        let payload = try JSONValue.object([
            "surface_id": .string("surface-browser"),
            "workspace_id": .string("workspace-1"),
            "url": .string("https://example.test/cmux-browser"),
            "title": .string("browser"),
            "captured_at": .string("2026-06-21T00:00:00Z"),
        ]).decode(BrowserStatePayload.self)

        XCTAssertEqual(payload.surfaceId, "surface-browser")
        XCTAssertEqual(payload.workspaceId, "workspace-1")
        XCTAssertEqual(payload.url, "https://example.test/cmux-browser")
        XCTAssertEqual(payload.title, "browser")
        XCTAssertEqual(payload.capturedAt, "2026-06-21T00:00:00Z")
    }

    @MainActor
    func testSelectingBrowserSurfaceDoesNotCallTerminalSubscribeOrReadText() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)

        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")

        XCTAssertEqual(store.selectedWorkspaceId, "workspace-1")
        XCTAssertEqual(store.selectedSurfaceId, "surface-browser")
        XCTAssertEqual(store.url, "https://example.test/cmux-browser")
        XCTAssertEqual(store.title, "browser")
        XCTAssertEqual(store.screenshotImageData, Self.validPNGData)
        XCTAssertNotNil(store.screenshotImage)
        XCTAssertNotNil(store.lastRefreshTime)
        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["browser.url.get", "browser.screenshot.read"])
        XCTAssertNoTerminalBrowserCalls(calls)
    }

    @MainActor
    func testNavigateBackForwardAndReloadDispatchBrowserMethods() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        await rpc.clearCalls()

        await store.navigate(to: "https://example.test/next?token=redacted")
        await store.back()
        await store.forward()
        await store.reload()

        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "browser.navigate",
                  case .object(let params) = call.params,
                  case .string("workspace-1")? = params["workspace_id"],
                  case .string("surface-browser")? = params["surface_id"],
                  case .string("https://example.test/next?token=redacted")? = params["url"]
            else { return false }
            return true
        })
        XCTAssertTrue(calls.contains { $0.method == "browser.back" })
        XCTAssertTrue(calls.contains { $0.method == "browser.forward" })
        XCTAssertTrue(calls.contains { $0.method == "browser.reload" })
        XCTAssertNoTerminalBrowserCalls(calls)
    }

    @MainActor
    func testScreenshotDecodeFailureBecomesVisibleErrorAndClearsStaleImage() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        XCTAssertNotNil(store.screenshotImageData)

        await rpc.setScreenshotResult(Self.screenshotValue(dataBase64: "not base64"))
        await store.refreshScreenshot()

        XCTAssertNil(store.screenshotImageData)
        XCTAssertNil(store.screenshotImage)
        XCTAssertEqual(store.errorMessage, "Browser screenshot response was invalid.")
    }

    @MainActor
    func testScreenshotImageDecodeFailureBecomesVisibleErrorAndClearsStaleImage() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        XCTAssertNotNil(store.screenshotImageData)
        XCTAssertNotNil(store.screenshotImage)

        await rpc.setScreenshotResult(Self.screenshotValue(dataBase64: Data([0x01, 0x02, 0x03]).base64EncodedString()))
        await store.refreshScreenshot()

        XCTAssertNil(store.screenshotImageData)
        XCTAssertNil(store.screenshotImage)
        XCTAssertEqual(store.errorMessage, "Browser screenshot response was invalid.")
    }

    @MainActor
    func testUpstreamFailureBecomesVisibleErrorState() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")

        await rpc.setFailure(method: "browser.reload", code: "upstream", message: "navigation unavailable")
        await store.reload()

        XCTAssertEqual(store.errorMessage, "Browser request failed.")
        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { $0.method == "browser.reload" })
        XCTAssertNoTerminalBrowserCalls(calls)
    }

    @MainActor
    func testResetClearsImageErrorAndNewSelectionRefreshesPriorState() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        await rpc.setScreenshotResult(Self.screenshotValue(dataBase64: "not base64"))
        await store.refreshScreenshot()

        store.reset()

        XCTAssertNil(store.selectedWorkspaceId)
        XCTAssertNil(store.selectedSurfaceId)
        XCTAssertNil(store.url)
        XCTAssertNil(store.title)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.screenshotImageData)
        XCTAssertNil(store.screenshotImage)
        XCTAssertNil(store.lastRefreshTime)

        await rpc.setState(url: "https://example.test/other", title: "other")
        await rpc.setScreenshotResult(Self.screenshotValue(
            dataBase64: Self.validPNGData.base64EncodedString(),
            url: "https://example.test/other",
            title: "other"
        ))
        await store.selectBrowserSurface(workspaceId: "workspace-2", surfaceId: "surface-other")

        XCTAssertEqual(store.selectedWorkspaceId, "workspace-2")
        XCTAssertEqual(store.selectedSurfaceId, "surface-other")
        XCTAssertEqual(store.url, "https://example.test/other")
        XCTAssertEqual(store.title, "other")
        XCTAssertEqual(store.screenshotImageData, Self.validPNGData)
        XCTAssertNotNil(store.lastRefreshTime)
    }

    static let validPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADtGLyqAAAAEklEQVQIHWNk+M8ABEwggoEBAAweAQP5/4HBAAAAAElFTkSuQmCC")!

    static func screenshotValue(
        dataBase64: String,
        url: String = "https://example.test/cmux-browser",
        title: String = "browser"
    ) -> JSONValue {
        .object([
            "surface_id": .string("surface-browser"),
            "workspace_id": .string("workspace-1"),
            "url": .string(url),
            "title": .string(title),
            "mime_type": .string("image/png"),
            "data_base64": .string(dataBase64),
            "width": .int(640),
            "height": .int(360),
            "captured_at": .string("2026-06-21T00:00:00Z"),
        ])
    }

    private func screenshotValue(dataBase64: String) -> JSONValue {
        Self.screenshotValue(dataBase64: dataBase64)
    }

    private func XCTAssertNoTerminalBrowserCalls(
        _ calls: [BrowserRPCCall],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = Set(["surface.subscribe", "surface.read_text", "surface.send_text", "surface.send_key"])
        XCTAssertTrue(
            calls.allSatisfy { !forbidden.contains($0.method) },
            "Terminal RPC methods must not be called from BrowserRemoteStore: \(calls.map(\.method))",
            file: file,
            line: line
        )
    }
}
