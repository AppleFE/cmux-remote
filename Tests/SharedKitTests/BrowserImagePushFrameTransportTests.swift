import XCTest
import Foundation
@testable import SharedKit

final class SharedKitTests: XCTestCase {
    func testBrowserImagePushFrameIsRejectedBecauseImageTransportIsRpcOnly() throws {
        let browserPushFrames = [
            (
                type: "browser.image",
                raw: """
                {"type":"browser.image","surface_id":"browser-1","rev":8,
                 "mime_type":"image/png","data_base64":"iVBORw0KGgo=","width":1,"height":1}
                """
            ),
            (
                type: "browser.screenshot",
                raw: """
                {"type":"browser.screenshot","surface_id":"browser-1","rev":9,
                 "mime_type":"image/png","data_base64":"iVBORw0KGgo="}
                """
            ),
            (
                type: "browser.screenshot.read",
                raw: """
                {"type":"browser.screenshot.read","surface_id":"browser-1","rev":10,
                 "format":"png","max_width":800}
                """
            ),
            (
                type: "browser.image",
                raw: """
                {"type":"browser.image","surface_id":42,"rev":"bad",
                 "data_base64":false}
                """
            ),
        ]

        for pushFrame in browserPushFrames {
            XCTAssertThrowsError(
                try JSONDecoder().decode(PushFrame.self, from: Data(pushFrame.raw.utf8)),
                "\(pushFrame.type) must remain RPC-only and must not decode as a PushFrame"
            ) { error in
                guard case DecodingError.dataCorrupted(let context) = error else {
                    XCTFail("Expected unknown PushFrame type rejection for \(pushFrame.type), got \(error)")
                    return
                }
                XCTAssertEqual(context.debugDescription, "Unknown push frame type: \(pushFrame.type)")
            }
        }

        let missingType = #"{"surface_id":"browser-1","rev":11}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PushFrame.self, from: Data(missingType.utf8)),
            "PushFrame decoding must reject frames without a type discriminator"
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected missing PushFrame type rejection, got \(error)")
                return
            }
            XCTAssertEqual(key.stringValue, "type")
        }

        let invalidType = #"{"type":42,"surface_id":"browser-1","rev":12}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PushFrame.self, from: Data(invalidType.utf8)),
            "PushFrame decoding must reject non-string type discriminators"
        ) { error in
            guard case DecodingError.typeMismatch(let type, _) = error else {
                XCTFail("Expected invalid PushFrame type rejection, got \(error)")
                return
            }
            XCTAssertEqual(String(describing: type), "String")
        }
    }
}
