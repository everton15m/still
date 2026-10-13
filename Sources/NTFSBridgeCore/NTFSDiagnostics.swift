import Foundation

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
    public static func decode(_ data: Data, exitStatus: Int32) throws -> NTFSSafetyReport {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              value.code == exitStatus,
              ["passed", "volume_open", "volume_flags", "hiber_file", "journal_open", "journal_state", "cached_journal", "metadata_close", "volume_close"].contains(value.stage),
              (value.code == 0) == (value.stage == "passed") else {
            throw BridgeError("The installed safety checker returned an unreadable report. Update the helper package before retrying.")
        }
        return value
    }
    public var explanation: String {
        if code == 0 { return "The known NTFS safety checks passed. Write access has not been enabled, and this check is not a complete filesystem audit." }
        switch stage {
        case "cached_journal":
            return "NTFS-3G rejected the journal's cached-state metadata. This can also follow an unclean disconnect and does not prove that Windows is currently hibernated. Connecting to Windows alone may not clear it. Back up readable files before a Windows filesystem check, then safely eject."
        case "hiber_file" where code == 14:
            return "The NTFS hibernation-file check detected a saved or incomplete Windows state. Resume the Windows session and fully shut down before reconnecting."
        case "volume_flags":
            return "NTFS has dirty or maintenance flags set. Back up readable files before checking the filesystem in Windows."
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
        return "NTFSBridge read-only diagnostic\nExit code: \(code)\nCheck: \(stage)\nNTFS version: \(version)\nVolume flags: \(flags)\nHibernation check: \(hiber)\nJournal version: \(journal)\nJournal clean: \(clean)\nMetadata cleanup error: \((cleanupError ?? 0) == 0 ? "no" : "yes")"
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
