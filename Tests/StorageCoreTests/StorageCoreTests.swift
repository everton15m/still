import XCTest
import Darwin
@testable import StorageCore

final class StorageCoreTests: XCTestCase {
    var fixture: URL!
    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Still-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        fixture = canonicalURL(fixture)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixture) }

    @discardableResult
    func write(_ name: String, _ data: Data = Data(repeating: 42, count: 8192)) throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func scan(_ configure: (inout ScanConfiguration) -> Void = { _ in }) throws -> ScanResult {
        var config = ScanConfiguration(root: fixture)
        config.minimumRetainedFileBytes = 1
        configure(&config)
        return try StorageScanner().scan(configuration: config)
    }

    func testFolderAggregationAndLargestFiles() throws {
        let a = try write("Downloads/a.zip", Data(repeating: 1, count: 8192))
        let b = try write("Downloads/b.mov", Data(repeating: 2, count: 32768))
        let c = try write("Documents/c.txt")
        let result = try scan()
        let expected = try [a, b, c].map { try FileMetadata.read($0).allocatedBytes }.reduce(0, +)
        XCTAssertEqual(result.allocatedBytes, expected)
        XCTAssertEqual(result.directories[fixture.path]?.fileCount, 3)
        XCTAssertEqual(result.files.first?.url, b)
        XCTAssertEqual(result.children(of: fixture).count, 2)
        XCTAssertEqual(FileCategory.classify(a), .archives)
    }

    func testHardLinksCountOnceAndSymlinkLoopIsNotFollowed() throws {
        let a = try write("a.bin")
        try FileManager.default.linkItem(at: a, to: fixture.appendingPathComponent("b.bin"))
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("loop"), withDestinationURL: fixture)
        let result = try scan()
        XCTAssertEqual(result.allocatedBytes, try FileMetadata.read(a).allocatedBytes)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.visited, 3)
    }

    func testSparseFileUsesAllocatedRatherThanLogicalSize() throws {
        let url = try write("sparse.bin", Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 32_000_000)
        try handle.close()
        let result = try scan()
        XCTAssertEqual(result.files.first?.metadata.logicalBytes, 32_000_000)
        XCTAssertLessThan(result.allocatedBytes, 32_000_000)
    }

    func testPermissionFailureIsReportedWithoutLosingReadableFiles() throws {
        let inaccessible = try write("blocked/secret.bin")
        let readable = try write("readable.bin")
        var config = ScanConfiguration(root: fixture)
        config.minimumRetainedFileBytes = 1
        let result = try StorageScanner().scan(configuration: config, metadata: { url in
            if isWithin(url.path, inaccessible.deletingLastPathComponent().path) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            }
            return try FileMetadata.read(url)
        })
        XCTAssertTrue(result.files.contains { $0.url == readable })
        XCTAssertFalse(result.files.contains { $0.url == inaccessible })
        XCTAssertGreaterThan(result.issueCount, 0)
        XCTAssertTrue(result.directories[fixture.path]?.incomplete == true)
    }

    func testUnreadableRootFailsClearly() throws {
        let config = ScanConfiguration(root: fixture)
        XCTAssertThrowsError(try StorageScanner().scan(configuration: config, metadata: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }))
    }

    func testCancellationAndProgressProvidePartialResults() throws {
        for index in 0..<20 { try write("\(index).bin") }
        let flag = CancellationFlag()
        let result = try StorageScanner().scan(configuration: ScanConfiguration(root: fixture), cancellation: flag, progress: { progress in
            if progress.visited >= 1 { flag.cancel() }
        })
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(result.visited, 20)
        XCTAssertGreaterThan(result.allocatedBytes, 0)
    }

    func testExclusionsAndMemoryBudgetsAreExplicit() throws {
        try write("excluded/a.bin")
        for index in 0..<10 { try write("\(index).bin") }
        let result = try scan { config in
            config.maximumRetainedFiles = 3
            config.excludedPaths = [fixture.appendingPathComponent("excluded").path]
        }
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertEqual(result.directories[fixture.path]?.fileCount, 10)
        XCTAssertEqual(result.issueCount, 1)
    }

    func testDuplicatesRequireMatchingContentAndExcludeHardLinks() throws {
        let a = try write("a.bin")
        let b = try write("b.bin")
        try write("different.bin", Data(repeating: 99, count: 8192))
        try FileManager.default.linkItem(at: a, to: fixture.appendingPathComponent("link.bin"))
        let result = DuplicateDetector().find(in: try scan().files)
        XCTAssertEqual(result.groups.count, 1)
        guard let group = result.groups.first else { return }
        XCTAssertEqual(group.files.count, 2)
        XCTAssertTrue(group.files.contains { $0.url == b })
        XCTAssertEqual(group.potentialBytes, try FileMetadata.read(b).allocatedBytes)
    }

    func testChangedAndDeletedFilesAreNotDeclaredDuplicates() throws {
        let a = try write("a.bin")
        let b = try write("b.bin")
        let records = try scan().files
        try Data(repeating: 7, count: 16384).write(to: a)
        try FileManager.default.removeItem(at: b)
        let result = DuplicateDetector().find(in: records)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.issues.count, 2)
    }

    func testDuplicateCancellation() throws {
        try write("a.bin"); try write("b.bin")
        let flag = CancellationFlag(); flag.cancel()
        let result = DuplicateDetector().find(in: try scan().files, cancellation: flag)
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testSafetyRejectsSystemHomeRootsUnknownCachesDatabasesAndPackages() throws {
        let policy = SafetyPolicy(home: fixture)
        for path in ["/System/a", fixture.path, fixture.appendingPathComponent("Downloads").path,
                     fixture.appendingPathComponent("Library/Application Support/a").path,
                     fixture.appendingPathComponent("Library/Caches/Unknown/a").path,
                     fixture.appendingPathComponent("Pictures/Library.photoslibrary/a").path,
                     fixture.appendingPathComponent("a.sqlite").path,
                     fixture.appendingPathComponent("a.sqlite3-wal").path,
                     fixture.appendingPathComponent("a.realm").path] {
            XCTAssertNotNil(policy.rejectionReason(for: URL(fileURLWithPath: path)), path)
        }
        XCTAssertNil(policy.rejectionReason(for: fixture.appendingPathComponent("Downloads/readme.txt")))
        XCTAssertNil(policy.rejectionReason(for: fixture.appendingPathComponent("Library/Caches/Homebrew/downloads/archive.tar")))
    }

    func testSymlinkAndAncestorSymlinkEscapeAreRejected() throws {
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/System"))
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        XCTAssertThrowsError(try service.prepare(urls: [fixture.appendingPathComponent("escape")]))
        XCTAssertThrowsError(try service.prepare(urls: [fixture.appendingPathComponent("escape/Library")]))
    }

    func testTrashRequiresConfirmationAndDoesNotMoveAnythingBeforeIt() throws {
        let url = try write("a.bin")
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var moved = false
        XCTAssertThrowsError(try service.execute(plan, confirmed: false, move: { _ in moved = true }))
        XCTAssertFalse(moved)
        let result = try service.execute(plan, confirmed: true, move: { _ in moved = true })
        XCTAssertTrue(moved)
        XCTAssertEqual(result.moved, [url])
    }

    func testTrashRefusesChangedFileAndFolderContentsAfterReview() throws {
        let file = try write("folder/a.bin")
        let folder = file.deletingLastPathComponent()
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [folder, file])
        XCTAssertEqual(plan.items.count, 1)
        try write("folder/new.bin")
        var moved = false
        let result = try service.execute(plan, confirmed: true, move: { _ in moved = true })
        XCTAssertFalse(moved)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testTrashRejectsFilesChangedSinceScan() throws {
        let file = try write("a.bin")
        let expected = try FileMetadata.read(file)
        try Data(repeating: 9, count: 64).write(to: file)
        XCTAssertThrowsError(try TrashService(policy: SafetyPolicy(home: fixture)).prepare(urls: [file], expected: [file.path: expected]))
    }

    func testFolderContainingProtectedDataIsRefused() throws {
        try write("folder/data.sqlite")
        XCTAssertThrowsError(try TrashService(policy: SafetyPolicy(home: fixture)).prepare(urls: [fixture.appendingPathComponent("folder")]))
    }

    func testTrashMoveFailureIsReported() throws {
        let file = try write("a.bin")
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let result = try service.execute(try service.prepare(urls: [file]), confirmed: true, move: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testNativeTrashIntegrationUsesOnlyGeneratedFixture() throws {
        let file = try write("Still-disposable-test-\(UUID().uuidString).bin")
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [file])
        var destination: NSURL?
        defer { if let destination { try? FileManager.default.removeItem(at: destination as URL) } }
        let result = try service.execute(plan, confirmed: true, move: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        })
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(destination)
    }

    func testLowStorageNotificationsUseRecoveryHysteresis() {
        var gate = LowStorageGate()
        XCTAssertTrue(gate.shouldNotify(available: 19_000_000_000, threshold: 20_000_000_000))
        XCTAssertFalse(gate.shouldNotify(available: 18_000_000_000, threshold: 20_000_000_000))
        XCTAssertFalse(gate.shouldNotify(available: 21_000_000_000, threshold: 20_000_000_000))
        XCTAssertFalse(gate.shouldNotify(available: 19_000_000_000, threshold: 20_000_000_000))
        XCTAssertFalse(gate.shouldNotify(available: 22_000_000_000, threshold: 20_000_000_000))
        XCTAssertTrue(gate.shouldNotify(available: 19_000_000_000, threshold: 20_000_000_000))
        gate.deliveryFailed()
        XCTAssertTrue(gate.shouldNotify(available: 19_000_000_000, threshold: 20_000_000_000))
    }

    func testCapacityReadingAndTreemapArea() throws {
        let capacity = try DiskCapacity.read()
        XCTAssertGreaterThan(capacity.total, 0)
        XCTAssertGreaterThanOrEqual(capacity.available, 0)
        let weights: [Int64] = [70, 20, 10, 0]
        let rects = TreemapLayout.rectangles(weights: weights, width: 400, height: 200)
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.width * $1.height }, 80_000, accuracy: 0.001)
        for rect in rects {
            XCTAssertEqual(rect.width * rect.height / 80_000, Double(weights[rect.index]) / 100, accuracy: 0.001)
            XCTAssertLessThanOrEqual(rect.x + rect.width, 400.001)
            XCTAssertLessThanOrEqual(rect.y + rect.height, 200.001)
        }
    }

    func testSuggestionsArePrioritizedAndOnlyRecommendUserEligibleData() throws {
        func largeRecord(_ name: String, bytes: Int64, daysOld: Int) throws -> FileRecord {
            let url = try write(name)
            var value = stat()
            XCTAssertEqual(lstat(url.path, &value), 0)
            value.st_size = bytes
            value.st_blocks = bytes / 512
            value.st_mtimespec.tv_sec = Int(Date().timeIntervalSince1970) - daysOld * 86_400
            return FileRecord(url: url, metadata: FileMetadata.from(value))
        }
        let files = try [largeRecord("Downloads/old.dmg", bytes: 800_000_000, daysOld: 90),
                         largeRecord("Downloads/archive.zip", bytes: 400_000_000, daysOld: 0),
                         largeRecord("Movies/recording.mov", bytes: 600_000_000, daysOld: 0),
                         largeRecord("Library/Application Support/recording.mov", bytes: 2_000_000_000, daysOld: 90),
                         largeRecord("Documents/needed.pdf", bytes: 900_000_000, daysOld: 90)]
        let cache = fixture.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var folder = DirectoryRecord(url: cache)
        folder.allocatedBytes = 200_000_000
        let result = ScanResult(root: fixture, directories: [cache.path: folder], files: files,
            visited: 5, issues: [], issueCount: 0, cancelled: false, limited: false, finished: Date())
        let suggestions = SuggestionEngine().suggestions(from: result, policy: SafetyPolicy(home: fixture))
        XCTAssertEqual(suggestions.count, 4)
        XCTAssertEqual(suggestions.first?.risk, .low)
        XCTAssertEqual(suggestions.dropFirst().map(\.bytes), [800_000_000, 600_000_000, 400_000_000])
        XCTAssertFalse(suggestions.contains { $0.url.lastPathComponent == "needed.pdf" })
        XCTAssertTrue(suggestions.allSatisfy { !isWithin($0.url.path, fixture.appendingPathComponent("Library/Application Support").path) })
    }

    func testIncompleteCacheIsNotSuggested() throws {
        let cache = fixture.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var folder = DirectoryRecord(url: cache)
        folder.allocatedBytes = 300_000_000; folder.incomplete = true
        let result = ScanResult(root: fixture, directories: [cache.path: folder], files: [],
            visited: 1, issues: [], issueCount: 0, cancelled: false, limited: false, finished: Date())
        XCTAssertTrue(SuggestionEngine().suggestions(from: result, policy: SafetyPolicy(home: fixture)).isEmpty)
    }

    func testLargeFolderSuggestionIsForExploration() throws {
        let url = fixture.appendingPathComponent("Documents/Project")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = DirectoryRecord(url: url)
        folder.allocatedBytes = 2_000_000_000
        let result = ScanResult(root: fixture, directories: [url.path: folder], files: [],
            visited: 1, issues: [], issueCount: 0, cancelled: false, limited: false, finished: Date())
        let suggestions = SuggestionEngine().suggestions(from: result, policy: SafetyPolicy(home: fixture))
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertTrue(suggestions.first?.inspectOnly == true)
        XCTAssertEqual(suggestions.first?.risk, .review)
    }

    func testDirectoryBudgetStopsWithPartialCoverage() throws {
        try write("one/a.bin"); try write("two/b.bin")
        let result = try scan { $0.maximumDirectories = 2 }
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.directories[result.root.path]?.incomplete == true)
    }

    func testNewDuplicateChangesDuringComparisonAreRevalidated() throws {
        let a = try write("a.bin")
        try write("b.bin")
        let records = try scan().files
        let result = DuplicateDetector().find(in: records, progress: { done, total in
            if done == total { try? Data(repeating: 9, count: 8192).write(to: a) }
        })
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testReplacingSelectedFileWithSymlinkAfterReviewIsRejected() throws {
        let a = try write("a.bin")
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [a])
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        var moved = false
        let outcome = try service.execute(plan, confirmed: true, move: { _ in moved = true })
        XCTAssertFalse(moved)
        XCTAssertEqual(outcome.failures.count, 1)
    }

    func duplicateFixture(count: Int = 2) throws -> DuplicateGroup {
        for index in 0..<count { try write("copy-\(index).bin") }
        return try XCTUnwrap(DuplicateDetector().find(in: try scan().files).groups.first)
    }

    func testDuplicateReviewRequiresAnUnchangedKeptCopy() throws {
        let group = try duplicateFixture()
        let selected = group.files[0]
        let retention = DuplicateRetention(group: group, selectedPaths: [selected.id])
        try FileManager.default.removeItem(at: group.files[1].url)
        XCTAssertThrowsError(try TrashService(policy: SafetyPolicy(home: fixture)).prepare(urls: [selected.url], preserving: [retention]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.id))
    }

    func testDuplicateTrashRefusesMissingOrChangedKeptCopyAfterReview() throws {
        let group = try duplicateFixture()
        let selected = group.files[0], keeper = group.files[1]
        let retention = DuplicateRetention(group: group, selectedPaths: [selected.id])
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [selected.url], preserving: [retention])
        try Data(repeating: 99, count: 8192).write(to: keeper.url)
        var moved = false
        let changed = try service.execute(plan, confirmed: true, move: { _ in moved = true })
        XCTAssertFalse(moved)
        XCTAssertEqual(changed.failures.count, 1)
        try FileManager.default.removeItem(at: keeper.url)
        let missing = try service.execute(plan, confirmed: true, move: { _ in moved = true })
        XCTAssertFalse(moved)
        XCTAssertEqual(missing.failures.count, 1)
    }

    func testDuplicateTrashAllowsAnotherUnchangedRetainedCopy() throws {
        let group = try duplicateFixture(count: 3)
        let selected = group.files[0]
        let retention = DuplicateRetention(group: group, selectedPaths: [selected.id])
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: [selected.url], preserving: [retention])
        try FileManager.default.removeItem(at: group.files[1].url)
        let result = try service.execute(plan, confirmed: true, move: { _ in })
        XCTAssertEqual(result.moved, [selected.url])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testDuplicateTrashRechecksRetainedCopyBeforeEveryMove() throws {
        let group = try duplicateFixture(count: 3)
        let selected = Array(group.files.prefix(2)), keeper = group.files[2]
        let retention = DuplicateRetention(group: group, selectedPaths: Set(selected.map(\.id)))
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        let plan = try service.prepare(urls: selected.map(\.url), preserving: [retention])
        var count = 0
        let result = try service.execute(plan, confirmed: true, move: { _ in
            count += 1
            XCTAssertEqual(unlink(keeper.id), 0)
        })
        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testSelectingEveryDuplicateCopyIsRejectedByTheService() throws {
        let group = try duplicateFixture()
        let retention = DuplicateRetention(group: group, selectedPaths: Set(group.files.map(\.id)))
        XCTAssertThrowsError(try TrashService(policy: SafetyPolicy(home: fixture)).prepare(urls: group.files.map(\.url), preserving: [retention]))
    }

    func testTrashReviewCanBeCancelledWithoutMovingFiles() throws {
        let file = try write("folder/a.bin")
        let flag = CancellationFlag(); flag.cancel()
        XCTAssertThrowsError(try TrashService(policy: SafetyPolicy(home: fixture)).prepare(urls: [file.deletingLastPathComponent()], cancellation: flag)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testInspectionOnlyReasonsIncludeOwnershipAndCloudPlaceholders() throws {
        let file = try write("a.bin")
        var value = stat()
        XCTAssertEqual(lstat(file.path, &value), 0)
        value.st_uid = getuid() + 1
        let policy = SafetyPolicy(home: fixture)
        XCTAssertNotNil(policy.rejectionReason(for: FileRecord(url: file, metadata: FileMetadata.from(value))))
        value.st_uid = getuid(); value.st_flags |= UInt32(SF_DATALESS)
        XCTAssertNotNil(policy.rejectionReason(for: FileRecord(url: file, metadata: FileMetadata.from(value))))
    }

    func testNativeDuplicateTrashPreservesTheRetainedCopy() throws {
        let group = try duplicateFixture()
        let selected = group.files[0], keeper = group.files[1]
        let retention = DuplicateRetention(group: group, selectedPaths: [selected.id])
        let service = TrashService(policy: SafetyPolicy(home: fixture))
        var destination: NSURL?
        defer { if let destination { try? FileManager.default.removeItem(at: destination as URL) } }
        let result = try service.execute(try service.prepare(urls: [selected.url], preserving: [retention]), confirmed: true, move: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        })
        XCTAssertEqual(result.moved, [selected.url])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try FileMetadata.read(keeper.url), keeper.metadata)
    }
}
