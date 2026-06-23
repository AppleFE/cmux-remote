import Foundation

public protocol HTTPClientFacade: Sendable {
    func request(_ request: URLRequest) async throws -> (Data, Int)
}

public final class URLSessionHTTP: HTTPClientFacade, @unchecked Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }
}

public final class AuthClient: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let keychain: Keychain
    public let http: any HTTPClientFacade
    public let scheme: String

    public init(host: String, port: Int, keychain: Keychain, http: any HTTPClientFacade, scheme: String = "http") {
        self.host = host
        self.port = port
        self.keychain = keychain
        self.http = http
        self.scheme = scheme
    }

    public func registerIfNeeded() async throws {
        guard EndpointPolicy.isAllowedRelayHost(host) else { throw AuthError.disallowedHost }
        if let storedHost = try keychain.get("relay_host"), storedHost != host {
            try keychain.wipe()
        }
        if try keychain.get("bearer") != nil, try keychain.get("device_id") != nil, try keychain.get("relay_host") == host { return }
        guard let url = URL(string: "\(scheme)://\(host):\(port)/v1/devices/me/register") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, code) = try await http.request(request)
        guard code == 200 else { throw AuthError.relayRejected(code) }
        let payload = try JSONDecoder().decode(RegisterResponse.self, from: data)
        try keychain.set(payload.deviceId, for: "device_id")
        try keychain.set(payload.token, for: "bearer")
        try keychain.set(host, for: "relay_host")
    }

    public func registerAPNsTokenHex(
        _ tokenHex: String,
        environment: APNsRegistrationEnvironment
    ) async throws {
        guard EndpointPolicy.isAllowedRelayHost(host) else { throw AuthError.disallowedHost }
        guard !tokenHex.isEmpty else { throw AuthError.invalidAPNsToken }
        guard let bearer = try keychain.get("bearer"),
              try keychain.get("device_id") != nil,
              try keychain.get("relay_host") == host
        else {
            throw AuthError.missingBearer
        }
        guard let url = URL(string: "\(scheme)://\(host):\(port)/v1/devices/me/apns") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(APNsRegistrationRequest(
            apnsToken: tokenHex,
            env: environment.rawValue
        ))
        let (_, code) = try await http.request(request)
        guard code == 204 else { throw AuthError.relayRejected(code) }
    }

    public func wipe() throws {
        try keychain.delete("device_id")
        try keychain.delete("bearer")
    }
}

private struct RegisterResponse: Decodable {
    let deviceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case token
    }
}

private struct APNsRegistrationRequest: Encodable {
    let apnsToken: String
    let env: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case env
    }
}

public enum APNsRegistrationEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case prod
}

public enum AuthError: Error, Equatable {
    case invalidURL
    case disallowedHost
    case missingBearer
    case invalidAPNsToken
    case relayRejected(Int)
}
