import Foundation
import Darwin

public protocol MountOperations {
    func validate() throws
    func unmount() throws
    func probe() throws -> Int32
    func mount() throws
    func verify() throws
    func restoreReadOnly() throws
}

public enum MountTransaction {
    public static func enable(using operations: MountOperations) throws {
        try operations.validate()
        try operations.unmount()
        do {
            // Revalidate identity after unmounting, before opening the raw device.
            try operations.validate()
            let status = try operations.probe()
            guard status == 0 else { throw BridgeError(ProbeFailure.message(status)) }
            try operations.validate()
            try operations.mount()
            try operations.verify()
        } catch {
            do { try operations.restoreReadOnly() }
            catch let fallbackError {
                throw BridgeError("\(error.localizedDescription) Read-only restoration also failed: \(fallbackError.localizedDescription) Reconnect the drive only after checking its current status.")
            }
            throw BridgeError("\(error.localizedDescription) macOS read-only access was restored.")
        }
    }
}

public enum DriverLayout {
    public static let root = "/Library/Application Support/NTFSBridge"
    public static let helper = root + "/NTFSBridgeHelper"
    public static let driver = root + "/Driver/bin/ntfs-3g"
    public static let checker = root + "/Driver/bin/ntfsbridge-check"
    public static let probe = root + "/Driver/bin/ntfs-3g.probe"
    public static var diagnosticsInstalled: Bool {
        FileManager.default.contents(atPath: root + "/Version").flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) == "0.1.4"
    }
    public static let fuse = "/Library/Filesystems/macfuse.fs"
    public static func supportsFUSEVersion(_ version: String) -> Bool {
        version.range(of: "\\A5\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil && version.compare("5.4.0", options: .numeric) != .orderedAscending
    }
    public static var fuseVersion: String? {
        guard let data = FileManager.default.contents(atPath: fuse + "/Contents/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
    public static var installed: Bool {
        [helper, driver, checker, probe, fuse].allSatisfy { FileManager.default.fileExists(atPath: $0) }
            && fuseVersion.map(supportsFUSEVersion) == true
    }
}

public enum SecurePath {
    /// Checks every ancestor using lstat; refuses symlinks, non-root ownership,
    /// group/other writable paths, and ACLs granting additional access.
    public static func requireRootOwned(_ path: String) throws {
        var current = URL(fileURLWithPath: path).standardized.path
        while current != "/" {
            var value = stat()
            guard lstat(current, &value) == 0, value.st_uid == 0,
                  value.st_mode & 0o022 == 0, value.st_mode & S_IFMT != S_IFLNK else {
                throw BridgeError("An installed component is missing or has unsafe ownership: \(current). Reinstall the helper package.")
            }
            if let acl = acl_get_file(current, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else {
                    throw BridgeError("An installed component has an unexpected ACL: \(current).")
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
