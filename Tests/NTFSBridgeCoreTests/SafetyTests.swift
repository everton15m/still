import XCTest
@testable import NTFSBridgeCore

final class SafetyTests: XCTestCase {
    private var info: [String: Any] { ["DeviceIdentifier": "disk8s1", "ParentWholeDisk": "disk8", "VolumeUUID": "A1234567-1234-1234-1234-123456789ABC", "FilesystemType": "ntfs", "Internal": false, "VirtualOrPhysical": "Physical", "WritableMedia": true, "WritableVolume": false, "MountPoint": "/Volumes/Test"] }
    func testPhysicalBackingExcludesSimulatorDiskImages() {
        let physical: Set<String> = ["disk8"]
        XCTAssertTrue(DiskMetadata.hasExternalPhysicalBacking(info, physicalParents: physical))
        let apfs: [String: Any] = ["ParentWholeDisk": "disk9", "APFSPhysicalStores": [["APFSPhysicalStore": "disk8s2"]]]
        XCTAssertTrue(DiskMetadata.hasExternalPhysicalBacking(apfs, physicalParents: physical))
        let image: [String: Any] = ["ParentWholeDisk": "disk10", "APFSPhysicalStores": [["APFSPhysicalStore": "disk10s1"]]]
        XCTAssertFalse(DiskMetadata.hasExternalPhysicalBacking(image, physicalParents: physical))
        XCTAssertFalse(DiskMetadata.hasExternalPhysicalBacking(["ParentWholeDisk": "disk10"], physicalParents: physical))
    }
    func testCurrentDiskutilPartitionMetadata() {
        var partition = info
        partition["WholeDisk"] = false
        partition.removeValue(forKey: "VirtualOrPhysical")
        XCTAssertTrue(DiskMetadata.isPartition(partition))
        let parent: [String: Any] = ["DeviceIdentifier": "disk8", "WholeDisk": true, "Internal": false, "VirtualOrPhysical": "Physical"]
        XCTAssertNil(Volume(info: DiskMetadata.enrich(partition, parent: parent)).writeEligibility)
        XCTAssertNotNil(Volume(info: partition).writeEligibility)
        var other = parent; other["DeviceIdentifier"] = "disk9"
        XCTAssertNotNil(Volume(info: DiskMetadata.enrich(partition, parent: other)).writeEligibility)
        var virtual = parent; virtual["VirtualOrPhysical"] = "Virtual"
        XCTAssertNotNil(Volume(info: DiskMetadata.enrich(partition, parent: virtual)).writeEligibility)
        var internalDisk = parent; internalDisk["Internal"] = true
        XCTAssertNotNil(Volume(info: DiskMetadata.enrich(partition, parent: internalDisk)).writeEligibility)
        XCTAssertFalse(DiskMetadata.isPartition(parent))
        XCTAssertFalse(DiskMetadata.isPartition(["Internal": false]))
    }
    func testCurrentDiskutilFreeSpace() {
        var ntfs = info; ntfs["FreeSpace"] = Int64(12345)
        XCTAssertEqual(Volume(info: ntfs).available, 12345)
        var apfs = info; apfs["FreeSpace"] = 0; apfs["APFSContainerFree"] = Int64(67890)
        XCTAssertEqual(Volume(info: apfs).available, 67890)
    }
    func testRejectsOlderAndUnknownFUSEVersions() {
        for version in ["5.3.3", "4.10.2", "5.4", "6.0.0", "unknown"] { XCTAssertFalse(DriverLayout.supportsFUSEVersion(version)) }
        for version in ["5.4.0", "5.4.1", "5.10.0"] { XCTAssertTrue(DriverLayout.supportsFUSEVersion(version)) }
    }
    func testRejectsUnsafeAndUnknownMedia() {
        XCTAssertNil(Volume(info: info).writeEligibility)
        for replacement: [String: Any] in [["Internal": true], ["WritableMedia": false], ["VirtualOrPhysical": "Virtual"], ["Encrypted": true], ["FilesystemType": "exfat"], ["VolumeUUID": "invalid"]] {
            var item = info; item.merge(replacement) { _, new in new }
            XCTAssertNotNil(Volume(info: item).writeEligibility)
        }
        var item = info; item.removeValue(forKey: "WritableMedia")
        XCTAssertNotNil(Volume(info: item).writeEligibility)
    }
    func testMountTableOverridesClaimedWriteAccess() {
        var item = info; item["WritableVolume"] = true
        let readonly = MountRecord(source: "/dev/disk8s1", path: "/Volumes/Test", kind: "ntfs", writable: false)
        XCTAssertEqual(Volume(info: item, mount: readonly).writable, false)
        XCTAssertFalse(readonly.verifies(device: "disk8s1", path: "/Volumes/Test"))
        let writable = MountRecord(source: "/dev/disk8s1", path: "/Volumes/NTFSBridge-Test", kind: "macfuse", writable: true)
        XCTAssertTrue(writable.verifies(device: "disk8s1", path: "/Volumes/NTFSBridge-Test"))
        XCTAssertFalse(writable.verifies(device: "disk9s1", path: writable.path))
        XCTAssertFalse(writable.verifies(device: "disk8s1", path: "/Volumes/Other"))
    }
    func testInputsCannotBecomeShellSyntax() {
        for device in ["disk0", "disk2s1; rm -rf /", "disk2s1\n", "disk2s1/foo", "-disk2s1", "$(whoami)"] { XCTAssertFalse(InputValidation.device(device), device) }
        XCTAssertTrue(InputValidation.device("disk22s12"))
        XCTAssertFalse(InputValidation.uuid("';touch /tmp/x;'"))
    }
    func testUnsafeProbeRestoresReadOnlyWithoutMounting() {
        for code: Int32 in [12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 99] {
            let mock = Mock(); mock.probeCode = code
            XCTAssertThrowsError(try MountTransaction.enable(using: mock))
            XCTAssertEqual(mock.events, ["validate", "unmount", "validate", "probe", "readonly"])
        }
    }
    func testUnmountFailureNeverAttemptsFallbackOrWrite() {
        let mock = Mock(); mock.failAt = "unmount"
        XCTAssertThrowsError(try MountTransaction.enable(using: mock))
        XCTAssertEqual(mock.events, ["validate", "unmount"])
    }
    func testVerificationFailureRestoresReadOnly() {
        let mock = Mock(); mock.failAt = "verify"
        XCTAssertThrowsError(try MountTransaction.enable(using: mock))
        XCTAssertEqual(mock.events.last, "readonly")
    }
    func testIdentityChangeAfterProbePreventsMount() {
        let mock = Mock(); mock.failValidationAt = 3
        XCTAssertThrowsError(try MountTransaction.enable(using: mock))
        XCTAssertFalse(mock.events.contains("mount"))
        XCTAssertEqual(mock.events.last, "readonly")
    }
    func testFallbackFailureIsReported() {
        let mock = Mock(); mock.probeCode = 15; mock.failAt = "readonly"
        XCTAssertThrowsError(try MountTransaction.enable(using: mock)) { error in
            XCTAssertTrue(error.localizedDescription.contains("restoration also failed"))
        }
    }
    func testSuccessfulTransactionMustVerifyMount() throws {
        let mock = Mock()
        try MountTransaction.enable(using: mock)
        XCTAssertEqual(mock.events, ["validate", "unmount", "validate", "probe", "validate", "mount", "verify"])
    }
}

private final class Mock: MountOperations {
    var events: [String] = []
    var probeCode: Int32 = 0
    var failAt: String?
    var failValidationAt: Int?
    func step(_ name: String) throws {
        events.append(name)
        if failAt == name || (name == "validate" && events.filter { $0 == "validate" }.count == failValidationAt) { throw BridgeError("Injected failure") }
    }
    func validate() throws { try step("validate") }
    func unmount() throws { try step("unmount") }
    func probe() throws -> Int32 { try step("probe"); return probeCode }
    func mount() throws { try step("mount") }
    func verify() throws { try step("verify") }
    func restoreReadOnly() throws { try step("readonly") }
}
