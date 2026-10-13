import Foundation

public struct ScanConfiguration: Sendable {
    public var root: URL
    public var minimumRetainedFileBytes: Int64 = 1_000_000
    public var maximumRetainedFiles = 100_000
    public var maximumDirectories = 100_000
    public var maximumHardLinkIdentities = 100_000
    public var excludedPaths: [String]
    public init(root: URL) {
        self.root = canonicalURL(root)
        excludedPaths = ["/System", "/dev", "/Volumes", "/Network", "/bin", "/sbin",
                         "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/usr/standalone",
                         "/private/var/vm", "/private/var/db", "/private/var/folders", "/.Spotlight-V100",
                         "/.fseventsd", "/.DocumentRevisions-V100", "/.Trashes"]
        // An explicit folder selection can inspect an otherwise excluded subtree.
        excludedPaths.removeAll { isWithin(self.root.path, $0) }
    }
}

public struct StorageScanner: Sendable {
    public init() {}
    public func scan(configuration config: ScanConfiguration, cancellation: CancellationFlag = CancellationFlag(),
                     metadata: @Sendable (URL) throws -> FileMetadata = { try FileMetadata.read($0) },
                     progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> ScanResult {
        let root = config.root
        let rootMeta = try metadata(root)
        guard rootMeta.isDirectory && !rootMeta.isSymlink else { throw StorageFailure.message("Choose a readable folder to scan.") }
        var devices: Set<UInt64> = [rootMeta.identity.device]
        if root.path == "/", let dataMeta = try? metadata(DiskCapacity.startupURL) { devices.insert(dataMeta.identity.device) }
        var directories = [root.path: DirectoryRecord(url: root, metadata: rootMeta)]
        var retained: [FileRecord] = []
        var top: [FileRecord] = []
        var hardLinks = Set<FileIdentity>()
        var visited = 0, issueCount = 0
        var total: Int64 = 0
        var issues: [ScanIssue] = []
        var limited = false
        var lastProgress = Date.distantPast
        func issue(_ url: URL, _ reason: String) {
            issueCount += 1
            if issues.count < 300 { issues.append(ScanIssue(url: url, reason: reason)) }
            let parent = directories[url.path] != nil ? url.path : url.deletingLastPathComponent().path
            directories[parent]?.incomplete = true
        }
        let manager = FileManager()
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [], errorHandler: { url, error in
            issue(url, error.localizedDescription)
            return !cancellation.isCancelled
        }) else { throw StorageFailure.message("This folder cannot be inspected. Check Files & Folders permissions.") }

        while let url = enumerator.nextObject() as? URL {
            if cancellation.isCancelled { break }
            visited += 1
            if config.excludedPaths.contains(where: { isWithin(url.path, $0) }) || url.lastPathComponent == ".Trash" {
                enumerator.skipDescendants()
                issue(url, "Excluded: system-managed, mounted, or Trash storage.")
                continue
            }
            do {
                let info = try metadata(url)
                guard devices.contains(info.identity.device) else {
                    enumerator.skipDescendants(); issue(url, "Another volume; not scanned."); continue
                }
                if info.isSymlink { enumerator.skipDescendants(); continue }
                if info.isDirectory {
                    guard directories.count < config.maximumDirectories else { limited = true; break }
                    directories[url.path] = DirectoryRecord(url: url, metadata: info)
                } else if info.isRegular {
                    if info.links > 1 {
                        if hardLinks.contains(info.identity) { continue }
                        guard hardLinks.count < config.maximumHardLinkIdentities else { limited = true; break }
                        hardLinks.insert(info.identity)
                    }
                    let parent = url.deletingLastPathComponent().path
                    directories[parent]?.allocatedBytes += info.allocatedBytes
                    directories[parent]?.logicalBytes += info.logicalBytes
                    directories[parent]?.fileCount += 1
                    total += info.allocatedBytes
                    let record = FileRecord(url: url, metadata: info)
                    if info.logicalBytes >= config.minimumRetainedFileBytes {
                        if retained.count < config.maximumRetainedFiles { retained.append(record) }
                        else { limited = true }
                    }
                    if top.count < 12 || info.allocatedBytes > (top.last?.metadata.allocatedBytes ?? 0) {
                        top.append(record); top.sort { $0.metadata.allocatedBytes > $1.metadata.allocatedBytes }
                        if top.count > 12 { top.removeLast() }
                    }
                }
            } catch { enumerator.skipDescendants(); issue(url, error.localizedDescription) }
            if Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(ScanProgress(visited: visited, allocatedBytes: total, currentPath: url.path, largest: top))
                lastProgress = Date()
            }
        }
        // Postorder aggregation: each directory contributes once, without walking every file's ancestors.
        for path in directories.keys.sorted(by: { $0.count > $1.count }) where path != root.path {
            guard let item = directories[path] else { continue }
            let parent = item.url.deletingLastPathComponent().path
            directories[parent]?.allocatedBytes += item.allocatedBytes
            directories[parent]?.logicalBytes += item.logicalBytes
            directories[parent]?.fileCount += item.fileCount
            if item.incomplete { directories[parent]?.incomplete = true }
        }
        if cancellation.isCancelled || limited { directories[root.path]?.incomplete = true }
        progress(ScanProgress(visited: visited, allocatedBytes: total, currentPath: root.path, largest: top))
        if limited {
            let retainedPaths = Set(retained.map(\.id))
            retained.append(contentsOf: top.filter { !retainedPaths.contains($0.id) })
        }
        retained.sort { $0.metadata.allocatedBytes > $1.metadata.allocatedBytes }
        if retained.count > config.maximumRetainedFiles { retained = Array(retained.prefix(config.maximumRetainedFiles)) }
        return ScanResult(root: root, directories: directories, files: retained,
                          visited: visited, issues: issues, issueCount: issueCount,
                          cancelled: cancellation.isCancelled, limited: limited, finished: Date())
    }
}

public func isWithin(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}
