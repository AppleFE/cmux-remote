import XCTest
import SharedKit
@testable import RelayServer
@testable import RelayCore

final class WebSocketHandlerTests: XCTestCase {

    // MARK: - Hello flow

    func testHelloMissedReturnsClose() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [.close])
    }

    func testValidHelloEmitsAttach() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let json = #"{"deviceId":"d-7","appVersion":"1.0.0","protocolVersion":1}"#
        let actions = await m.processText(json)
        XCTAssertEqual(actions, [.attachSession(deviceId: "d-7")])
    }

    func testInvalidFirstFrameClosesBeforeHello() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [.close])
    }

    func testFirstFrameWrongShapeClosesBeforeHello() async {
        // Looks like JSON but isn't a HelloFrame.
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)
        XCTAssertEqual(actions, [.close])
    }

    func testHelloMissedAfterHelloIsNoop() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.helloMissed()
        XCTAssertEqual(actions, [])
    }

    // MARK: - RPC dispatch

    func testRPCDispatchesToFacade() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"1","method":"workspace.list","params":{}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls.map(\.method), ["workspace.list"])
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""id":"1""#), "missing id: \(s)")
        XCTAssertTrue(s.contains(#""ok":true"#), "missing ok=true: \(s)")
    }

    func testRPCErrorYieldsErrorResponse() async {
        let cmux = ThrowingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"7","method":"surface.send_text","params":{}}"#)
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let s) = actions[0] else {
            return XCTFail("expected sendText, got \(actions[0])")
        }
        XCTAssertTrue(s.contains(#""ok":false"#), "missing ok=false: \(s)")
        XCTAssertTrue(s.contains(#""code":"internal_error""#), "missing code: \(s)")
    }

    func testGarbageAfterHelloIsIgnored() async {
        let m = WSProtocolMachine(cmux: NoOpCMUXFacade())
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)
        let actions = await m.processText("not json")
        XCTAssertEqual(actions, [])
    }

    func testSurfaceSubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"9","method":"surface.subscribe","params":{"workspace_id":"w","surface_id":"s","fps":15}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.subscribe(responseId: "9", workspaceId: "w", surfaceId: "s", lines: 200)])
    }

    func testSurfaceSubscribeUsesRequestedLineCount() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"9","method":"surface.subscribe","params":{"workspace_id":"w","surface_id":"s","fps":15,"lines":120}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.subscribe(responseId: "9", workspaceId: "w", surfaceId: "s", lines: 120)])
    }

    func testSurfaceUnsubscribeBecomesRelayActionWithoutCmuxDispatch() async {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"10","method":"surface.unsubscribe","params":{"surface_id":"s"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(actions, [.unsubscribe(responseId: "10", surfaceId: "s")])
    }

    func testBrowserScreenshotReadIsRelayOwnedAndReturnsImageBytes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let imageURL = try Self.writeScreenshotFixture(named: "relay-owned.png", data: png)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let cmux = ScriptedCMUXFacade(result: .object([
            "path": .string(imageURL.path),
            "mime_type": .string("image/png"),
            "width": .int(4),
            "height": .int(3),
            "captured_at": .string("2026-06-21T00:00:00Z"),
            "url": .string("https://example.test/browser"),
            "title": .string("Browser"),
        ]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-1","method":"browser.screenshot.read","params":{"workspace_id":"w","surface_id":"s"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls.map(\.method), ["browser.screenshot"])
        XCTAssertEqual(calls.map(\.params), [.object(["workspace_id": .string("w"), "surface_id": .string("s")])])
        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.id, "shot-1")
        XCTAssertEqual(response.ok, true)
        guard case .object(let result)? = response.result else {
            return XCTFail("expected object result")
        }
        XCTAssertEqual(result["surface_id"], .string("s"))
        XCTAssertEqual(result["workspace_id"], .string("w"))
        XCTAssertEqual(result["mime_type"], .string("image/png"))
        XCTAssertEqual(result["data_base64"], .string(png.base64EncodedString()))
        XCTAssertEqual(result["width"], .int(4))
        XCTAssertEqual(result["height"], .int(3))
        XCTAssertEqual(result["captured_at"], .string("2026-06-21T00:00:00Z"))
        XCTAssertEqual(result["url"], .string("https://example.test/browser"))
        XCTAssertEqual(result["title"], .string("Browser"))
    }

    func testBrowserScreenshotReadNormalizesCmuxEnvelopePayload() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let cmux = ScriptedCMUXFacade(result: .object([
            "id": .string("upstream-shot"),
            "result": .object([
                "png_base64": .string(png.base64EncodedString()),
                "mime_type": .string("image/png"),
                "workspace_id": .string("upstream-workspace"),
                "surface_id": .string("upstream-surface"),
                "width": .int(1600),
                "height": .int(1200),
                "captured_at": .string("2026-06-22T07:00:00Z"),
                "url": .string("https://example.test/cmux"),
                "title": .string("cmux browser"),
            ]),
        ]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-envelope","method":"browser.screenshot.read","params":{"workspace_id":"w","surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, true)
        guard case .object(let result)? = response.result else {
            return XCTFail("expected object result")
        }
        XCTAssertEqual(result["surface_id"], .string("upstream-surface"))
        XCTAssertEqual(result["workspace_id"], .string("upstream-workspace"))
        XCTAssertEqual(result["mime_type"], .string("image/png"))
        XCTAssertEqual(result["data_base64"], .string(png.base64EncodedString()))
        XCTAssertEqual(result["width"], .int(1600))
        XCTAssertEqual(result["height"], .int(1200))
        XCTAssertEqual(result["captured_at"], .string("2026-06-22T07:00:00Z"))
        XCTAssertEqual(result["url"], .string("https://example.test/cmux"))
        XCTAssertEqual(result["title"], .string("cmux browser"))
    }

    func testBrowserScreenshotReadRejectsNonImageBytes() async throws {
        let text = Data("not an image".utf8)
        let cmux = ScriptedCMUXFacade(result: .object([
            "png_base64": .string(text.base64EncodedString()),
            "mime_type": .string("image/png"),
        ]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-non-image","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "unsupported_response")
    }

    func testBrowserScreenshotReadRejectsInvalidParams() async throws {
        let cmux = RecordingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-invalid","method":"browser.screenshot.read","params":{"workspace_id":"w"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls, [])
        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "invalid_params")
    }

    func testBrowserScreenshotReadSuppliesCapturedAtWhenUpstreamOmitsIt() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imageURL = try Self.writeScreenshotFixture(named: "relay-owned-no-captured-at.png", data: png)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let cmux = ScriptedCMUXFacade(result: .object([
            "path": .string(imageURL.path),
            "mime_type": .string("image/png"),
        ]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-fallback-date","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, true)
        guard case .object(let result)? = response.result,
              case .string(let capturedAt)? = result["captured_at"]
        else {
            return XCTFail("expected captured_at fallback")
        }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: capturedAt))
    }

    func testBrowserScreenshotReadRejectsUnsupportedUpstreamResponse() async throws {
        let cmux = ScriptedCMUXFacade(result: .object(["ok": .bool(true)]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-unsupported","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let calls = await cmux.snapshot()
        XCTAssertEqual(calls.map(\.method), ["browser.screenshot"])
        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "unsupported_response")
    }

    func testBrowserScreenshotReadRejectsInvalidBase64() async throws {
        let cmux = ScriptedCMUXFacade(result: .object(["png_base64": .string("not-base64")]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-bad-base64","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "invalid_base64")
    }

    func testBrowserScreenshotReadRejectsReadFailure() async throws {
        let missingURL = Self.screenshotFixtureDirectory()
            .appendingPathComponent("missing-\(UUID().uuidString).png", isDirectory: false)
        let cmux = ScriptedCMUXFacade(result: .object(["path": .string(missingURL.path)]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-missing","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "read_failed")
    }

    func testBrowserScreenshotReadRejectsOutsideScreenshotDirectory() async throws {
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-iphone-outside-\(UUID().uuidString).png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let cmux = ScriptedCMUXFacade(result: .object(["path": .string(outsideURL.path)]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-outside","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "unsupported_response")
    }

    func testBrowserScreenshotReadRejectsOversizedImage() async throws {
        let oversized = Data(repeating: 0x41, count: 6 * 1024 * 1024 + 1)
        let cmux = ScriptedCMUXFacade(result: .object([
            "png_base64": .string(oversized.base64EncodedString()),
        ]))
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-big","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "image_too_large")
    }

    func testBrowserScreenshotReadReturnsUpstreamError() async throws {
        let cmux = ThrowingCMUXFacade()
        let m = WSProtocolMachine(cmux: cmux)
        _ = await m.processText(#"{"deviceId":"d","appVersion":"1","protocolVersion":1}"#)

        let actions = await m.processText(#"{"id":"shot-upstream","method":"browser.screenshot.read","params":{"surface_id":"s"}}"#)

        let response = try Self.decodeSingleResponse(actions)
        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "upstream_error")
    }

    private static func decodeSingleResponse(_ actions: [WSProtocolMachine.Action]) throws -> RPCResponse {
        XCTAssertEqual(actions.count, 1)
        guard case .sendText(let text) = actions.first else {
            XCTFail("expected sendText, got \(String(describing: actions.first))")
            throw TestFailure()
        }
        return try JSONDecoder().decode(RPCResponse.self, from: Data(text.utf8))
    }

    private static func screenshotFixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)
            .appendingPathComponent("cmux-iphone-tests", isDirectory: true)
    }

    private static func writeScreenshotFixture(named name: String, data: Data) throws -> URL {
        let directory = screenshotFixtureDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)", isDirectory: false)
        try data.write(to: url)
        return url
    }
}

// MARK: - Test doubles

private struct TestFailure: Error {}

final class NoOpCMUXFacade: CMUXFacade {
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        .object([:])
    }
}

actor RecordingCMUXFacade: CMUXFacade {
    struct Call: Equatable, Sendable {
        let method: String
        let params: JSONValue
    }
    private var calls: [Call] = []
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(.init(method: method, params: params))
        return .object([:])
    }
    func snapshot() -> [Call] { calls }
}

actor ScriptedCMUXFacade: CMUXFacade {
    private let result: JSONValue
    private var calls: [RecordingCMUXFacade.Call] = []

    init(result: JSONValue) {
        self.result = result
    }

    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(.init(method: method, params: params))
        return result
    }

    func snapshot() -> [RecordingCMUXFacade.Call] { calls }
}

final class ThrowingCMUXFacade: CMUXFacade {
    struct Boom: Error {}
    func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        throw Boom()
    }
}
