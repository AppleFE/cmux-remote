import NIOCore
import NIOPosix
import Foundation

public enum UnixSocketChannelError: Error, Equatable {
    case socketMissing(String)
    case connectFailed(String)
}

/// Default cmux socket location on macOS.
///
/// Resolution order:
/// 1. `CMUX_SOCKET_PATH`
/// 2. deprecated `CMUX_SOCKET`
/// 3. cmux's `last-socket-path` marker, when it points at an existing path
/// 4. the historical per-user `cmux.sock` fallback
///
/// Modern cmux can rotate from `cmux.sock` to a per-user socket such as
/// `cmux-501.sock`. Following `last-socket-path` avoids leaving long-running
/// relay installs pinned to a stale socket path after cmux restarts.
public func cmuxSocketPath(
    _ env: [String: String] = ProcessInfo.processInfo.environment,
    appSupportDirectory: URL? = nil,
    fileManager: FileManager = .default
) -> String {
    if let p = env["CMUX_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
    if let p = env["CMUX_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }

    let appSupport = appSupportDirectory ?? defaultAppSupportDirectory(env)
    let cmuxDirectory = appSupport.appendingPathComponent("cmux", isDirectory: true)
    let marker = cmuxDirectory.appendingPathComponent("last-socket-path", isDirectory: false)
    if let data = try? Data(contentsOf: marker),
       let raw = String(data: data, encoding: .utf8)
    {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty, fileManager.fileExists(atPath: candidate) {
            return candidate
        }
    }

    return cmuxDirectory.appendingPathComponent("cmux.sock", isDirectory: false).path
}

private func defaultAppSupportDirectory(_ env: [String: String]) -> URL {
    if let home = env["HOME"], !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }
    if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return dir
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
}

/// Resolves the password used by cmux `socketControlMode=password`.
///
/// Order intentionally matches current cmux CLI behavior for non-interactive
/// local automation: `CMUX_SOCKET_PASSWORD` first, then the per-user password
/// file written by cmux Settings. The relay does not put secrets into launchd
/// plists; a launchd-started relay can read the same owner-only file.
public func cmuxSocketPassword(
    _ env: [String: String] = ProcessInfo.processInfo.environment,
    appSupportDirectory: URL? = nil,
    fileManager: FileManager = .default
) -> String? {
    if let p = normalizedSocketPassword(env["CMUX_SOCKET_PASSWORD"]) {
        return p
    }

    guard let appSupportDirectory = appSupportDirectory
        ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
        return nil
    }

    let passwordFile = appSupportDirectory
        .appendingPathComponent("cmux", isDirectory: true)
        .appendingPathComponent("socket-control-password", isDirectory: false)
    guard fileManager.fileExists(atPath: passwordFile.path),
          let data = try? Data(contentsOf: passwordFile),
          let raw = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return normalizedSocketPassword(raw)
}

private func normalizedSocketPassword(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Connects to a Unix-domain socket and installs the JSON line framer.
public struct UnixSocketChannel {
    public let path: String
    public let group: EventLoopGroup
    public init(path: String, group: EventLoopGroup) { self.path = path; self.group = group }

    public func connect(handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>)
        async throws -> Channel
    {
        guard FileManager.default.fileExists(atPath: path) else {
            throw UnixSocketChannelError.socketMissing(path)
        }
        let bs = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    LineFrameDecoder(),
                    LineFrameEncoder(),
                ]).flatMap { handler(channel) }
            }
        do {
            return try await bs.connect(unixDomainSocketPath: path).get()
        } catch {
            throw UnixSocketChannelError.connectFailed(String(describing: error))
        }
    }
}
