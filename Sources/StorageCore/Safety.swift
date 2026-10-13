import Foundation
import Darwin

public struct SafetyPolicy: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = canonicalURL(home)
    }

    public func rejectionReason(for url: URL) -> String? {
        let path = url.path
        guard isWithin(path, home.path), path != home.path else { return "Only items inside your home folder can be moved to Trash." }
        let relative = String(path.dropFirst(home.path.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        let roots: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "Applications"]
        if parts.count == 1 && roots.contains(parts[0]) { return "Keep this standard home folder; review its contents instead." }
        if parts.contains(where: { $0.hasPrefix(".") && $0 != ".DS_Store" }) { return "Hidden configuration, repositories, and Trash are inspection-only." }
        if parts.first == "Library" {
            let cache = home.appendingPathComponent("Library/Caches/Homebrew/downloads").path
            guard isWithin(path, cache) else { return "Application data and unknown caches are protected. Only recognized Homebrew downloads are eligible." }
        }
        let protectedExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "photolibrary", "musiclibrary", "pvm", "vmwarevm"]
        if parts.contains(where: { protectedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
            return "Application bundles, media libraries, and virtual machines are inspection-only. Manage them in their own app."
        }
        let ext = url.pathExtension.lowercased()
        if ["db", "db-wal", "db-shm", "sqlite", "sqlite3", "sqlitedb", "sqlite-wal", "sqlite-shm", "sqlite3-wal", "sqlite3-shm", "realm", "mdb", "anki2"].contains(ext) {
            return "Application databases are protected."
        }
        guard path == canonicalURL(url).path else { return "Symbolic links and paths through symbolic links are inspection-only." }
        return nil
    }

    public func rejectionReason(for file: FileRecord) -> String? {
        if let reason = rejectionReason(for: file.url) { return reason }
        if file.metadata.owner != getuid() { return "This file belongs to another user." }
        if file.metadata.isDataless { return "Online-only files are inspection-only; manage their cloud copies in Finder." }
        return nil
    }
}

public struct TrashItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    fileprivate let entries: [String: FileMetadata]
}

public struct TrashPlan: Sendable {
    public let items: [TrashItem]
    public let duplicateRetentions: [DuplicateRetention]
    public var estimatedBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

public struct TrashOutcome: Sendable {
    public let moved: [URL]
    public let failures: [ScanIssue]
}

public struct TrashService: Sendable {
    public let policy: SafetyPolicy
    public init(policy: SafetyPolicy = SafetyPolicy()) { self.policy = policy }

    // Preparation is read-only. The UI presents these exact paths before calling execute.
    public func prepare(urls: [URL], expected: [String: FileMetadata] = [:],
                        preserving duplicateRetentions: [DuplicateRetention] = [],
                        cancellation: CancellationFlag = CancellationFlag()) throws -> TrashPlan {
        if cancellation.isCancelled { throw CancellationError() }
        let selected = Array(Set(urls)).sorted { $0.path.count < $1.path.count }
        guard !selected.isEmpty else { throw StorageFailure.message("Select an item first.") }
        for retention in duplicateRetentions {
            guard !retention.selectedURLs.isEmpty,
                  retention.selectedURLs.allSatisfy({ selected.contains($0) }),
                  retention.retainedCopies.allSatisfy({ copy in !selected.contains(where: { isWithin(copy.id, $0.path) }) }) else {
                throw StorageFailure.message("Select duplicate copies to remove and keep at least one separate copy in every group.")
            }
            _ = try survivingCopy(in: retention)
        }
        var items: [TrashItem] = []
        for url in selected {
            if cancellation.isCancelled { throw CancellationError() }
            if items.contains(where: { isWithin(url.path, $0.url.path) }) { continue }
            if let previous = expected[url.path], try FileMetadata.read(url) != previous {
                throw StorageFailure.message("\(url.lastPathComponent) changed since scanning. Scan again before moving it.")
            }
            let entries = try snapshot(url, cancellation: cancellation)
            var seen = Set<FileIdentity>()
            let bytes = entries.values.filter { $0.isRegular && seen.insert($0.identity).inserted }
                .reduce(Int64(0)) { $0 + $1.allocatedBytes }
            items.append(TrashItem(url: url, bytes: bytes, entries: entries))
        }
        if cancellation.isCancelled { throw CancellationError() }
        return TrashPlan(items: items, duplicateRetentions: duplicateRetentions)
    }

