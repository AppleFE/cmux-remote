import XCTest
@testable import RelayCore

final class ConfigLoaderTests: XCTestCase {
    func testParsesAllFields() throws {
        let json = #"""
        {
          "listen": "0.0.0.0:4399",
          "allow_login": ["alice@example.com"],
          "apns": { "key_path": "/k.p8", "key_id": "K", "team_id": "T",
                    "topic": "com.example", "env": "prod" },
          "snippets": [{ "label": "ll", "text": "ls -alh\n" }],
          "default_fps": 15,
          "idle_fps": 5
        }
        """#
        let cfg = try RelayConfig.decode(jsonString: json)
        XCTAssertEqual(cfg.listen, "0.0.0.0:4399")
        XCTAssertEqual(cfg.allowLogin, ["alice@example.com"])
        XCTAssertEqual(cfg.apns.keyId, "K")
        XCTAssertEqual(cfg.snippets.first?.label, "ll")
        XCTAssertEqual(cfg.defaultFps, 15)
    }

    /// Regression for #3. The installer (and the documented default) writes a
    /// minimal relay.json carrying only `listen`/`default_fps`/`idle_fps`. The
    /// relay must boot from it, filling the omitted optional fields with safe
    /// defaults, instead of crash-looping with `keyNotFound: allow_login`.
    func testParsesMinimalInstallerConfig() throws {
        let json = #"""
        {
          "listen":      "0.0.0.0:4399",
          "default_fps": 15,
          "idle_fps":    5
        }
        """#
        let cfg = try RelayConfig.decode(jsonString: json)
        XCTAssertEqual(cfg.listen, "0.0.0.0:4399")
        XCTAssertEqual(cfg.allowLogin, [])
        XCTAssertEqual(cfg.snippets, [])
        XCTAssertEqual(cfg.apns.env, "sandbox")
        XCTAssertEqual(cfg.apns.keyId, "")
        XCTAssertEqual(cfg.defaultFps, 15)
        XCTAssertEqual(cfg.idleFps, 5)
    }

    /// Any omitted key falls back to the baseline default, so even an empty
    /// document yields a usable config rather than throwing.
    func testEmptyObjectUsesDefaults() throws {
        let cfg = try RelayConfig.decode(jsonString: "{}")
        XCTAssertEqual(cfg, RelayConfig.defaults)
    }

    /// A present-but-malformed value (wrong type) still fails loudly — only
    /// *omitted* keys are defaulted, never bad ones.
    func testRejectsMalformedValue() {
        let json = #"{"allow_login": "not-an-array"}"#
        XCTAssertThrowsError(try RelayConfig.decode(jsonString: json))
    }

    func testReloadFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let raw = #"""
        {"listen":"0.0.0.0:4399","allow_login":["a"],
         "apns":{"key_path":"/k","key_id":"K","team_id":"T","topic":"x","env":"prod"},
         "snippets":[],"default_fps":15,"idle_fps":5}
        """#
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: url)
        try store.reload()
        XCTAssertEqual(store.current.allowLogin, ["a"])
    }
}
