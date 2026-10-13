import Foundation
import Darwin

public struct NTFSSafetyReport: Codable, Equatable, Sendable {
    public let schema: Int
    public let code: Int32
    public let stage: String
    public let volumeFlags: Int
    public let ntfsMajor: Int
    public let ntfsMinor: Int
    public let hiberCode: Int
    public let logValid: Int
    public let logClean: Int
    public let logMajor: Int
    public let logMinor: Int
    public let cleanupError: Int?
    public let osError: Int?
    public let ioOperation: String?
    public let deviceOpened: Int?
    public let writeBlocked: Int?
    public static func decode(_ data: Data, exitStatus: Int32) throws -> NTFSSafetyReport {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              value.code == exitStatus,
              ["passed", "volume_open", "volume_flags", "hiber_file", "journal_open", "journal_state", "cached_journal", "metadata_close", "volume_close"].contains(value.stage),
              (value.code == 0) == (value.stage == "passed") else {
            throw BridgeError("The installed safety checker returned an unreadable report. Update the helper package before retrying.")
        }
        guard value.osError.map({ (0...255).contains($0) }) ?? true,
              value.deviceOpened.map({ [0, 1].contains($0) }) ?? true,
              value.writeBlocked.map({ [0, 1].contains($0) }) ?? true,
              value.ioOperation.map({ ["none", "device_stat", "device_open", "device_open_or_lock", "device_lock", "device_read", "boot_read", "volume_metadata", "write_blocked"].contains($0) }) ?? true else {
            throw BridgeError("The installed safety checker returned invalid device-access details.")
        }
        return value
    }
    public var explanation: String {
        if code == 0 { return "The known NTFS safety checks passed. Write access has not been enabled, and this check is not a complete filesystem audit." }
        switch stage {
        case "volume_open":
            if (osError == Int(EPERM) || osError == Int(EACCES)),
               ["device_stat", "device_open", "device_open_or_lock", "device_lock", "device_read", "boot_read"].contains(ioOperation ?? "") {
                return "macOS denied read-only access while opening the NTFS volume. The hibernation and journal checks did not run. Administrator authorization does not override macOS privacy restrictions; this error can involve permissions or privacy settings. It is not evidence that Windows is hibernated."
            }
            if code == 14 {
                return "The NTFS library could not open the volume for read-only inspection. The hibernation and journal checks did not run. This older report does not preserve the macOS error, so code 14 alone cannot identify the cause. Update the helper and check again."
            }
            return "The NTFS library could not open or load the volume for read-only inspection. The hibernation and journal checks did not run. See the device-access details below; this result does not establish a hibernation or cached-journal problem."
        case "cached_journal":
            return "NTFS-3G rejected the journal's cached-state metadata. This can also follow an unclean disconnect and does not prove that Windows is currently hibernated. Connecting to Windows alone may not clear it. Back up readable files before a Windows filesystem check, then safely eject."
        case "hiber_file" where code == 14:
            return "The NTFS hibernation-file check detected a saved or incomplete Windows state. Resume the Windows session and fully shut down before reconnecting."
        case "volume_flags":
            if volumeFlags >= 0 && volumeFlags & 0x0001 != 0 {
                return "The NTFS dirty bit is set. Back up readable files before checking the filesystem in Windows. The hibernation and journal checks have not run."
            }
            if volumeFlags >= 0 && volumeFlags & ~0xC03F != 0 {
                let unknown = String(format: "0x%04X", volumeFlags & ~0xC03F)
                return "The checker does not interpret volume flags \(unknown). Its conservative policy refuses write access when any volume flag is set. The dirty bit is not set; this result does not establish corruption or hibernation. The hibernation and journal checks have not run."
            }
            return "NTFS has nonzero volume flags that this checker's conservative policy refuses. The dirty bit is not set. The hibernation and journal checks have not run; no repair has been performed."
        case "journal_state", "journal_open":
            return "The NTFS journal could not be verified as clean and supported. Back up readable files before repair."
        default: return ProbeFailure.message(code)
        }
    }
    public var details: String {
        let flags = volumeFlags < 0 ? "unavailable" : String(format: "0x%04X", volumeFlags)
        let version = ntfsMajor < 0 ? "unavailable" : "\(ntfsMajor).\(ntfsMinor)"
        let journal = logMajor < 0 ? "unavailable or empty" : "\(logMajor).\(logMinor)"
        let clean = logClean < 0 ? "not checked" : logClean == 1 ? "yes" : "no"
        let hiber = hiberCode < 0 ? "not checked" : hiberCode == 0 ? "clear" : "refused (\(hiberCode))"
        let systemError = osError.map { $0 == 0 ? "none" : "\($0) (\(String(cString: strerror(Int32($0)))))" } ?? "not recorded by this helper"
        let opened = deviceOpened.map { $0 == 1 ? "completed" : "failed" } ?? "not recorded"
        let blocked = writeBlocked.map { $0 == 1 ? "yes; refused" : "no" } ?? "not recorded"
        let dirty = volumeFlags < 0 ? "not checked" : volumeFlags & 1 != 0 ? "set" : "not set"
        return "NTFSBridge read-only diagnostic\nExit code: \(code)\nCheck: \(stage)\nmacOS errno: \(systemError)\nI/O operation: \(ioOperation ?? "not recorded")\nRead-only device open/lock: \(opened)\nWrite attempted: \(blocked)\nNTFS version: \(version)\nVolume flags: \(flags)\nNTFS dirty bit: \(dirty)\nHibernation check: \(hiber)\nJournal version: \(journal)\nJournal clean: \(clean)\nMetadata cleanup error: \((cleanupError ?? 0) == 0 ? "no" : "yes")"
    }
}

public protocol NTFSDiagnosticOperations: MountOperations {
    func readOnlyReport() throws -> NTFSSafetyReport
}

public enum NTFSDiagnosticTransaction {
    public static func check(using operations: NTFSDiagnosticOperations) throws -> NTFSSafetyReport {
        try operations.validate()
        try operations.unmount()
        let report: NTFSSafetyReport
        do {
            try operations.validate()
            report = try operations.readOnlyReport()
        } catch {
            do { try operations.restoreReadOnly() }
            catch let fallbackError { throw BridgeError("\(error.localizedDescription) Read-only restoration failed: \(fallbackError.localizedDescription)") }
            throw BridgeError("\(error.localizedDescription) Read-only access was restored.")
        }
        try operations.restoreReadOnly()
        return report
    }
}
