import Foundation

public struct TransferRequest: Codable {
    public var id = UUID().uuidString
    public var created = Date()
    public var sources: [String]
    public var destination: String
    public var move: Bool
    public var token: String
    public var cancelled = false
    public var paused = false

    public init(sources: [URL], destination: URL, move: Bool, token: String) {
        self.sources = sources.map(\.path)
        self.destination = destination.path
        self.move = move
        self.token = token
    }
}

// Requests survive restarts, including requests made while another copy is busy.
public final class RequestStore {
    public let directory: URL
    let files = FileManager.default

    public init(directory: URL) { self.directory = directory }

    public func save(_ request: TransferRequest) throws {
        guard UUID(uuidString: request.id) != nil else { throw TransferError.unsafe("Invalid transfer request.") }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = requestURL(request)
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func pending(includePaused: Bool = false) throws -> [TransferRequest] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        var requests: [TransferRequest] = []
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let request = try JSONDecoder().decode(TransferRequest.self, from: Data(contentsOf: url))
            guard UUID(uuidString: request.id) != nil, url.lastPathComponent == request.id + ".json" else {
                throw TransferError.unsafe("Invalid saved transfer request.")
            }
            if includePaused || !request.paused { requests.append(request) }
        }
        return requests.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }

    // Retained errors get another safe attempt after launch/wake. A saved
    // cancellation stays a cancellation: only its recovery cleanup is resumed.
    public func resumeRetained() throws {
        for var request in try pending(includePaused: true) where request.paused {
            request.paused = false
            try save(request)
        }
    }

    public func journal(for request: TransferRequest) -> URL {
        directory.appendingPathComponent("Jobs").appendingPathComponent(request.id + ".json")
    }

    public func remove(_ request: TransferRequest) throws { try files.removeItem(at: requestURL(request)) }

    private func requestURL(_ request: TransferRequest) -> URL {
        directory.appendingPathComponent(request.id + ".json")
    }
}
