import Foundation
import CryptoKit
import Darwin

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let files: [FileRecord]
    // An upper bound, never a promise: clones and snapshots may share every block.
    public var potentialBytes: Int64 {
        let sizes = files.map { $0.metadata.allocatedBytes }.sorted()
        return sizes.dropFirst().reduce(0, +)
    }
}

public struct DuplicateResult: Sendable {
    public let groups: [DuplicateGroup]
    public let issues: [ScanIssue]
    public let cancelled: Bool
}

public struct DuplicateRetention: Sendable {
    public let selectedURLs: [URL]
    public let retainedCopies: [FileRecord]

    public init(group: DuplicateGroup, selectedPaths: Set<String>) {
        selectedURLs = group.files.filter { selectedPaths.contains($0.id) }.map(\.url)
        retainedCopies = group.files.filter { !selectedPaths.contains($0.id) }
    }
}

public struct DuplicateDetector: Sendable {
    public init() {}
    public func find(in files: [FileRecord], cancellation: CancellationFlag = CancellationFlag(),
                     progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> DuplicateResult {
        var identities = Set<FileIdentity>()
        let candidates = files.filter {
            $0.metadata.isRegular && !$0.metadata.isDataless && $0.metadata.logicalBytes > 0
            && identities.insert($0.metadata.identity).inserted
        }
        let buckets = Dictionary(grouping: candidates, by: { $0.metadata.logicalBytes })
        let work = buckets.values.filter { $0.count > 1 }.flatMap { $0 }
        var byHash: [String: [FileRecord]] = [:]
        var issues: [ScanIssue] = []
        for (index, file) in work.enumerated() {
            if cancellation.isCancelled { break }
            do {
                let digest = try hash(file, cancellation: cancellation)
                byHash["\(file.metadata.logicalBytes):\(digest)", default: []].append(file)
            } catch {
                if !cancellation.isCancelled && issues.count < 100 {
                    issues.append(ScanIssue(url: file.url, reason: error.localizedDescription))
                }
            }
            progress(index + 1, work.count)
        }
        // Revalidate ALL members after hashing: an earlier member could change while others are read.
        let groups = byHash.compactMap { key, members -> DuplicateGroup? in
            let stable = members.filter {
                if (try? FileMetadata.read($0.url)) == $0.metadata { return true }
                if issues.count < 100 { issues.append(ScanIssue(url: $0.url, reason: "File changed or became inaccessible during comparison.")) }
                return false
            }
            return stable.count > 1 ? DuplicateGroup(id: key, files: stable.sorted { $0.id < $1.id }) : nil
        }.sorted { $0.potentialBytes > $1.potentialBytes }
        return DuplicateResult(groups: groups, issues: issues, cancelled: cancellation.isCancelled)
    }

    private func hash(_ file: FileRecord, cancellation: CancellationFlag) throws -> String {
        guard try FileMetadata.read(file.url) == file.metadata else { throw StorageFailure.message("File changed since the scan. Scan again.") }
        // O_NOFOLLOW and O_NONBLOCK prevent a replaced symlink/FIFO from being opened.
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, FileMetadata.from(status) == file.metadata else {
            throw StorageFailure.message("File was replaced while opening it.")
        }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            bytes += Int64(data.count)
            hasher.update(data: data)
        }
        guard bytes == file.metadata.logicalBytes, try FileMetadata.read(file.url) == file.metadata else {
            throw StorageFailure.message("File changed while comparing its content.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
