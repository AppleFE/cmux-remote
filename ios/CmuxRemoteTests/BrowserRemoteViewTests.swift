import SwiftUI
import UIKit
import XCTest
import SharedKit
@testable import CmuxRemote

@MainActor
final class BrowserRemoteViewTests: XCTestCase {
    func testValidScreenshotRendersBrowserScreenshotImage() async {
        let rpc = BrowserRPCRecorder()
        await rpc.setScreenshotResult(BrowserRemoteStoreTests.screenshotValue(
            dataBase64: Self.validPNGData().base64EncodedString()
        ))
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        XCTAssertNotNil(store.screenshotImage)

        let renderer = ImageRenderer(content: BrowserScreenshotViewport(
            image: store.screenshotImage,
            isLoading: false
        ).frame(width: 80, height: 80))
        XCTAssertNotNil(renderer.uiImage)
    }

    func testInvalidScreenshotShowsBrowserErrorMessage() async {
        let rpc = BrowserRPCRecorder()
        await rpc.setScreenshotResult(BrowserRemoteStoreTests.screenshotValue(dataBase64: "not base64"))
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")

        XCTAssertEqual(store.errorMessage, "Browser screenshot response was invalid.")
        let renderer = ImageRenderer(content: BrowserErrorBanner(message: store.errorMessage ?? ""))
        XCTAssertNotNil(renderer.uiImage)
    }

    func testAddressSubmitDispatchesBrowserNavigate() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        await rpc.clearCalls()

        await store.navigate(to: "https://example.test/next")

        let calls = await rpc.calls
        XCTAssertTrue(calls.contains { call in
            guard call.method == "browser.navigate",
                  case .object(let params) = call.params,
                  case .string("https://example.test/next")? = params["url"]
            else { return false }
            return true
        })
    }

    func testRefreshScreenshotDispatchesBrowserScreenshotRead() async {
        let rpc = BrowserRPCRecorder()
        let store = BrowserRemoteStore(rpc: rpc)
        await store.selectBrowserSurface(workspaceId: "workspace-1", surfaceId: "surface-browser")
        await rpc.clearCalls()

        await store.refreshScreenshot()

        let calls = await rpc.calls
        XCTAssertEqual(calls.map(\.method), ["browser.screenshot.read"])
    }

    func testBrowserViewImplementationDoesNotUseLocalWebView() throws {
        let source = try browserRemoteViewSource()

        XCTAssertFalse(source.contains("WKWebView"))
        XCTAssertFalse(source.contains("SFSafariViewController"))
        XCTAssertNil(source.range(of: #"(?<![A-Za-z0-9_])WebView\s*\("#, options: .regularExpression))
    }

    func testBrowserViewDefinesRequiredAccessibilityIdentifiers() throws {
        let source = try browserRemoteViewSource()
        let identifiers = [
            "BrowserRemoteViewport",
            "BrowserScreenshotImage",
            "BrowserAddressField",
            "BrowserBackButton",
            "BrowserForwardButton",
            "BrowserReloadButton",
            "BrowserRefreshScreenshotButton",
            "BrowserErrorMessage",
        ]

        for identifier in identifiers {
            XCTAssertTrue(source.contains(#""\#(identifier)""#), identifier)
        }
        XCTAssertTrue(source.contains(".accessibilityIdentifier(identifier)"))
    }

    private func browserRemoteViewSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CmuxRemote/Browser/BrowserRemoteView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func validPNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}
