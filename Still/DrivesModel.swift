import AppKit
import Foundation
import NTFSBridgeCore
import os

@MainActor
final class DrivesModel: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var busyDevice: String?
    @Published var refreshing = false
    @Published var notice: Notice?
    @Published var setupPresented = false
    @Published var diagnostic: DiagnosticNotice?
    struct DiagnosticNotice: Identifiable {
        let id = UUID()
        let report: NTFSSafetyReport
    }
    @Published var ready = (DriverLayout.installed && DriverLayout.diagnosticsInstalled)
    private var observer: DiskObserver?
    private var timer: Timer?
    private var expectedRemovals = Set<String>()
    private let logger = Logger(subsystem: "org.stillapp.Still", category: "App")
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    init() {
        observer = DiskObserver { [weak self] in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 15
        refresh()
    }
    func refresh() {
        guard !refreshing, busyDevice == nil else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try DiskInventory.scan() } }.value
            refreshing = false; ready = (DriverLayout.installed && DriverLayout.diagnosticsInstalled)
            switch result {
            case .success(let updated):
                let removedWritable = volumes.filter { old in old.isNTFS && old.writable == true && !updated.contains(where: { $0.device == old.device && $0.uuid == old.uuid }) && !expectedRemovals.contains(old.wholeDisk) }
                volumes = updated
                expectedRemovals = expectedRemovals.filter { disk in updated.contains { $0.wholeDisk == disk } }
                if !removedWritable.isEmpty {
                    notice = Notice(title: "Writable drive disconnected", message: "A writable NTFS drive disappeared without a confirmed eject. Recent writes may be incomplete. Check the drive in Windows before enabling write access again.")
                }
            case .failure:
                notice = Notice(title: "Could not refresh drives", message: "macOS could not read external drive information. Reconnect the drive and check Disk Utility.")
            }
        }
    }
    func open(_ volume: Volume) {
        guard let path = volume.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    func enable(_ volume: Volume) {
        guard busyDevice == nil, let uuid = volume.uuid else { return }
        guard volume.registryID != nil else {
            notice = Notice(title: "Drive identity unavailable", message: "macOS could not identify this physical drive attachment. Reconnect and refresh before enabling writes."); return
        }
        guard ready else { setupPresented = true; return }
        guard volume.writeEligibility == nil else {
            notice = Notice(title: "Write access unavailable", message: volume.writeEligibility!); return
        }
        busyDevice = volume.device
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                Result {
                    _ = try AdministratorHelper.invoke("enable", volume: volume)
                    let path = "/Volumes/NTFSBridge-\(volume.device)-\(uuid)"
                    guard MountRecord.current().contains(where: { $0.verifies(device: volume.device, path: path) }) else { throw BridgeError("The helper completed, but a writable mount is no longer present. Refresh the drive status.") }
                }
            }.value
            busyDevice = nil
            if case .failure(let error) = result { notice = Notice(title: "Write access was not enabled", message: error.localizedDescription) }
            logger.info("Write access request completed")
            refresh()
        }
    }
    func check(_ volume: Volume) {
        guard busyDevice == nil else { return }
        guard DriverLayout.diagnosticsInstalled else {
            notice = Notice(title: "Helper update required", message: "The read-only diagnostic needs helper 0.1.5. Use Still’s Connected drives → Set Up NTFS → Open Helper Installer to install the bundled update. macOS asks for administrator approval.")
            return
        }
        busyDevice = volume.device
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result {
                let output = try AdministratorHelper.invoke("diagnose", volume: volume)
                guard let data = output.data(using: .utf8),
                      let value = try? JSONDecoder().decode(NTFSSafetyReport.self, from: data) else { throw BridgeError("The helper returned an unreadable diagnostic.") }
                return try NTFSSafetyReport.decode(data, exitStatus: value.code)
            } }.value
            busyDevice = nil
            switch result {
            case .success(let report): diagnostic = DiagnosticNotice(report: report)
            case .failure(let error): notice = Notice(title: "Could not check NTFS", message: error.localizedDescription)
            }
            refresh()
        }
    }
    func eject(_ volume: Volume) {
        guard busyDevice == nil else { return }
        guard volume.registryID != nil else {
            notice = Notice(title: "Drive identity unavailable", message: "Refresh the drive status before ejecting, or eject through Finder."); return
        }
        busyDevice = volume.device
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result {
                let current = Volume(info: try Command.diskInfo(volume.device))
                guard current.external, current.wholeDisk == volume.wholeDisk, current.uuid == volume.uuid, DeviceIdentity.registryID(volume.device) == volume.registryID else { throw BridgeError("The drive changed. Refresh before ejecting.") }
                let result = try Command.run("/usr/sbin/diskutil", ["eject", current.wholeDisk])
                guard result.status == 0, !MountRecord.current().contains(where: { $0.source == "/dev/\(current.device)" }) else { throw BridgeError("The drive could not be safely ejected. Close files and applications using every volume on this drive, then retry.") }
            } }.value
            busyDevice = nil
            switch result {
            case .success:
                expectedRemovals.insert(volume.wholeDisk)
                notice = Notice(title: "Drive ejected", message: "macOS confirmed the eject. You can disconnect the drive.")
            case .failure(let error): notice = Notice(title: "Eject failed", message: error.localizedDescription)
            }
            refresh()
        }
    }
    func openHelperInstaller() {
        guard let url = Bundle.main.url(forResource: "NTFSBridgeHelper", withExtension: "pkg") else {
            notice = Notice(title: "Installer not included", message: "The bundled NTFS helper installer is missing. Rebuild Still with the current helper package."); return
        }
        NSWorkspace.shared.open(url)
    }
}

private enum AdministratorHelper {
    static func invoke(_ action: String, volume: Volume) throws -> String {
        try SecurePath.requireRootOwned(DriverLayout.helper)
        guard ["enable", "diagnose"].contains(action), InputValidation.device(volume.device),
              let uuid = volume.uuid, InputValidation.uuid(uuid), let attachment = volume.registryID else {
            throw BridgeError("The drive identity is unavailable. Reconnect and refresh before retrying.")
        }
        let command = "'\(DriverLayout.helper)' \(action) \(volume.device) \(uuid) \(getuid()) \(attachment)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else { throw BridgeError("Administrator authorization could not be prepared.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw BridgeError("Authorization was cancelled. The drive was left unchanged.") }
            let original = error[NSAppleScript.errorMessage] as? String ?? "The operation failed."
            let old = "Windows hibernation or Fast Startup is active. Resume Windows, disable Fast Startup, and fully shut down before reconnecting."
            throw BridgeError(original.replacingOccurrences(of: old, with: ProbeFailure.message(14)))
        }
        return result.stringValue ?? ""
    }
}
