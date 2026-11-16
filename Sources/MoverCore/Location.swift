import Foundation

public struct Location: Codable {
    public var original: String
    var volume: String
    var identity: String
    var relative: String
    var reconnectURL: String?
    var network: Bool

    public init(_ url: URL) throws {
        let url = url.standardizedFileURL
        let values = try url.resourceValues(forKeys: [
            .volumeURLKey, .volumeUUIDStringKey,
            .volumeURLForRemountingKey, .volumeIsLocalKey
        ])
        var root = values.volume?.standardizedFileURL.path ?? "/"
        if root == "/System/Volumes/Data" { root = "/" }
        original = url.path
        volume = root
        network = values.volumeIsLocal == false
        reconnectURL = Self.cleanRemoteURL(values.volumeURLForRemounting)
        if network, let remote = reconnectURL {
            identity = "remote:" + remote
        } else if let uuid = values.volumeUUIDString {
            identity = "uuid:" + uuid
        } else if root == "/" {
            identity = "startup"
        } else {
            throw TransferError.unsafe("Cannot identify this volume safely. Reconnect it in Finder first.")
        }
        let prefix = root == "/" ? "/" : root + "/"
        guard url.path == root || url.path.hasPrefix(prefix) else {
            throw TransferError.unsafe("The file does not belong to the expected volume.")
        }
        relative = url.path == root ? "" : String(url.path.dropFirst(prefix.count))
    }

    public func resolve() throws -> URL {
        if identity == "startup" {
            return URL(fileURLWithPath: "/").appendingPathComponent(relative)
        }
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeURLForRemountingKey]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) ?? []
        // Prefer the previous mount, then look for the same volume under a new name.
        let candidates = [URL(fileURLWithPath: volume)] + mounted
        for candidate in candidates {
            guard let values = try? candidate.resourceValues(forKeys: Set(keys)) else { continue }
            let candidateIdentity: String
            if identity.hasPrefix("remote:"), let remote = Self.cleanRemoteURL(values.volumeURLForRemounting) {
                candidateIdentity = "remote:" + remote
            } else if let uuid = values.volumeUUIDString {
                candidateIdentity = "uuid:" + uuid
            } else {
                continue
            }
            guard candidateIdentity == identity else { continue }
            // An absent /Volumes/share must never fall back to the startup disk.
            let actualRoot = try candidate.resourceValues(forKeys: [.volumeURLKey]).volume
            var root = actualRoot?.standardizedFileURL ?? candidate
            if root.path == "/System/Volumes/Data" { root = URL(fileURLWithPath: "/") }
            if candidate.path != "/" && root.path != candidate.standardizedFileURL.path { continue }
            return root.appendingPathComponent(relative)
        }
        throw TransferError.unavailable("Waiting for \(URL(fileURLWithPath: volume).lastPathComponent) to reconnect. Reconnect it in Finder if necessary.")
    }

    private static func cleanRemoteURL(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.password = nil
        parts.user = nil
        parts.host = parts.host?.lowercased()
        return parts.string
    }
}
