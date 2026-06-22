import Foundation
import SharedKit

struct BrowserStatePayload: Decodable, Equatable {
    let surfaceId: String
    let workspaceId: String?
    let url: String?
    let title: String?
    let capturedAt: String?
}

struct BrowserScreenshotPayload: Decodable, Equatable {
    static let maxDecodedBytes = 6 * 1024 * 1024

    let surfaceId: String
    let workspaceId: String?
    let url: String?
    let title: String?
    let mimeType: String
    let imageData: Data
    let width: Int?
    let height: Int?
    let capturedAt: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceId = try container.decode(String.self, forKey: .surfaceId)
        workspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        capturedAt = try container.decodeIfPresent(String.self, forKey: .capturedAt) ?? ISO8601DateFormatter().string(from: Date())

        guard let encodedImage = try container.decodeIfPresent(String.self, forKey: .dataBase64),
              !encodedImage.isEmpty
        else {
            throw BrowserScreenshotPayloadError.missingImageBytes
        }
        guard let decodedImage = Data(base64Encoded: encodedImage) else {
            throw BrowserScreenshotPayloadError.invalidBase64
        }
        guard !decodedImage.isEmpty else {
            throw BrowserScreenshotPayloadError.missingImageBytes
        }
        guard decodedImage.count <= Self.maxDecodedBytes else {
            throw BrowserScreenshotPayloadError.oversizedImageBytes(maxBytes: Self.maxDecodedBytes)
        }
        imageData = decodedImage
    }

    static func decodeRPCResult(_ result: JSONValue) throws -> BrowserScreenshotPayload {
        guard case .object = result else {
            throw BrowserScreenshotPayloadError.unsupportedResponse
        }
        do {
            return try result.decode(Self.self)
        } catch let error as BrowserScreenshotPayloadError {
            throw error
        } catch {
            throw BrowserScreenshotPayloadError.unsupportedResponse
        }
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceId
        case workspaceId
        case url
        case title
        case mimeType
        case dataBase64
        case width
        case height
        case capturedAt
    }
}

enum BrowserScreenshotPayloadError: Error, Equatable {
    case invalidBase64
    case missingImageBytes
    case oversizedImageBytes(maxBytes: Int)
    case timeout
    case unsupportedResponse
    case upstreamError(code: String, message: String)

    static func map(_ error: Error) -> BrowserScreenshotPayloadError {
        switch error {
        case RPCClientError.timeout:
            return .timeout
        case let error as CmuxRemoteRPCError:
            switch error {
            case .rpc(let code, let message):
                return .upstreamError(code: code, message: message)
            case .missingResult:
                return .unsupportedResponse
            }
        case let error as BrowserScreenshotPayloadError:
            return error
        default:
            return .unsupportedResponse
        }
    }
}
