import Foundation
import Darwin
import DiskArbitration
import NTFSBridgeCore
import os

let logger = Logger(subsystem: "org.ntfsbridge.app", category: "Mount")

final class AutomountGuard {
    let session: DASession
    let device: String
    var blocking = true
    init(device: String) throws {
        self.device = device
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw BridgeError("Disk Arbitration is unavailable.") }
        self.session = session
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            guard let context, let name = DADiskGetBSDName(disk) else { return nil }
            let guardObject = Unmanaged<AutomountGuard>.fromOpaque(context).takeUnretainedValue()
            if guardObject.blocking && String(cString: name) == guardObject.device {
                return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), "NTFSBridge is checking this volume" as CFString))
            }
            return nil
        }, Unmanaged.passUnretained(self).toOpaque())
        DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    deinit { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }
}

final class Operations: NTFSDiagnosticOperations {
    let device: String
    let uuid: String
    let registryID: UInt64
    let uid: uid_t
    let gid: gid_t
    let path: String
    let automount: AutomountGuard
    init(device: String, uuid: String, uid: uid_t, gid: gid_t, registryID: UInt64) throws {
        self.device = device; self.uuid = uuid; self.uid = uid; self.gid = gid; self.registryID = registryID
        path = "/Volumes/NTFSBridge-\(device)-\(uuid)"
        automount = try AutomountGuard(device: device)
    }
    func identityInfo() throws -> [String: Any] {
        let info = try Command.volumeInfo(device)
        guard DeviceIdentity.registryID(device) == registryID, info["DeviceIdentifier"] as? String == device,
              (info["VolumeUUID"] as? String)?.uppercased() == uuid.uppercased() else {
            throw BridgeError("The drive was disconnected or replaced. No further device operation was performed.")
        }
        return info
    }
    func validate() throws {
        let volume = Volume(info: try identityInfo())
        guard volume.writeEligibility == nil else { throw BridgeError(volume.writeEligibility!) }
        let mounts = MountRecord.current().filter { $0.source == "/dev/\(device)" }
        guard mounts.count <= 1, !mounts.contains(where: { $0.writable }) else {
            throw BridgeError("A writable or conflicting mount already exists. It was left in place.")
        }
    }
    func unmount() throws {
        if MountRecord.current().contains(where: { $0.source == "/dev/\(device)" }) {
            let result = try Command.run("/usr/sbin/diskutil", ["unmount", device])
            guard result.status == 0 else { throw BridgeError("The volume is busy. Close open files and Finder windows before retrying.") }
        }
        guard !MountRecord.current().contains(where: { $0.source == "/dev/\(device)" }) else { throw BridgeError("macOS still reports the volume as mounted.") }
    }
    func readOnlyReport() throws -> NTFSSafetyReport {
        let result = try Command.run(DriverLayout.checker, ["--report", "/dev/\(device)"])
        return try NTFSSafetyReport.decode(result.output, exitStatus: result.status)
    }
    func probe() throws -> Int32 {
        let report = try readOnlyReport()
        guard report.code == 0 else { throw BridgeError(report.explanation + "\n\n" + report.details) }
        // The read-only report is sufficient preflight. The actual driver
        // performs its own checks when the user-authorized mount begins.
        return 0
    }
    func mount() throws {
        guard !MountRecord.current().contains(where: { $0.source == "/dev/\(device)" || $0.path == path }) else { throw BridgeError("A competing mount appeared during the safety check.") }
        if FileManager.default.fileExists(atPath: path) {
            try SecurePath.requireRootOwned(path)
            guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else { throw BridgeError("The reserved mount folder is not empty.") }
        } else {
            try SecurePath.requireRootOwned("/Volumes")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let options = "rw,norecover,nosuid,nodev,noexec,backend=fskit,local,allow_other,default_permissions,uid=\(uid),gid=\(gid),umask=077,windows_names,fsname=/dev/\(device),volname=NTFSBridge-\(device)"
        automount.blocking = false
        let result = try Command.run(DriverLayout.driver, ["/dev/\(device)", path, "-o", options])
        guard result.status == 0 else {
            // Do not surface raw driver output; it can contain private filenames.
            throw BridgeError("The FSKit write mount failed (code \(result.status)). Check that the macFUSE FSKit extension is enabled in System Settings.")
        }
    }
    func verify() throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let records = MountRecord.current().filter { $0.source == "/dev/\(device)" }
            if records.count == 1, records[0].verifies(device: device, path: path) {
                // statfs verifies actual mounted flags; no test file is written.
                let check = try Command.volumeInfo(device)
                guard DeviceIdentity.registryID(device) == registryID, (check["VolumeUUID"] as? String)?.uppercased() == uuid.uppercased() else { throw BridgeError("Mounted device identity could not be verified.") }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw BridgeError("Write access could not be verified against the macOS mount table.")
    }
    func restoreReadOnly() throws {
        _ = try identityInfo()
        automount.blocking = false
        let mounts = MountRecord.current().filter { $0.source == "/dev/\(device)" }
        if mounts.count == 1 && mounts[0].isNativeReadOnlyNTFS(device: device, excluding: path) { return }
        if !mounts.isEmpty {
            let result = try Command.run("/usr/sbin/diskutil", ["unmount", device])
            guard result.status == 0 else { throw BridgeError("The failed mount is busy and could not be unmounted. Use Finder to eject it; do not pull the cable.") }
        }
        let result = try Command.run("/usr/sbin/diskutil", ["mount", "readOnly", device])
        let restored = MountRecord.current().filter { $0.source == "/dev/\(device)" }
        guard result.status == 0, restored.count == 1, restored[0].isNativeReadOnlyNTFS(device: device, excluding: path) else {
            throw BridgeError("macOS could not restore a verified read-only mount.")
        }
        // rmdir refuses nonempty directories atomically; never recurse into a mount.
        _ = rmdir(path)
    }
}

func main() throws {
    let args = CommandLine.arguments
    guard args.count == 6, ["enable", "diagnose"].contains(args[1]), InputValidation.device(args[2]), InputValidation.uuid(args[3]),
          let requestedUID = uid_t(args[4]), requestedUID >= 501, let registryID = UInt64(args[5]), registryID > 0 else { throw BridgeError("Invalid helper arguments.") }
    guard getuid() == 0 else { throw BridgeError("Administrator authorization is required.") }
    var console = stat()
    guard stat("/dev/console", &console) == 0, console.st_uid == requestedUID,
          let user = getpwuid(requestedUID) else { throw BridgeError("The active console user changed. Retry from your logged-in desktop.") }
    let gid = user.pointee.pw_gid
    for component in [DriverLayout.helper, DriverLayout.driver, DriverLayout.checker, DriverLayout.probe, DriverLayout.root + "/Driver/lib/libfuse.2.dylib", DriverLayout.fuse] {
        try SecurePath.requireRootOwned(component)
    }
    guard DriverLayout.fuseVersion.map(DriverLayout.supportsFUSEVersion) == true else {
        throw BridgeError("Install macFUSE 5.x, version 5.4.0 or newer, before enabling writes. Other major versions require an updated app.")
    }
    // Check all macFUSE files and directories, resolving legitimate framework
    // symlinks only when their targets remain in this protected installation.
    let fuseURL = URL(fileURLWithPath: DriverLayout.fuse)
    guard let enumerator = FileManager.default.enumerator(at: fuseURL, includingPropertiesForKeys: nil) else { throw BridgeError("macFUSE installation could not be inspected.") }
    for case let url as URL in enumerator {
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(DriverLayout.fuse + "/") else { throw BridgeError("macFUSE contains a link outside its installation.") }
        try SecurePath.requireRootOwned(resolved)
    }
    let signature = try Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", DriverLayout.fuse])
    guard signature.status == 0 else { throw BridgeError("macFUSE's code signature could not be verified. Install an official release.") }
    let lockPath = DriverLayout.root + "/Locks/\(args[2]).lock"
    try SecurePath.requireRootOwned(DriverLayout.root + "/Locks")
    let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw BridgeError("The mount lock could not be opened.") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError("Another NTFSBridge operation is already working on this drive.") }
    let operations = try Operations(device: args[2], uuid: args[3], uid: requestedUID, gid: gid, registryID: registryID)
    if args[1] == "diagnose" {
        let report = try NTFSDiagnosticTransaction.check(using: operations)
        let data = try JSONEncoder().encode(report)
        print(String(decoding: data, as: UTF8.self))
        return
    }
    try MountTransaction.enable(using: operations)
    logger.info("Verified write mount for device \(args[2], privacy: .public)")
    print("Verified write mount")
}

do { try main() }
catch {
    logger.error("Mount operation failed")
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
