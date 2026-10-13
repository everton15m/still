import XCTest
@testable import NTFSBridgeCore

final class DiagnosticTests: XCTestCase {
    func testExtendedClearChecksStillRefuseFlag0080() throws {
        let value = try extendedReport()
        XCTAssertEqual(value.code, 15)
        XCTAssertEqual(value.stage, "volume_flags")
        XCTAssertTrue(value.explanation.contains("Hibernation-file check: clear"))
        XCTAssertTrue(value.explanation.contains("clean-state checks passed"))
        XCTAssertTrue(value.explanation.contains("Write access remains blocked"))
        XCTAssertTrue(value.details.contains("Journal check: passed"))
    }
    func testExtendedCleanVersion2JournalIsStillRefused() throws {
        let value = try extendedReport(journal: 14, major: 2)
        XCTAssertEqual(value.code, 15) // First refusal is retained.
        XCTAssertTrue(value.explanation.contains("version-2.0 cached-state guard refused"))
        XCTAssertTrue(value.details.contains("Journal check: refused (14)"))
        XCTAssertTrue(value.details.contains("Journal clean: yes"))
    }
    func testExtendedHibernationAndJournalRefusalsAreBothDisplayed() throws {
        let value = try extendedReport(hiber: 14, journal: 14, major: 2)
        XCTAssertTrue(value.explanation.contains("Hibernation-file check: refused (code 14)"))
        XCTAssertTrue(value.explanation.contains("cached-state guard refused"))
        XCTAssertEqual(value.stage, "volume_flags")
    }
    func testInvalidJournalCodeAndBlockedWriteCannotPass() throws {
        let data = try JSONEncoder().encode(report())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["journalCode"] = 99
        XCTAssertThrowsError(try NTFSSafetyReport.decode(JSONSerialization.data(withJSONObject: json), exitStatus: 0))
        json["journalCode"] = 0; json["writeBlocked"] = 1
        XCTAssertThrowsError(try NTFSSafetyReport.decode(JSONSerialization.data(withJSONObject: json), exitStatus: 0))
    }
    private func extendedReport(hiber: Int = 0, journal: Int = 0, major: Int = 1) throws -> NTFSSafetyReport {
        let json = """
        {"schema":1,"code":15,"stage":"volume_flags","volumeFlags":128,"ntfsMajor":3,"ntfsMinor":1,"hiberCode":\(hiber),"logValid":1,"logClean":1,"logMajor":\(major),"logMinor":\(major == 1 ? 1 : 0),"journalCode":\(journal),"osError":0,"ioOperation":"none","deviceOpened":1,"writeBlocked":0}
        """
        return try NTFSSafetyReport.decode(Data(json.utf8), exitStatus: 15)
    }
    func testUnknownVolumeFlagCannotBeCalledDirtyOrCorrupt() throws {
        let value = try flaggedReport(0x0080)
        XCTAssertTrue(value.explanation.contains("does not interpret volume flags 0x0080"))
        XCTAssertTrue(value.explanation.contains("dirty bit is not set"))
        XCTAssertTrue(value.explanation.contains("flag alone does not establish corruption or hibernation"))
        XCTAssertTrue(value.details.contains("NTFS dirty bit: not set"))
        XCTAssertEqual(value.code, 15) // No change to the refusal policy.
    }
    func testDirtyFlagIsReportedEvenAlongsideUnknownFlags() throws {
        let value = try flaggedReport(0x0081)
        XCTAssertTrue(value.explanation.contains("dirty bit is set"))
        XCTAssertTrue(value.details.contains("NTFS dirty bit: set"))
        XCTAssertEqual(value.code, 15)
    }
    private func flaggedReport(_ flags: Int) throws -> NTFSSafetyReport {
        let json = """
        {"schema":1,"code":15,"stage":"volume_flags","volumeFlags":\(flags),"ntfsMajor":3,"ntfsMinor":1,"hiberCode":-1,"logValid":-1,"logClean":-1,"logMajor":-1,"logMinor":-1,"osError":0,"ioOperation":"none","deviceOpened":1,"writeBlocked":0}
        """
        return try NTFSSafetyReport.decode(Data(json.utf8), exitStatus: 15)
    }
    func testVolumeOpenEPERMCannotBeDiagnosedAsHibernation() throws {
        let json = """
        {"schema":1,"code":14,"stage":"volume_open","volumeFlags":-1,"ntfsMajor":-1,"ntfsMinor":-1,"hiberCode":-1,"logValid":-1,"logClean":-1,"logMajor":-1,"logMinor":-1,"osError":1,"ioOperation":"device_open","deviceOpened":0,"writeBlocked":0}
        """
        let value = try NTFSSafetyReport.decode(Data(json.utf8), exitStatus: 14)
        XCTAssertTrue(value.explanation.contains("macOS denied read-only access"))
        XCTAssertTrue(value.explanation.contains("checks did not run"))
        XCTAssertTrue(value.details.contains("1 (Operation not permitted)"))
        XCTAssertTrue(value.details.contains("I/O operation: device_open"))
        XCTAssertTrue(value.details.contains("Write attempted: no"))
    }
    func testOldVolumeOpenReportDoesNotClaimHibernation() throws {
        let value = try report(code: 14, stage: "volume_open")
        XCTAssertTrue(value.explanation.contains("code 14 alone cannot identify"))
        XCTAssertTrue(value.details.contains("not recorded by this helper"))
    }
    func testRejectsUntrustedDeviceOperationText() throws {
        let data = try JSONEncoder().encode(report(code: 14, stage: "volume_open"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["ioOperation"] = "/private/user-file.txt"
        XCTAssertThrowsError(try NTFSSafetyReport.decode(JSONSerialization.data(withJSONObject: json), exitStatus: 14))
        json["ioOperation"] = "device_open"; json["osError"] = -1
        XCTAssertThrowsError(try NTFSSafetyReport.decode(JSONSerialization.data(withJSONObject: json), exitStatus: 14))
    }
    private func report(code: Int32 = 0, stage: String = "passed") throws -> NTFSSafetyReport {
        let json = "{\"schema\":1,\"code\":\(code),\"stage\":\"\(stage)\",\"volumeFlags\":0,\"ntfsMajor\":3,\"ntfsMinor\":1,\"hiberCode\":0,\"logValid\":1,\"logClean\":1,\"logMajor\":2,\"logMinor\":0}"
        return try NTFSSafetyReport.decode(Data(json.utf8), exitStatus: code)
    }
    func testSignalFourteenCannotBecomeAHibernationVerdict() {
        XCTAssertThrowsError(try Command.run("/bin/sh", ["-c", "kill -ALRM $$"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("signal 14"))
            XCTAssertFalse(error.localizedDescription.contains("hibernation"))
        }
    }
    func testReadOnlyFUSEMountCannotCountAsNativeRestoration() {
        let path = "/Volumes/NTFSBridge-Test"
        for kind in ["macfuse", "fskit", "apfs"] {
            let record = MountRecord(source: "/dev/disk8s1", path: "/Volumes/Other", kind: kind, writable: false)
            XCTAssertFalse(record.isNativeReadOnlyNTFS(device: "disk8s1", excluding: path))
        }
        XCTAssertFalse(MountRecord(source: "/dev/disk8s1", path: path, kind: "ntfs", writable: false).isNativeReadOnlyNTFS(device: "disk8s1", excluding: path))
        XCTAssertTrue(MountRecord(source: "/dev/disk8s1", path: "/Volumes/NTFS", kind: "ntfs", writable: false).isNativeReadOnlyNTFS(device: "disk8s1", excluding: path))
    }
    func testCleanCachedV2JournalIsStillRefusedAndExplainedWithoutClaimingActiveHibernation() throws {
        let value = try report(code: 14, stage: "cached_journal")
        XCTAssertTrue(value.explanation.contains("does not prove"))
        XCTAssertTrue(value.details.contains("Journal clean: yes"))
        XCTAssertTrue(value.details.contains("Journal version: 2.0"))
    }
    func testHibernationAndJournalHaveDifferentExplanations() throws {
        XCTAssertNotEqual(try report(code: 14, stage: "hiber_file").explanation, try report(code: 14, stage: "cached_journal").explanation)
    }
    func testRejectsUnstructuredOrInconsistentReports() throws {
        XCTAssertThrowsError(try NTFSSafetyReport.decode(Data("invalid".utf8), exitStatus: 14))
        let encoded = try JSONEncoder().encode(report(code: 14, stage: "cached_journal"))
        XCTAssertThrowsError(try NTFSSafetyReport.decode(encoded, exitStatus: 0))
        XCTAssertThrowsError(try report(code: 14, stage: "passed"))
        XCTAssertThrowsError(try report(code: 0, stage: "cached_journal"))
    }
    func testUnsafeReadOnlyCheckNeverRunsWriteProbeOrDriver() throws {
        let mock = DiagnosticMock(report: try report(code: 14, stage: "cached_journal"))
        let result = try NTFSDiagnosticTransaction.check(using: mock)
        XCTAssertEqual(result.code, 14)
        XCTAssertEqual(mock.calls, ["validate", "unmount", "validate", "read-only-report", "restore"])
    }
    func testCleanReadOnlyCheckStillRestoresNativeReadOnlyAccess() throws {
        let mock = DiagnosticMock(report: try report())
        _ = try NTFSDiagnosticTransaction.check(using: mock)
        XCTAssertEqual(mock.calls.last, "restore")
        XCTAssertFalse(mock.calls.contains("mount"))
    }
    func testFailedDiagnosticRestoresReadOnly() throws {
        let mock = DiagnosticMock(report: try report()); mock.failure = "read-only-report"
        XCTAssertThrowsError(try NTFSDiagnosticTransaction.check(using: mock))
        XCTAssertEqual(mock.calls.last, "restore")
    }
    func testBusyUnmountNeverReadsRawMetadataOrRestoresConflictingMount() throws {
        let mock = DiagnosticMock(report: try report()); mock.failure = "unmount"
        XCTAssertThrowsError(try NTFSDiagnosticTransaction.check(using: mock))
        XCTAssertEqual(mock.calls, ["validate", "unmount"])
    }
    func testFallbackFailureDoesNotPresentSuccessfulReport() throws {
        let mock = DiagnosticMock(report: try report()); mock.failure = "restore"
        XCTAssertThrowsError(try NTFSDiagnosticTransaction.check(using: mock))
    }
}

private final class DiagnosticMock: NTFSDiagnosticOperations {
    let report: NTFSSafetyReport
    var calls: [String] = []
    var failure: String?
    init(report: NTFSSafetyReport) { self.report = report }
    private func step(_ name: String) throws { calls.append(name); if name == failure { throw BridgeError("Injected failure") } }
    func validate() throws { try step("validate") }
    func unmount() throws { try step("unmount") }
    func readOnlyReport() throws -> NTFSSafetyReport { try step("read-only-report"); return report }
    func restoreReadOnly() throws { try step("restore") }
    func probe() throws -> Int32 { try step("write-probe"); return 0 }
    func mount() throws { try step("mount") }
    func verify() throws { try step("verify") }
}
