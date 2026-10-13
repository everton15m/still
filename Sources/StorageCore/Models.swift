import Foundation
import Darwin

// Foundation prettifies /private/var as /var, while DirectoryEnumerator emits
// /private/var. Keep physical paths consistent when indexing the directory tree.
public func canonicalURL(_ url: URL) -> URL {
    guard let pointer = realpath(url.path, nil) else { return url }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer))
}

public enum FileCategory: String, CaseIterable, Sendable {
    case videos = "Videos", archives = "Archives", installers = "Installers"
    case documents = "Documents", other = "Other"

    public static func classify(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return .videos
        case "zip", "gz", "tar", "7z", "rar", "bz2", "xz": return .archives
        case "dmg", "iso", "pkg": return .installers
        case "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "txt", "csv": return .documents
        default: return .other
        }
    }
}

public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct FileMetadata: Equatable, Sendable {
    public let identity: FileIdentity
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let links: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let mode: UInt16
    public let owner: UInt32
    public let flags: UInt32
    public var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    public var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    public var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    // SF_DATALESS: never hydrate an online-only file just to hash it.
    public var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds)) }

    public static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return from(value)
    }

    static func from(_ value: stat) -> Self {
        Self(identity: FileIdentity(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino),
             logicalBytes: max(0, value.st_size), allocatedBytes: max(0, value.st_blocks * 512),
             links: UInt64(value.st_nlink), modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
             modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec), changedSeconds: Int64(value.st_ctimespec.tv_sec),
             changedNanoseconds: Int64(value.st_ctimespec.tv_nsec), mode: value.st_mode,
             owner: value.st_uid, flags: value.st_flags)
    }
}

public struct FileRecord: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let metadata: FileMetadata
    public var name: String { url.lastPathComponent }
    public var category: FileCategory { .classify(url) }
    public init(url: URL, metadata: FileMetadata) { self.url = url; self.metadata = metadata }
}

public struct DirectoryRecord: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let metadata: FileMetadata?
    public var allocatedBytes: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var fileCount: Int = 0
    public var incomplete = false
    public init(url: URL, metadata: FileMetadata? = nil) { self.url = url; self.metadata = metadata }
}

public struct ScanIssue: Identifiable, Sendable {
    public var id: String { url.path + reason }
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}

public struct ScanProgress: Sendable {
    public let visited: Int
    public let allocatedBytes: Int64
    public let currentPath: String
    public let largest: [FileRecord]
}

public struct ScanResult: Sendable {
    public let root: URL
    public var directories: [String: DirectoryRecord]
    // Bounded metadata for large files; all regular files contribute to folder totals.
    public var files: [FileRecord]
    public let visited: Int
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let cancelled: Bool
    public let limited: Bool
    public let finished: Date
    public var allocatedBytes: Int64 { directories[root.path]?.allocatedBytes ?? 0 }
    public func children(of url: URL) -> [DirectoryRecord] {
        directories.values.filter { $0.url != url && $0.url.deletingLastPathComponent() == url }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
    public func files(in url: URL) -> [FileRecord] {
        files.filter { $0.url.deletingLastPathComponent() == url }
            .sorted { $0.metadata.allocatedBytes > $1.metadata.allocatedBytes }
    }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

public enum StorageFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct DiskCapacity: Sendable {
    public let total: Int64
    public let available: Int64
    public let importantAvailable: Int64?
    public var used: Int64 { max(0, total - available) }
    public static var startupURL: URL {
        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        return FileManager.default.fileExists(atPath: data.path) ? data : URL(fileURLWithPath: "/")
    }
    public static func read(at url: URL = startupURL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else {
            throw StorageFailure.message("macOS did not return capacity for the startup volume.")
        }
        return Self(total: Int64(total), available: Int64(available), importantAvailable: values.volumeAvailableCapacityForImportantUsage)
    }
}

public struct LowStorageGate: Sendable {
    public private(set) var warned: Bool
    public init(warned: Bool = false) { self.warned = warned }
    public mutating func shouldNotify(available: Int64, threshold: Int64) -> Bool {
        let recovery = max(2_000_000_000, threshold / 10)
        if available >= threshold + recovery { warned = false }
        if available < threshold && !warned { warned = true; return true }
        return false
    }
    public mutating func deliveryFailed() { warned = false }
}
