import DiskArbitration
import IOKit
import Foundation

public enum DeviceIdentity {
    /// I/O Registry IDs identify this attachment, unlike a volume UUID that can
    /// be cloned or remain identical after a disconnect/reconnect.
    public static func registryID(_ device: String) -> UInt64? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(device)") else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS, id != 0 else { return nil }
        return id
    }
}
