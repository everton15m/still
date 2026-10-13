import AppKit
import SwiftUI
import StorageCore
import UserNotifications
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var capacity: DiskCapacity?
    @Published var capacityError: String?
    @Published var result: ScanResult?
    @Published private(set) var protectionReasons: [String: String] = [:]
    @Published var progress: ScanProgress?
    @Published var scanning = false
    @Published var comparing = false
    @Published var compareProgress = ""
    @Published var duplicateResult: DuplicateResult?
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var exploreURL = URL(fileURLWithPath: "/", isDirectory: true)
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var trashPlan: TrashPlan?
    @Published var preparingTrash = false
    @Published var trashing = false
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var showIssues = false
    @Published var alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled")
    @Published var thresholdGB: Int = UserDefaults.standard.object(forKey: "thresholdGB") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(thresholdGB, forKey: "thresholdGB"); refreshCapacity() }
    }
    let policy = SafetyPolicy()
    private var cancellation: CancellationFlag?
    private var generation = UUID()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var gate = LowStorageGate(warned: UserDefaults.standard.bool(forKey: "lowStorageWarned"))
    private var checkingAlert = false
    private var fileIndex: [String: FileRecord] = [:]
    private let notificationDelegate = DashboardNotificationDelegate()
    var busy: Bool { scanning || comparing || preparingTrash || trashing }
    var canCancel: Bool { scanning || comparing || preparingTrash }
    var threshold: Int64 { Int64(thresholdGB) * 1_000_000_000 }
    var isLow: Bool { capacity.map { $0.available < threshold } ?? false }

    init() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        let action = UNNotificationAction(identifier: "OPEN_CLEANUP", title: "Open cleanup dashboard", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "LOW_STORAGE", actions: [action], intentIdentifiers: [])])
        Task { notificationStatus = await center.notificationSettings().authorizationStatus }
        refreshCapacity()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCapacity() }
        }
        timer?.tolerance = 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCapacity() }
        }
    }

    func refreshCapacity() {
        Task {
            let reading = await Task.detached(priority: .utility) { () -> Result<DiskCapacity, Error> in
                Result { try DiskCapacity.read() }
            }.value
            switch reading {
            case .success(let value):
                capacity = value; capacityError = nil
                await checkAlert(value)
            case .failure(let error): capacityError = error.localizedDescription
            }
        }
    }

    private func checkAlert(_ value: DiskCapacity) async {
        guard !checkingAlert else { return }
        checkingAlert = true
        defer { checkingAlert = false }
        // Keep recovery hysteresis accurate even while permission is disabled.
        let wasWarned = gate.warned
        let shouldSend = gate.shouldNotify(available: value.available, threshold: threshold)
        if shouldSend {
            let center = UNUserNotificationCenter.current()
            notificationStatus = await center.notificationSettings().authorizationStatus
            guard alertsEnabled && notificationStatus == .authorized else {
                gate.deliveryFailed(); UserDefaults.standard.set(false, forKey: "lowStorageWarned"); return
            }
            let content = UNMutableNotificationContent()
            content.title = "A little room would help"
            content.body = "Your startup disk has \(formatBytes(value.available)) available. Open Still to review cleanup opportunities."
            content.categoryIdentifier = "LOW_STORAGE"
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "still-low-storage", content: content, trigger: nil))
            } catch { gate.deliveryFailed(); errorMessage = "Could not deliver the storage notification: \(error.localizedDescription)" }
        }
        if gate.warned != wasWarned { UserDefaults.standard.set(gate.warned, forKey: "lowStorageWarned") }
    }

    func setAlerts(_ enabled: Bool) {
        Task {
            do {
                if enabled {
                    let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    alertsEnabled = allowed
                    if !allowed { errorMessage = "Allow Still in System Settings → Notifications to receive low-storage alerts." }
                } else { alertsEnabled = false }
                UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled")
                refreshCapacity()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
        } catch { errorMessage = "Login item could not be changed: \(error.localizedDescription)" }
    }

    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = policy.home
        panel.message = "Choose a folder on your startup disk. Still respects macOS privacy permissions."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let device = try FileMetadata.read(url).identity.device
                let startup = try FileMetadata.read(DiskCapacity.startupURL).identity.device
                guard device == startup else { throw StorageFailure.message("Choose a folder on the internal startup data volume. External volumes are not supported yet.") }
                scan(url)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func scan(_ url: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        guard !busy else { return }
        let flag = CancellationFlag(), id = UUID()
        generation = id; cancellation = flag; scanning = true
        progress = nil; result = nil; suggestions = []; duplicateResult = nil
        fileIndex = [:]; protectionReasons = [:]
        exploreURL = url; statusMessage = nil
        Task {
            do {
                let configuration = ScanConfiguration(root: url)
                let policy = self.policy
                let output = try await Task.detached(priority: .utility) { [self] in
                    let scanned = try StorageScanner().scan(configuration: configuration, cancellation: flag, progress: { update in
                        Task { @MainActor [self] in
                            guard self.generation == id, self.scanning else { return }
                            self.progress = update
                        }
                    })
                    var protected: [String: String] = [:]
                    for file in scanned.files {
                        if let reason = policy.rejectionReason(for: file) { protected[file.id] = reason }
                    }
                    return (scanned, protected, Dictionary(uniqueKeysWithValues: scanned.files.map { ($0.id, $0) }))
                }.value
                guard generation == id else { return }
                let scanned = output.0
                protectionReasons = output.1; fileIndex = output.2
                result = scanned; exploreURL = scanned.root
                suggestions = SuggestionEngine().suggestions(from: scanned, policy: policy)
                statusMessage = scanned.cancelled ? "Scan stopped. Showing inspected files only." : "Scan finished. Sizes are estimates of allocated blocks."
            } catch { errorMessage = "Scan could not complete: \(error.localizedDescription)" }
            if generation == id { scanning = false; cancellation = nil; refreshCapacity() }
        }
    }

    func cancel() { cancellation?.cancel() }

    func rescanCurrentFolder() { scan(result == nil ? URL(fileURLWithPath: "/", isDirectory: true) : exploreURL) }

    func file(at path: String) -> FileRecord? { fileIndex[path] }

    func findDuplicates() {
        guard let result, !busy else { return }
        let files = result.files.filter { protectionReasons[$0.id] == nil }
        let flag = CancellationFlag()
        cancellation = flag; comparing = true; compareProgress = "Preparing comparisons…"; duplicateResult = nil
        Task {
            let duplicates = await Task.detached(priority: .utility) { [self] in
                DuplicateDetector().find(in: files, cancellation: flag) { done, total in
                    // Hashing can finish many files quickly; only enqueue occasional UI changes.
                    if done % 20 == 0 || done == total {
                        Task { @MainActor [self] in self.compareProgress = "Compared \(done) of \(total) candidates" }
                    }
                }
            }.value
            duplicateResult = duplicates; comparing = false; cancellation = nil
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func requestDuplicateTrash(groups: [DuplicateGroup], selected: Set<String>) {
        let relevant = groups.filter { $0.files.contains { selected.contains($0.id) } }
        let retentions = relevant.map { DuplicateRetention(group: $0, selectedPaths: selected) }
        requestTrash(retentions.flatMap(\.selectedURLs), preserving: retentions)
    }

    func requestTrash(_ urls: [URL], preserving retentions: [DuplicateRetention] = []) {
        guard !busy, let result else { return }
        let flag = CancellationFlag()
        cancellation = flag
        preparingTrash = true
        let service = TrashService(policy: policy)
        var expected: [String: FileMetadata] = [:]
        for url in urls {
            if let file = fileIndex[url.path] { expected[url.path] = file.metadata }
            else if let info = result.directories[url.path]?.metadata { expected[url.path] = info }
        }
        Task {
            do {
                let plan = try await Task.detached(priority: .utility) {
                    try service.prepare(urls: urls, expected: expected, preserving: retentions, cancellation: flag)
                }.value
                if !flag.isCancelled { trashPlan = plan }
                else { statusMessage = "Review cancelled. No files were moved." }
            } catch is CancellationError { statusMessage = "Review cancelled. No files were moved." }
              catch { errorMessage = error.localizedDescription }
            preparingTrash = false; cancellation = nil
        }
    }

    func confirmTrash() {
        guard let plan = trashPlan else { return }
        trashPlan = nil; trashing = true
        let service = TrashService(policy: policy)
        Task {
            do {
                let outcome = try await Task.detached(priority: .utility) { try service.execute(plan, confirmed: true) }.value
                if !outcome.moved.isEmpty {
                    removeFromResults(outcome.moved)
                    statusMessage = "Moved \(outcome.moved.count) item(s) to Trash. Space is reclaimed after you empty Trash in Finder; snapshots may retain blocks."
                }
                if !outcome.failures.isEmpty { errorMessage = outcome.failures.map { "\($0.url.path): \($0.reason)" }.joined(separator: "\n\n") }
            } catch { errorMessage = error.localizedDescription }
            trashing = false; refreshCapacity()
        }
    }

    private func removeFromResults(_ urls: [URL]) {
        guard var scan = result else { return }
        for url in urls {
            let folder = scan.directories[url.path]
            let file = scan.files.first { $0.url == url }
            let allocated = folder?.allocatedBytes ?? file?.metadata.allocatedBytes ?? 0
            let logical = folder?.logicalBytes ?? file?.metadata.logicalBytes ?? 0
            let count = folder?.fileCount ?? (file == nil ? 0 : 1)
            for key in scan.directories.keys where key != url.path && isWithin(url.path, key) {
                guard var directory = scan.directories[key] else { continue }
                directory.allocatedBytes = max(0, directory.allocatedBytes - allocated)
                directory.logicalBytes = max(0, directory.logicalBytes - logical)
                directory.fileCount = max(0, directory.fileCount - count)
                scan.directories[key] = directory
            }
            scan.directories = scan.directories.filter { !isWithin($0.key, url.path) }
            scan.files.removeAll { isWithin($0.url.path, url.path) }
        }
        result = scan; duplicateResult = nil
        for url in urls {
            fileIndex = fileIndex.filter { !isWithin($0.key, url.path) }
            protectionReasons = protectionReasons.filter { !isWithin($0.key, url.path) }
        }
        if scan.directories[exploreURL.path] == nil { exploreURL = scan.root }
        suggestions = SuggestionEngine().suggestions(from: scan, policy: policy)
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

private final class DashboardNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { NSApp.activate(ignoringOtherApps: true); DashboardOpener.open() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
enum DashboardOpener {
    static var action: (() -> Void)?
    static func open() { action?() }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}
