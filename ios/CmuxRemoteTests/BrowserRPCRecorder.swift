import Foundation
import SharedKit
@testable import CmuxRemote

struct BrowserRPCCall: Sendable {
    let method: String
    let params: JSONValue
}

actor BrowserRPCRecorder: RPCDispatch {
    private(set) var calls: [BrowserRPCCall] = []
    private var stateResult: JSONValue = .object([
        "surface_id": .string("surface-browser"),
        "workspace_id": .string("workspace-1"),
        "url": .string("https://example.test/cmux-browser"),
        "title": .string("browser"),
        "captured_at": .string("2026-06-21T00:00:00Z"),
    ])
    private var screenshotResult: JSONValue = BrowserRemoteStoreTests.screenshotValue(
        dataBase64: BrowserRemoteStoreTests.validPNGData.base64EncodedString()
    )
    private var failures: [String: RPCError] = [:]

    func call(method: String, params: JSONValue) async throws -> RPCResponse {
        calls.append(BrowserRPCCall(method: method, params: params))
        if let failure = failures[method] {
            return RPCResponse(id: method, ok: false, error: failure)
        }
        switch method {
        case "browser.url.get":
            return RPCResponse(id: method, result: stateResult)
        case "browser.screenshot.read":
            return RPCResponse(id: method, result: screenshotResult)
        case "browser.navigate", "browser.back", "browser.forward", "browser.reload":
            return RPCResponse(id: method, result: .object(["ok": .bool(true)]))
        default:
            return RPCResponse(
                id: method,
                ok: false,
                error: RPCError(code: "unexpected_method", message: method)
            )
        }
    }

    func clearCalls() {
        calls.removeAll()
    }

    func setState(url: String, title: String) {
        stateResult = .object([
            "surface_id": .string("surface-browser"),
            "workspace_id": .string("workspace-1"),
            "url": .string(url),
            "title": .string(title),
            "captured_at": .string("2026-06-21T00:00:01Z"),
        ])
    }

    func setScreenshotResult(_ result: JSONValue) {
        screenshotResult = result
    }

    func setFailure(method: String, code: String, message: String) {
        failures[method] = RPCError(code: code, message: message)
    }
}