    public func execute(_ plan: TrashPlan, confirmed: Bool,
                        move: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }) throws -> TrashOutcome {
        guard confirmed else { throw StorageFailure.message("Moving to Trash requires explicit confirmation.") }
        var moved: [URL] = [], failures: [ScanIssue] = []
        for item in plan.items {
            do {
                var coordinationError: NSError?
                var operationError: Error?
                var didMove = false
                let coordinator = NSFileCoordinator(filePresenter: nil)
                func moveReviewedItem(_ coordinatedURL: URL, keeping keeper: FileRecord? = nil, readURL: URL? = nil) {
                    do {
                        if let keeper {
                            guard readURL == keeper.url, try FileMetadata.read(keeper.url) == keeper.metadata else {
                                throw StorageFailure.message("The copy you kept changed or disappeared. Compare duplicates again before moving any more copies.")
                            }
                        }
                        guard coordinatedURL == item.url else { throw StorageFailure.message("The selected path changed during coordination. Review it again.") }
                        let current = try snapshot(coordinatedURL, cancellation: CancellationFlag())
                        guard current == item.entries else { throw StorageFailure.message("The item changed after review. Review it again before moving it.") }
                        try move(coordinatedURL)
                        didMove = true
                    } catch { operationError = error }
                }
                if let retention = plan.duplicateRetentions.first(where: { $0.selectedURLs.contains(item.url) }) {
                    let keeper = try survivingCopy(in: retention)
                    // Coordinate the kept file's read with the selected file's move.
                    // Check the retained copy before EVERY move, including later items in a batch.
                    coordinator.coordinate(readingItemAt: keeper.url, options: [], writingItemAt: item.url,
                                           options: .forMoving, error: &coordinationError) { readURL, moveURL in
                        moveReviewedItem(moveURL, keeping: keeper, readURL: readURL)
                    }
                } else {
                    coordinator.coordinate(writingItemAt: item.url, options: .forMoving, error: &coordinationError) { moveReviewedItem($0) }
                }
                if let error = coordinationError { throw error }
                if let error = operationError { throw error }
                guard didMove else { throw StorageFailure.message("macOS could not coordinate this file move.") }
                moved.append(item.url)
            } catch { failures.append(ScanIssue(url: item.url, reason: error.localizedDescription)) }
        }
        return TrashOutcome(moved: moved, failures: failures)
    }

    private func snapshot(_ url: URL, cancellation: CancellationFlag) throws -> [String: FileMetadata] {
        if cancellation.isCancelled { throw CancellationError() }
        if let reason = policy.rejectionReason(for: url) { throw StorageFailure.message(reason) }
        let root = try FileMetadata.read(url)
        try validate(url, root, device: try FileMetadata.read(policy.home).identity.device)
        var entries = [url.path: root]
        if root.isDirectory {
            var readFailure: Error?
            guard let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                readFailure = error; return false
            }) else { throw StorageFailure.message("The folder cannot be fully inspected; it will not be moved.") }
            while let child = enumerator.nextObject() as? URL {
                if cancellation.isCancelled { throw CancellationError() }
                guard entries.count < 100_000 else { throw StorageFailure.message("This folder is too large to safely review as one action. Select smaller items.") }
                if let reason = policy.rejectionReason(for: child) { throw StorageFailure.message("\(child.lastPathComponent): \(reason)") }
                let info = try FileMetadata.read(child)
                try validate(child, info, device: root.identity.device)
                entries[child.path] = info
            }
            if let error = readFailure { throw error }
        }
        return entries
    }

    private func survivingCopy(in retention: DuplicateRetention) throws -> FileRecord {
        guard let copy = retention.retainedCopies.first(where: {
            (try? FileMetadata.read($0.url)) == $0.metadata && canonicalURL($0.url) == $0.url
        }) else {
            throw StorageFailure.message("No unchanged copy remains in this duplicate group. Compare again and choose a copy to keep.")
        }
        return copy
    }

    private func validate(_ url: URL, _ info: FileMetadata, device: UInt64) throws {
        guard (info.isRegular || info.isDirectory), !info.isSymlink,
              info.identity.device == device, info.owner == getuid() else {
            throw StorageFailure.message("\(url.lastPathComponent) is not a user-owned regular file or folder on your home volume.")
        }
        guard !info.isDataless else { throw StorageFailure.message("Online-only files are inspection-only; removing them may also delete their cloud copy.") }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            throw StorageFailure.message("iCloud items are inspection-only. Manage them in Finder to avoid deleting a cloud copy.")
        }
    }
}
