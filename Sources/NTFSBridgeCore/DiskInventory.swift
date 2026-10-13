import Foundation
import DiskArbitration

public enum DiskInventory {
    public static func scan() throws -> [Volume] {
        let result = try Command.run("/usr/sbin/diskutil", ["list", "-plist", "external"])
        guard result.status == 0 else { throw BridgeError("macOS could not list external drives.") }
        let physicalResult = try Command.run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard physicalResult.status == 0 else { throw BridgeError("macOS could not identify external physical drives.") }
        let physicalList = try PropertyListSerialization.propertyList(from: physicalResult.output, format: nil) as? [String: Any]
        let physicalParents = Set((physicalList?["AllDisksAndPartitions"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String })
        let plist = try PropertyListSerialization.propertyList(from: result.output, format: nil)
        var devices = Set<String>()
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let id = dict["DeviceIdentifier"] as? String { devices.insert(id) }
                for child in dict.values { visit(child) }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        visit(plist)
        let mounts = MountRecord.current()
        return devices.sorted().compactMap { device in
            // Do not query whole-disk info from the unprivileged GUI. macOS's
            // info operation attempts low-level raw-device access for whole disks.
            guard InputValidation.device(device), let rawInfo = try? Command.diskInfo(device), DiskMetadata.isPartition(rawInfo) else { return nil }
            guard DiskMetadata.hasExternalPhysicalBacking(rawInfo, physicalParents: physicalParents) else { return nil }
            let parent = rawInfo["ParentWholeDisk"] as? String ?? ""
            let parentInfo: [String: Any] = physicalParents.contains(parent) ? ["DeviceIdentifier": parent, "WholeDisk": true, "Internal": false, "VirtualOrPhysical": "Physical"] : [:]
            let info = DiskMetadata.enrich(rawInfo, parent: parentInfo)
            let content = info["Content"] as? String ?? ""
            if ["EFI", "Apple_APFS", "Apple_Boot"].contains(content) { return nil }
            return Volume(info: info, mount: mounts.first { $0.source == "/dev/\(device)" }, registryID: DeviceIdentity.registryID(device))
        }
    }
}

public final class DiskObserver {
    private let session: DASession
    private let callback: () -> Void
    public init?(onChange: @escaping () -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session; callback = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            guard let context else { return }; Unmanaged<DiskObserver>.fromOpaque(context).takeUnretainedValue().callback()
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in
            guard let context else { return }; Unmanaged<DiskObserver>.fromOpaque(context).takeUnretainedValue().callback()
        }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in
            guard let context else { return }; Unmanaged<DiskObserver>.fromOpaque(context).takeUnretainedValue().callback()
        }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }
    deinit { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
}
