import SwiftUI
import AppKit
import StorageCore

enum StillStyle {
    static let accent = Color(red: 0.12, green: 0.48, blue: 0.43)
    static let tileColors: [Color] = [accent, Color(red: 0.29, green: 0.51, blue: 0.65),
        Color(red: 0.47, green: 0.43, blue: 0.64), Color(red: 0.63, green: 0.46, blue: 0.30),
        Color(red: 0.35, green: 0.55, blue: 0.48), Color(red: 0.42, green: 0.49, blue: 0.59)]
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var mode = ExplorerMode.folders

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                overview
                DrivesView().environmentObject(model)
                explorer
                cleanup
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("On your Mac. In your control.")
                    Spacer()
                    Text("No accounts · No telemetry")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1240).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(StillStyle.accent)
        .frame(minWidth: 860, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
            }
        }
        .onAppear { DashboardOpener.action = { openWindow(id: "dashboard") } }
        .alert("Still needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { model.trashPlan != nil }, set: { if !$0 { model.trashPlan = nil } })) {
            if let plan = model.trashPlan { TrashConfirmation(plan: plan).environmentObject(model) }
        }
        .sheet(isPresented: $model.showIssues) { ScanIssuesView().environmentObject(model) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("A little space. A lighter Mac.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.canCancel {
                Button(model.preparingTrash ? "Cancel Review" : "Stop", systemImage: "stop.circle") { model.cancel() }
            } else {
                Menu {
                    Button("Scan Startup Storage") { model.scan() }
                    Button("Scan My Home Folder") { model.scan(model.policy.home) }
                    Button("Choose Folder…") { model.chooseFolder() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("STARTUP STORAGE", systemImage: "internaldrive").font(.system(size: 11, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                Spacer()
                Label(model.isLow ? "Room to recover" : "Storage looks healthy", systemImage: model.isLow ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(model.isLow ? Color.orange : StillStyle.accent)
                    .opacity(model.capacity == nil ? 0 : 1)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(model.capacity.map { formatBytes($0.available) } ?? "—")
                            .font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("available").font(.title3).foregroundStyle(.secondary)
                    }
                    Text(model.isLow ? "Below your \(model.thresholdGB) GB threshold. Start with files you recognize." : "Space for what comes next.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.rescanCurrentFolder() } label: {
                    Label(model.scanning ? "Scanning…" : model.result != nil ? (model.exploreURL.path == "/" ? "Rescan Storage" : "Rescan Folder") : model.isLow ? "Find room to recover" : "Scan Storage", systemImage: "sparkle.magnifyingglass")
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                    .help(model.result == nil ? "Scan accessible startup storage" : "Rescan \(model.exploreURL.path)")
            }
            GeometryReader { geometry in
                let ratio = model.capacity.map { Double($0.used) / Double(max(1, $0.total)) } ?? 0
                ZStack(alignment: .leading) {
                    Capsule().fill(StillStyle.accent.opacity(0.12))
                    Capsule().fill(model.isLow ? Color.orange.opacity(0.8) : StillStyle.accent)
                        .frame(width: geometry.size.width * min(1, max(0, ratio)))
                }
            }.frame(height: 11)
            HStack {
                Text(model.capacity.map { "\(formatBytes($0.used)) used" } ?? "Reading capacity…")
                Spacer()
                Text(model.capacity.map { "\(formatBytes($0.total)) total" } ?? "")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let value = model.capacity, let important = value.importantAvailable, important > value.available {
                Text("macOS reports \(formatBytes(important)) available for important usage, including reclaimable storage. Alerts use the conservative available value above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.capacityError {
                HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button("Retry") { model.refreshCapacity() } }
            }
            if !model.alertsEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "bell")
                    Text("A quiet heads-up when storage drops below \(model.thresholdGB) GB.")
                    Spacer()
                    Button("Enable alerts") { model.setAlerts(true) }.buttonStyle(.link)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.card()
    }

    private var explorer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Explore your space").font(.title3.weight(.semibold))
                    Text(model.result.map { "\(formatBytes($0.allocatedBytes)) inspected · \($0.visited.formatted()) entries" } ?? "See the big picture, then look a little closer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.result != nil {
                    Picker("Explore view", selection: $mode) {
                        ForEach(ExplorerMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 310)
                }
            }
            if model.scanning {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\((model.progress?.visited ?? 0).formatted()) entries · \(formatBytes(model.progress?.allocatedBytes ?? 0)) inspected")
                            .font(.subheadline).monospacedDigit()
                        Text(model.progress?.currentPath ?? "Starting scan…").lineLimit(1).truncationMode(.middle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Partial results").font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(StillStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                ForEach(model.progress?.largest.prefix(5) ?? [].prefix(5)) { file in
                    HStack { Text(file.name).lineLimit(1); Spacer(); Text(formatBytes(file.metadata.allocatedBytes)).monospacedDigit() }.font(.caption)
                }
            } else if let result = model.result {
                if result.issueCount > 0 || result.cancelled || result.limited {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(result.limited ? "Results limited by the memory budget. Scan a smaller folder for more detail." : "Protected or excluded locations are not included. This is a partial view of your disk.")
                        Spacer()
                        Button("Coverage") { model.showIssues = true }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                switch mode {
                case .folders: FolderExplorer().environmentObject(model)
                case .files: LargeFilesView().environmentObject(model)
                case .duplicates: DuplicatesView().environmentObject(model)
                }
                Text("Allocated file sizes are estimates; APFS clones and snapshots may share blocks. File lists retain items ≥ 1 MB.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group").font(.system(size: 36, weight: .light)).foregroundStyle(StillStyle.accent)
                    Text("Know where your space goes").font(.headline)
                    Text("Scan your startup storage to explore folders, find large files,\nand review a few useful cleanup opportunities.")
                        .multilineTextAlignment(.center).font(.subheadline).foregroundStyle(.secondary)
                    Button("Choose a folder instead…") { model.chooseFolder() }.buttonStyle(.link).disabled(model.busy)
                }.frame(maxWidth: .infinity).padding(.vertical, 25)
            }
        }.card()
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Worth a look").font(.title3.weight(.semibold))
                Spacer()
                Label("You make the call", systemImage: "hand.raised").font(.caption).foregroundStyle(.secondary)
            }
            if model.suggestions.isEmpty {
                Text(model.result == nil ? "A short list of cleanup opportunities will appear after scanning." : "No clear cleanup opportunities in this scan. Explore large files and folders to choose what to keep.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.suggestions) { suggestion in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: suggestion.risk == .low ? "arrow.clockwise.circle" : "doc.text.magnifyingglass")
                        .font(.title3).foregroundStyle(StillStyle.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(suggestion.title).font(.subheadline.weight(.medium))
                            Text(suggestion.risk.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(suggestion.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        Text("Up to \(formatBytes(suggestion.bytes))").font(.subheadline.weight(.medium)).monospacedDigit()
                        HStack {
                            Button("Reveal") { model.reveal(suggestion.url) }
                            Button(suggestion.inspectOnly ? "Explore" : "Review…") {
                                if suggestion.inspectOnly { model.exploreURL = suggestion.url; mode = .folders }
                                else { model.requestTrash([suggestion.url]) }
                            }.disabled(model.busy)
                        }.controlSize(.small)
                    }
                }
                if suggestion.id != model.suggestions.last?.id { Divider() }
            }
            if model.preparingTrash || model.trashing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.trashing ? "Moving reviewed items to Trash…" : "Checking every selected item before review…").font(.caption)
                    Spacer()
                    if model.preparingTrash { Button("Cancel Review") { model.cancel() }.controlSize(.small) }
                }
            }
            if let message = model.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.card()
    }
}

enum ExplorerMode: String, CaseIterable, Identifiable {
    case folders = "Folders", files = "Large Files", duplicates = "Duplicates"
    var id: String { rawValue }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.055), lineWidth: 1))
    }
}

extension View { func card() -> some View { modifier(CardStyle()) } }
