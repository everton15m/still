import SwiftUI
import StorageCore
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showMenuBar") private var showMenuBar = false
    var body: some View {
        Form {
            Section("Storage alerts") {
                Stepper("Warn below \(model.thresholdGB) GB", value: $model.thresholdGB, in: 5...100, step: 5)
                Toggle("Native low-storage notifications", isOn: Binding(get: { model.alertsEnabled }, set: { model.setAlerts($0) }))
                Text("Checks every five minutes and after wake while Still is running. One warning per low-storage episode; resets after at least 2 GB of recovery above the threshold.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keep it nearby") {
                Toggle("Open Still at login", isOn: Binding(get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval }, set: { model.setLogin($0) }))
                if model.loginStatus == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Show menu bar indicator", isOn: $showMenuBar)
                Text("Closing the window keeps capacity monitoring active. Quitting Still stops monitoring. Login uses Apple's main-app service; there is no helper or privileged daemon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Text("For broader scan coverage, add Still in System Settings → Privacy & Security → Full Disk Access, then quit and reopen it. You can also choose a specific folder. System Integrity Protection and filesystem permissions still apply.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access…") { model.openPrivacySettings() }
            }
        }.formStyle(.grouped).frame(width: 490, height: 490).tint(StillStyle.accent)
    }
}

struct TrashConfirmation: View {
    let plan: TrashPlan
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Move to Trash?", systemImage: "trash").font(.title2.weight(.semibold))
            Text("Review these exact items. Nothing else will be moved.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(item.url.lastPathComponent).font(.headline); Spacer(); Text(formatBytes(item.bytes)).monospacedDigit() }
                            Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            }.frame(maxHeight: 260)
            Text("Up to \(formatBytes(plan.estimatedBytes)) of inspected data. Moving to Trash does not free space until you empty Trash in Finder. APFS clones, hard links, and snapshots can reduce actual savings to zero.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Folder actions include everything inside. Inaccessible contents, protected app data, cloud items, and files changed since review are refused.")
                .font(.caption).foregroundStyle(.secondary)
            if !plan.duplicateRetentions.isEmpty {
                Label("An unchanged copy must still remain in every duplicate group. Still checks the copies you kept before each move.", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.trashPlan = nil }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.confirmTrash() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}

struct ScanIssuesView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What this scan covers").font(.title2.weight(.semibold))
            Text(model.result?.root.path ?? "").font(.caption).textSelection(.enabled)
            Text("The dashboard reads capacity from macOS. The explorer sums allocated blocks of files it could inspect, counting hard links once. Shared APFS blocks, snapshots, filesystem metadata, sealed system files, and excluded or inaccessible locations are not a complete disk breakdown.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let result = model.result {
                Text("\(result.issueCount) excluded or inaccessible locations. Showing up to 300 details.").font(.caption)
                if result.cancelled { Text("This scan was cancelled; unvisited locations are not included.").font(.caption).foregroundStyle(.orange) }
                if result.limited { Text("The metadata budget was reached. File lists or folder coverage are limited; scan a smaller folder.").font(.caption).foregroundStyle(.orange) }
                List(result.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.url.path).font(.caption).textSelection(.enabled)
                        Text(issue.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(height: 260)
            }
            HStack {
                Button("Full Disk Access…") { model.openPrivacySettings() }
                Spacer()
                Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
}
