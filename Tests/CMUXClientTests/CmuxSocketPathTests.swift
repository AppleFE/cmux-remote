import XCTest
@testable import CMUXClient

final class CmuxSocketPathTests: XCTestCase {
    func testEnvOverrideWins() {
        let p = cmuxSocketPath(["CMUX_SOCKET_PATH": "/tmp/explicit.sock"])
        XCTAssertEqual(p, "/tmp/explicit.sock")
    }
    func testLegacyAliasFallback() {
        let p = cmuxSocketPath(["CMUX_SOCKET": "/tmp/legacy.sock"])
        XCTAssertEqual(p, "/tmp/legacy.sock")
    }
    func testDefaultsToAppSupport() {
        let p = cmuxSocketPath(["HOME": "/Users/x"])
        XCTAssertTrue(p.hasSuffix("Library/Application Support/cmux/cmux.sock"), p)
    }

    func testFollowsCmuxLastSocketPathWhenPresent() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cmuxDir = temp.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        let liveSocket = cmuxDir.appendingPathComponent("cmux-501.sock", isDirectory: false)
        _ = FileManager.default.createFile(atPath: liveSocket.path, contents: Data())
        try "\(liveSocket.path)\n".write(
            to: cmuxDir.appendingPathComponent("last-socket-path", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let p = cmuxSocketPath([:], appSupportDirectory: temp)

        XCTAssertEqual(p, liveSocket.path)
    }

    func testFallsBackWhenLastSocketPathIsStale() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cmuxDir = temp.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        try "/tmp/no-such-cmux.sock\n".write(
            to: cmuxDir.appendingPathComponent("last-socket-path", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let p = cmuxSocketPath([:], appSupportDirectory: temp)

        XCTAssertEqual(p, cmuxDir.appendingPathComponent("cmux.sock").path)
    }

    func testEnvOverrideWinsOverLastSocketPath() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let cmuxDir = temp.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        let liveSocket = cmuxDir.appendingPathComponent("cmux-501.sock", isDirectory: false)
        _ = FileManager.default.createFile(atPath: liveSocket.path, contents: Data())
        try "\(liveSocket.path)\n".write(
            to: cmuxDir.appendingPathComponent("last-socket-path", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let p = cmuxSocketPath(["CMUX_SOCKET_PATH": "/tmp/explicit.sock"], appSupportDirectory: temp)

        XCTAssertEqual(p, "/tmp/explicit.sock")
    }

    func testSocketPasswordEnvWins() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "file-secret\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword(["CMUX_SOCKET_PASSWORD": " env-secret\n"], appSupportDirectory: temp)

        XCTAssertEqual(password, "env-secret")
    }

    func testSocketPasswordFallsBackToCmuxPasswordFile() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "file-secret\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword([:], appSupportDirectory: temp)

        XCTAssertEqual(password, "file-secret")
    }

    func testSocketPasswordIgnoresMissingOrBlankValues() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("cmux", isDirectory: true), withIntermediateDirectories: true)
        try "\n".write(to: temp.appendingPathComponent("cmux/socket-control-password"), atomically: true, encoding: .utf8)

        let password = cmuxSocketPassword(["CMUX_SOCKET_PASSWORD": "   "], appSupportDirectory: temp)

        XCTAssertNil(password)
    }

}
