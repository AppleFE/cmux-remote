import Foundation
import SharedKit

public struct BrowserScreenshotReadResult: Equatable, Sendable {
    public let json: JSONValue
}

public enum BrowserScreenshotReadError: Error, CustomStringConvertible, Equatable {
    case invalidParams
    case unsupportedResponse
    case invalidBase64
    case readFailed(String)
    case imageTooLarge(Int)
    case upstreamError(String)

    public var code: String {
        switch self {
        case .invalidParams: return "invalid_params"
        case .unsupportedResponse: return "unsupported_response"
        case .invalidBase64: return "invalid_base64"
        case .readFailed: return "read_failed"
        case .imageTooLarge: return "image_too_large"
        case .upstreamError: return "upstream_error"
        }
    }

    public var description: String {
        switch self {
        case .invalidParams:
            return "browser.screenshot.read requires surface_id"
        case .unsupportedResponse:
            return "browser.screenshot returned an unsupported response"
        case .invalidBase64:
            return "browser.screenshot returned invalid base64 image data"
        case .readFailed(let message):
            return "browser.screenshot file read failed: \(message)"
        case .imageTooLarge(let limit):
            return "browser.screenshot exceeds \(limit) bytes"
        case .upstreamError(let message):
            return "browser.screenshot upstream error: \(message)"
        }
    }
}

public enum BrowserScreenshotReadService {
    public static let maxDecodedBytes = 6 * 1024 * 1024
    public static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-browser-screenshots", isDirectory: true)

    public static func read(
        params: JSONValue,
        cmux: CMUXFacade,
        directory: URL = defaultDirectory
    ) async throws -> BrowserScreenshotReadResult {
        let request = try parse(params: params)
        let upstream: JSONValue
        do {
            upstream = try await cmux.dispatch(method: "browser.screenshot", params: .object(request.params))
        } catch {
            throw BrowserScreenshotReadError.upstreamError(String(describing: error))
        }
        let normalized = try normalize(upstream: upstream, request: request, directory: directory)
        return BrowserScreenshotReadResult(json: normalized)
    }

    private struct Request {
        let params: [String: JSONValue]
        let workspaceId: String?
        let surfaceId: String
    }

    private static func parse(params: JSONValue) throws -> Request {
        guard case .object(let object) = params,
              case .string(let surfaceId)? = object["surface_id"],
              !surfaceId.isEmpty
        else { throw BrowserScreenshotReadError.invalidParams }
        let workspaceId: String?
        if case .string(let value)? = object["workspace_id"], !value.isEmpty {
            workspaceId = value
        } else {
            workspaceId = nil
        }
        return Request(params: object, workspaceId: workspaceId, surfaceId: surfaceId)
    }

