import Foundation

public enum CleanupRisk: String, Sendable { case low = "Low risk", review = "Review first" }

public struct CleanupSuggestion: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let title: String
    public let detail: String
    public let bytes: Int64
    public let risk: CleanupRisk
    public var inspectOnly = false
}

public struct SuggestionEngine: Sendable {
    public init() {}
    public func suggestions(from result: ScanResult, policy: SafetyPolicy, now: Date = Date()) -> [CleanupSuggestion] {
        let downloads = policy.home.appendingPathComponent("Downloads").path
        var suggestions: [CleanupSuggestion] = []
        for file in result.files where file.metadata.allocatedBytes >= 100_000_000 {
            guard policy.rejectionReason(for: file.url) == nil else { continue }
            let old = now.timeIntervalSince(file.metadata.modified) > 30 * 86_400
            let inDownloads = isWithin(file.url.path, downloads)
            let title: String
            let detail: String
            switch file.category {
            case .installers where old:
                title = "Review an older installer"
                detail = "More than 30 days old. Keep it if you still need to install or restore this software."
            case .archives where inDownloads:
                title = "Review a downloaded archive"
                detail = "If you have already extracted it and no longer need the original, it may be a useful cleanup."
            case .videos:
                title = "Review a large recording or video"
                detail = "Consider archiving it elsewhere. Size alone does not make it unnecessary."
            default:
                if inDownloads { title = "Review a large download"; detail = "Confirm you no longer need this download before moving it to Trash." }
                else if old && ["tmp", "temp"].contains(file.url.pathExtension.lowercased()) {
                    title = "Review an old temporary file"; detail = "A .tmp or .temp file over 30 days old. Check that its app is no longer using it."
                } else { continue }
            }
            suggestions.append(CleanupSuggestion(url: file.url, title: title, detail: detail,
                                                 bytes: file.metadata.allocatedBytes, risk: .review))
        }
        let cache = policy.home.appendingPathComponent("Library/Caches/Homebrew/downloads")
        if let folder = result.directories[cache.path], folder.allocatedBytes >= 100_000_000,
           !folder.incomplete, policy.rejectionReason(for: cache) == nil {
            suggestions.append(CleanupSuggestion(url: cache, title: "Review Homebrew downloads",
                detail: "Recognized download cache; Homebrew can download it again. Finish any running brew commands first.",
                bytes: folder.allocatedBytes, risk: .low))
        }
        suggestions.sort {
            if $0.risk != $1.risk { return $0.risk == .low }
            return $0.bytes > $1.bytes
        }
        var chosen = Array(suggestions.prefix(5))
        if let folder = result.directories.values.filter({
            $0.allocatedBytes >= 1_000_000_000 && policy.rejectionReason(for: $0.url) == nil
        }).sorted(by: { $0.allocatedBytes > $1.allocatedBytes }).first {
            // Folder suggestions are for inspection; no blanket judgement about their contents.
            if !chosen.contains(where: { isWithin($0.url.path, folder.url.path) || isWithin(folder.url.path, $0.url.path) }) {
                chosen.append(CleanupSuggestion(url: folder.url, title: "Explore a large folder",
                    detail: "Inspect its contents and keep anything you need.", bytes: folder.allocatedBytes, risk: .review, inspectOnly: true))
            }
        }
        return Array(chosen.prefix(6))
    }
}
