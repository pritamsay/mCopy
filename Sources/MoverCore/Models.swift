import Foundation

public enum TransferError: LocalizedError {
    case stopped
    case unavailable(String)
    case unsafe(String)

    public var errorDescription: String? {
        switch self {
        case .stopped: return "Paused. Resume when you are ready."
        case .unavailable(let message), .unsafe(let message): return message
        }
    }
}

public enum Choice: String, Codable {
    case replace, skip, rename, cancel
}

public struct Decision {
    public var choice: Choice
    public var applyToAll: Bool
    public var newName: String?

    public init(_ choice: Choice, all: Bool = false, newName: String? = nil) {
        self.choice = choice
        self.applyToAll = all
        self.newName = newName
    }
}

public struct Progress {
    public var message: String
    public var fraction: Double
    public var copiedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var completedFiles = 0
    public var totalFiles = 0
    public var copyingFile = ""
    public var verifyingFile = ""
    public var sequence: UInt64 = 0
}

// A file's identity is checked again before an existing file is changed.
struct FileStamp: Codable, Equatable {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var seconds: Int64
    var nanoseconds: Int64

    func sameFile(as other: FileStamp, onNetwork: Bool = false) -> Bool {
        (onNetwork || device == other.device) && inode == other.inode
    }

    func matches(_ other: FileStamp, onNetwork: Bool = false) -> Bool {
        sameFile(as: other, onNetwork: onNetwork) && size == other.size &&
            seconds == other.seconds && nanoseconds == other.nanoseconds
    }
}

public struct Entry: Codable {
    var id = UUID().uuidString
    var source: Location
    var target: String
    var directory: Bool
    var size: Int64
    var modified: Date
    var sourceStamp: FileStamp
    var state = "ready"
    var replace = false
    var existingStamp: FileStamp?
    var temporaryStamp: FileStamp?
    var publicationStamp: FileStamp?
    var digest: String?
    var cleanupRequired = false
}

public struct Job: Codable {
    // The reconstructed journal has its own schema. Old journals are not guessed.
    var formatVersion = 2
    var id = UUID().uuidString
    var destination: Location
    var destinationStamp: FileStamp
    var entries: [Entry]
    var move: Bool
    public var limitMB: Double
}