    private static func normalize(upstream: JSONValue, request: Request, directory: URL) throws -> JSONValue {
        guard case .object(let object) = upstream else {
            throw BrowserScreenshotReadError.unsupportedResponse
        }
        let payload = screenshotPayload(from: object)
        let image = try imageData(from: payload, directory: directory)
        let surfaceId = stringField("surface_id", in: payload) ?? request.surfaceId
        var result: [String: JSONValue] = [
            "surface_id": .string(surfaceId),
            "mime_type": .string(image.mimeType),
            "data_base64": .string(image.data.base64EncodedString()),
        ]
        if let workspaceId = stringField("workspace_id", in: payload) ?? request.workspaceId {
            result["workspace_id"] = .string(workspaceId)
        }
        copyString("title", from: payload, to: &result)
        copyNonFileURL(from: payload, to: &result)
        if let capturedAt = stringField("captured_at", in: payload) {
            result["captured_at"] = .string(capturedAt)
        } else {
            result["captured_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        }
        copyInt("width", from: payload, to: &result)
        copyInt("height", from: payload, to: &result)
        return .object(result)
    }

    private static func screenshotPayload(from object: [String: JSONValue]) -> [String: JSONValue] {
        if hasImageSource(in: object) {
            return object
        }
        if case .object(let result)? = object["result"] {
            return result
        }
        return object
    }

    private static func hasImageSource(in object: [String: JSONValue]) -> Bool {
        stringField("data_base64", in: object) != nil
            || stringField("dataBase64", in: object) != nil
            || stringField("png_base64", in: object) != nil
            || stringField("pngBase64", in: object) != nil
            || stringField("base64", in: object) != nil
            || screenshotURL(from: object) != nil
    }

    private struct ImageData {
        let data: Data
        let mimeType: String
    }

    private static func imageData(from object: [String: JSONValue], directory: URL) throws -> ImageData {
        if let encoded = stringField("data_base64", in: object)
            ?? stringField("dataBase64", in: object)
            ?? stringField("png_base64", in: object)
            ?? stringField("pngBase64", in: object)
            ?? stringField("base64", in: object) {
            guard let data = Data(base64Encoded: encoded) else {
                throw BrowserScreenshotReadError.invalidBase64
            }
            try validateImageData(data)
            return ImageData(data: data, mimeType: mimeType(from: object, fallbackURL: nil))
        }

        guard let url = screenshotURL(from: object) else {
            throw BrowserScreenshotReadError.unsupportedResponse
        }
        guard isAllowed(url, under: directory) else {
            throw BrowserScreenshotReadError.unsupportedResponse
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BrowserScreenshotReadError.readFailed(String(describing: error))
        }
        try validateImageData(data)
        return ImageData(data: data, mimeType: mimeType(from: object, fallbackURL: url))
    }

    private static func validateImageData(_ data: Data) throws {
        guard data.count <= maxDecodedBytes else {
            throw BrowserScreenshotReadError.imageTooLarge(maxDecodedBytes)
        }
        guard isImageData(data) else {
            throw BrowserScreenshotReadError.unsupportedResponse
        }
    }

    private static func isImageData(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: [0x47, 0x49, 0x46, 0x38])
            || isWebPData(data)
    }

    private static func isWebPData(_ data: Data) -> Bool {
        data.count >= 12
            && data[0] == 0x52
            && data[1] == 0x49
            && data[2] == 0x46
            && data[3] == 0x46
            && data[8] == 0x57
            && data[9] == 0x45
            && data[10] == 0x42
            && data[11] == 0x50
    }

    private static func screenshotURL(from object: [String: JSONValue]) -> URL? {
        if let path = stringField("path", in: object)
            ?? stringField("file_path", in: object)
            ?? stringField("filePath", in: object) {
            return URL(fileURLWithPath: path)
        }
        guard let value = stringField("url", in: object),
              let url = URL(string: value),
              url.isFileURL
        else { return nil }
        return url
    }

    private static func isAllowed(_ url: URL, under directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func mimeType(from object: [String: JSONValue], fallbackURL: URL?) -> String {
        if let value = stringField("mime_type", in: object) ?? stringField("mimeType", in: object),
           value.hasPrefix("image/") {
            return value
        }
        if fallbackURL?.pathExtension.lowercased() == "jpg" || fallbackURL?.pathExtension.lowercased() == "jpeg" {
            return "image/jpeg"
        }
        return "image/png"
    }

    private static func stringField(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case .string(let value)? = object[key], !value.isEmpty else { return nil }
        return value
    }

    private static func intField(_ key: String, in object: [String: JSONValue]) -> Int64? {
        guard case .int(let value)? = object[key] else { return nil }
        return value
    }

    private static func copyString(_ key: String, from source: [String: JSONValue], to result: inout [String: JSONValue]) {
        guard let value = stringField(key, in: source) else { return }
        result[key] = .string(value)
    }

    private static func copyNonFileURL(from source: [String: JSONValue], to result: inout [String: JSONValue]) {
        guard let value = stringField("url", in: source) else { return }
        if URL(string: value)?.isFileURL == true { return }
        result["url"] = .string(value)
    }

    private static func copyInt(_ key: String, from source: [String: JSONValue], to result: inout [String: JSONValue]) {
        guard let value = intField(key, in: source) else { return }
        result[key] = .int(value)
    }
}
