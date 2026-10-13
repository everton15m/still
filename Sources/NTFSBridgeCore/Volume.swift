import Foundation
import Darwin

public struct Volume: Identifiable, Equatable, Sendable {
    public var id: String { device }
    public let device: String
    public let uuid: String?
    public let registryID: UInt64?
    public let wholeDisk: String
    public let name: String
    public let filesystem: String
    public let mountPoint: String?
    public let total: Int64
    public let available: Int64?
    public let external: Bool
    public let physical: Bool
    public let mediaWritable: Bool
    public let encrypted: Bool
    public let writable: Bool?

    public init(info: [String: Any], mount: MountRecord? = nil, registryID: UInt64? = nil) {
        device = info["DeviceIdentifier"] as? String ?? ""
        uuid = info["VolumeUUID"] as? String
        self.registryID = registryID
        wholeDisk = info["ParentWholeDisk"] as? String ?? device
        name = info["VolumeName"] as? String ?? info["MediaName"] as? String ?? device
        let rawKind = info["FilesystemType"] as? String ?? ""
        filesystem = rawKind.isEmpty ? (info["FileSystemPersonality"] as? String ?? "Unknown") : rawKind
        mountPoint = mount?.path ?? (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        total = (info["TotalSize"] as? NSNumber)?.int64Value ?? (info["Size"] as? NSNumber)?.int64Value ?? 0
        available = (info["APFSContainerFree"] as? NSNumber)?.int64Value ?? (info["VolumeFreeSpace"] as? NSNumber)?.int64Value ?? (info["FreeSpace"] as? NSNumber)?.int64Value
        // Missing security metadata is never interpreted as permission to write.
        external = info["Internal"] as? Bool == false
        physical = info["VirtualOrPhysical"] as? String == "Physical"
        mediaWritable = info["WritableMedia"] as? Bool == true
        encrypted = info["Encrypted"] as? Bool == true || info["Encryption"] as? Bool == true || info["Locked"] as? Bool == true || info["GlobalPermissionsEnabled"] as? Bool == false && filesystem.lowercased().contains("bitlocker")
        writable = mount?.writable ?? (info["WritableVolume"] as? Bool)
    }
    public var isNTFS: Bool {
        filesystem.lowercased() == "ntfs" || filesystem.lowercased() == "windows nt file system"
            || (mountPoint?.hasPrefix("/Volumes/NTFSBridge-") == true && (filesystem.lowercased().contains("macfuse") || filesystem.lowercased() == "fskit"))
    }
    public var writeEligibility: String? {
        if !isNTFS { return "This filesystem uses its existing macOS driver." }
        if !external || !physical { return "Only external physical NTFS partitions are supported." }
        if !mediaWritable { return "The device is read-only or its write protection is unknown." }
        if encrypted { return "Unlock encrypted storage with its supported software first." }
        if !InputValidation.device(device) || uuid.map(InputValidation.uuid) != true { return "This volume has no stable identity. Write access is unavailable." }
        return nil
    }
    public var accessLabel: String {
        guard mountPoint != nil else { return "Unmounted" }
        switch writable { case true: return "Read & write"; case false: return "Read-only"; default: return "Access unverified" }
    }
}

public enum InputValidation {
    public static func device(_ value: String) -> Bool { value.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil }
    public static func uuid(_ value: String) -> Bool { UUID(uuidString: value) != nil }
}

public struct MountRecord: Equatable, Sendable {
    public let source: String
    public let path: String
    public let kind: String
    public let writable: Bool
    public init(source: String, path: String, kind: String, writable: Bool) {
        self.source = source; self.path = path; self.kind = kind; self.writable = writable
    }
    public static func current() -> [MountRecord] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard let pointer else { return [] }
        return (0..<Int(count)).map { index in
            var item = pointer[index]
            func decode<T>(_ value: inout T) -> String {
                withUnsafePointer(to: &value) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
            }
            return MountRecord(source: decode(&item.f_mntfromname), path: decode(&item.f_mntonname), kind: decode(&item.f_fstypename), writable: item.f_flags & UInt32(MNT_RDONLY) == 0)
        }
    }
    public func isNativeReadOnlyNTFS(device: String, excluding path: String) -> Bool {
        source == "/dev/\(device)" && self.path != path && kind == "ntfs" && !writable
    }
    public func verifies(device: String, path: String) -> Bool {
        source == "/dev/\(device)" && self.path == path && writable && (kind.lowercased().contains("macfuse") || kind.lowercased() == "fskit")
    }
}

public enum ProbeFailure {
    public static func message(_ code: Int32) -> String {
        switch code {
        case 12: return "The device is not a valid supported NTFS filesystem. Encrypted drives must be unlocked with supported software."
        case 13: return "NTFS is inconsistent or the device has an I/O fault. Back up readable files, then check the drive in Windows."
        case 14: return "NTFS reports Windows hibernation or cached metadata from Fast Startup or an unclean shutdown. Reconnect to Windows, resume any hibernated session, close files, and fully shut down or safely eject before retrying."
        case 15: return "Windows did not cleanly unmount this drive. Check it in Windows and safely eject it before retrying."
        case 16: return "Another process or driver is using this volume. Close files and other NTFS utilities, then retry."
        case 17: return "This RAID configuration is unsupported. Use the system that owns the RAID."
        case 19: return "Permission was denied. Check administrator authorization and macOS privacy permissions."
        default: return "NTFS safety check failed (code \(code)). The volume was not mounted for writing."
        }
    }
}

public struct BridgeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
