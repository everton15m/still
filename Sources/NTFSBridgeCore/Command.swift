import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: Data
    public var text: String { String(data: output, encoding: .utf8) ?? "" }
}

// File-backed output avoids pipe-buffer deadlocks. Child environment excludes DYLD,
// shell startup hooks, and Homebrew paths, especially when run by the root helper.
public enum Command {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 45) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if process.isRunning {
            process.terminate()
            // Never SIGKILL a filesystem writer. If stuck, retain its device lock
            // by keeping the helper alive until it exits.
            process.waitUntilExit()
            throw BridgeError("The operation timed out. Check the current mount status before retrying.")
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            throw BridgeError("The operation's process terminated unexpectedly (signal \(process.terminationStatus)). No reliable result was obtained; refresh the drive status before retrying.")
        }
        return CommandResult(status: process.terminationStatus, output: try Data(contentsOf: file))
    }
    public static func diskInfo(_ device: String) throws -> [String: Any] {
        let result = try run("/usr/sbin/diskutil", ["info", "-plist", device])
        guard result.status == 0, let info = try PropertyListSerialization.propertyList(from: result.output, format: nil) as? [String: Any] else {
            throw BridgeError("The drive is unavailable or its information could not be read.")
        }
        return info
    }
    public static func volumeInfo(_ device: String) throws -> [String: Any] {
        let info = try diskInfo(device)
        guard let parent = info["ParentWholeDisk"] as? String,
              parent.range(of: "\\Adisk[0-9]+\\z", options: .regularExpression) != nil else { return info }
        return DiskMetadata.enrich(info, parent: try diskInfo(parent))
    }

}

public enum DiskMetadata {
    public static func hasExternalPhysicalBacking(_ info: [String: Any], physicalParents: Set<String>) -> Bool {
        if let parent = info["ParentWholeDisk"] as? String, physicalParents.contains(parent) { return true }
        // APFS volumes are synthesized; accept only physical stores on the
        // independently enumerated external physical drives. Disk images are excluded.
        guard let stores = info["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty else { return false }
        return stores.allSatisfy { store in
            guard let device = store["APFSPhysicalStore"] as? String ?? store["DeviceIdentifier"] as? String,
                  InputValidation.device(device) else { return false }
            let whole = device.replacingOccurrences(of: "s[0-9]+$", with: "", options: .regularExpression)
            return physicalParents.contains(whole)
        }
    }
    public static func isPartition(_ info: [String: Any]) -> Bool {
        (info["WholeDisk"] as? Bool ?? info["Whole"] as? Bool) == false && info["Internal"] as? Bool == false
    }
    public static func enrich(_ info: [String: Any], parent: [String: Any]) -> [String: Any] {
        var result = info
        // Physical eligibility must be sourced from a matching whole disk.
        result.removeValue(forKey: "VirtualOrPhysical")
        if let parentID = info["ParentWholeDisk"] as? String,
           parent["DeviceIdentifier"] as? String == parentID,
           (parent["WholeDisk"] as? Bool ?? parent["Whole"] as? Bool) == true,
           parent["Internal"] as? Bool == false {
            result["VirtualOrPhysical"] = parent["VirtualOrPhysical"]
        }
        return result
    }
}
