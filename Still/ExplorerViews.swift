import SwiftUI
import StorageCore

private struct ExplorerItem: Identifiable {
    let url: URL?
    let name: String
    let bytes: Int64
    let directory: Bool
    let incomplete: Bool
    var id: String { url?.path ?? "other-files" }
}

struct FolderExplorer: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: URL?
    @State private var largestFirst = true
    @State private var listOnly = false

    private var items: [ExplorerItem] {
        guard let result = model.result else { return [] }
        let folders = result.children(of: model.exploreURL).map {
            ExplorerItem(url: $0.url, name: $0.url.lastPathComponent, bytes: $0.allocatedBytes, directory: true, incomplete: $0.incomplete)
        }
        let files = result.files(in: model.exploreURL).map {
            ExplorerItem(url: $0.url, name: $0.name, bytes: $0.metadata.allocatedBytes, directory: false, incomplete: false)
        }
        return (folders + files).sorted { largestFirst ? $0.bytes > $1.bytes : $0.bytes < $1.bytes }
    }
    private var mapItems: [ExplorerItem] {
        let sorted = items.sorted { $0.bytes > $1.bytes }
        var tiles = Array(sorted.prefix(18).filter { $0.bytes > 0 })
        let visible = tiles.reduce(Int64(0)) { $0 + $1.bytes }
        let total = model.result?.directories[model.exploreURL.path]?.allocatedBytes ?? visible
        if total > visible { tiles.append(ExplorerItem(url: nil, name: "Other inspected files", bytes: total - visible, directory: false, incomplete: false)) }
        return tiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { model.exploreURL = model.exploreURL.deletingLastPathComponent(); selected = nil } label: { Image(systemName: "chevron.left") }
                    .disabled(model.exploreURL == model.result?.root).help("Enclosing folder")
                Button { if let root = model.result?.root { model.exploreURL = root }; selected = nil } label: { Image(systemName: "house") }.help("Scan root")
                Text(model.exploreURL.path).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Rescan", systemImage: "arrow.clockwise") { model.rescanCurrentFolder() }
                    .controlSize(.small).disabled(model.busy).help("Rescan this folder: \(model.exploreURL.path)")
                Toggle("List", isOn: $listOnly).toggleStyle(.button).controlSize(.small)
                Button { largestFirst.toggle() } label: { Image(systemName: largestFirst ? "arrow.down" : "arrow.up") }.help("Sort by size")
            }
            if !listOnly && !mapItems.isEmpty {
                GeometryReader { geometry in
                    let tiles = mapItems
                    let rects = TreemapLayout.rectangles(weights: tiles.map(\.bytes), width: geometry.size.width, height: geometry.size.height)
                    ZStack(alignment: .topLeading) {
                        ForEach(rects, id: \.index) { rect in
                            let item = tiles[rect.index]
                            Button { inspect(item) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if rect.width > 100 && rect.height > 65 {
                                        Image(systemName: item.directory ? "folder.fill" : "doc.fill").font(.caption).opacity(0.7)
                                    }
                                    if rect.width > 62 && rect.height > 34 {
                                        Text(item.name).font(.system(size: rect.width > 180 ? 13 : 11, weight: .medium)).lineLimit(2)
                                        if rect.height > 65 { Text(formatBytes(item.bytes)).font(.caption).opacity(0.8) }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(rect.width > 80 ? 12 : 5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .foregroundStyle(.white).background(item.url == nil ? Color.gray : StillStyle.tileColors[rect.index % StillStyle.tileColors.count], in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                                .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
                                .offset(x: rect.x, y: rect.y)
                                .help("\(item.name) · \(formatBytes(item.bytes))\(item.incomplete ? " · Partial" : "")")
                                .accessibilityLabel("\(item.name), \(formatBytes(item.bytes))\(item.directory ? ", open folder" : "")")
                                .disabled(item.url == nil)
                        }
                    }
                }.frame(height: 220).clipped()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(200)) { item in
                        HStack(spacing: 8) {
                            Button { inspect(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.directory ? "folder" : "doc").foregroundStyle(StillStyle.accent).frame(width: 18)
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    if item.incomplete { Text("Partial").font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(formatBytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                                    if item.directory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if let url = item.url {
                                Button { model.reveal(url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Reveal in Finder")
                            }
                        }.font(.subheadline)
                        Divider()
                    }
                }
            }.frame(height: items.isEmpty ? 40 : min(180, CGFloat(items.count) * 34))
            if items.isEmpty { Text("No retained files or folders here. Files smaller than 1 MB still count toward totals.").font(.caption).foregroundStyle(.secondary) }
            if items.count > 200 { Text("Showing 200 entries. Scan a smaller folder to narrow the view.").font(.caption).foregroundStyle(.secondary) }
            let inspected = selected ?? model.exploreURL
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(inspected.lastPathComponent.isEmpty ? "Startup storage" : inspected.lastPathComponent).font(.subheadline.weight(.medium))
                    Text(inspected.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button("Reveal in Finder") { model.reveal(inspected) }
                Button("Move to Trash…") { model.requestTrash([inspected]) }
                    .disabled(model.busy || model.policy.rejectionReason(for: inspected) != nil)
                    .help(model.policy.rejectionReason(for: inspected) ?? "Review this exact item before moving it to Trash")
            }.controlSize(.small)
            if let reason = model.policy.rejectionReason(for: inspected) { Text(reason).font(.caption2).foregroundStyle(.secondary) }
        }.onChange(of: model.exploreURL) { _, _ in selected = nil }
    }

    private func inspect(_ item: ExplorerItem) {
        guard let url = item.url else { return }
        selected = url
        if item.directory { model.exploreURL = url }
    }
}

struct LargeFilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var category: FileCategory?
    @State private var selected = Set<String>()
    @State private var largestFirst = true
    private var selectedFiles: [FileRecord] { selected.compactMap { model.file(at: $0) } }
    private var protectedSelection: [FileRecord] { selectedFiles.filter { model.protectionReasons[$0.id] != nil } }
    private var files: [FileRecord] {
        let matched = (model.result?.files ?? []).filter {
            (category == nil || $0.category == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
        return Array((largestFirst ? matched : Array(matched.reversed())).prefix(500))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search file names", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 270)
                Picker("Type", selection: $category) {
                    Text("All types").tag(nil as FileCategory?)
                    ForEach(FileCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }.frame(width: 165)
                Spacer()
                Button(largestFirst ? "Largest first ↓" : "Smallest first ↑") { largestFirst.toggle() }.controlSize(.small)
            }
            Table(files, selection: $selected) {
                TableColumn("File") { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(file.name, systemImage: "doc").lineLimit(1)
                        if let reason = model.protectionReasons[file.id] {
                            Label("Inspection only", systemImage: "lock").font(.caption2).foregroundStyle(.secondary).help(reason)
                        }
                    }.help(file.url.path)
                }.width(min: 160, ideal: 260)
                TableColumn("On disk") { file in Text(formatBytes(file.metadata.allocatedBytes)).monospacedDigit() }.width(95)
                TableColumn("Location") { file in Text(file.url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.url.path) }
                TableColumn("") { file in
                    Button { model.reveal(file.url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Reveal in Finder")
                }.width(28)
            }.frame(height: 290)
            HStack {
                Text("\(files.count) shown · up to 500 matching files").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Move \(selected.count) selected to Trash…") {
                    model.requestTrash(selectedFiles.map(\.url))
                }.disabled(selected.isEmpty || !protectedSelection.isEmpty || model.busy)
            }.controlSize(.small)
            if let file = protectedSelection.first, let reason = model.protectionReasons[file.id] {
                Label("\(protectedSelection.count) selected item(s) are inspection-only. \(reason) Deselect them to review other files.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.onChange(of: model.result?.finished) { _, _ in selected = [] }
         .onChange(of: model.result?.files.count) { _, _ in selected = [] }
         .onChange(of: search) { _, _ in selected = [] }
         .onChange(of: category) { _, _ in selected = [] }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected = Set<String>()
    private var groups: [DuplicateGroup] { Array((model.duplicateResult?.groups ?? []).prefix(50)) }
    private var selectedAllInGroup: Bool { groups.contains { $0.files.allSatisfy { selected.contains($0.id) } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Same size, then verified with SHA-256. No copy is selected for you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.comparing ? "Comparing…" : "Find duplicates") { selected = []; model.findDuplicates() }.disabled(model.busy)
            }
            if model.comparing { HStack { ProgressView().controlSize(.small); Text(model.compareProgress).font(.caption) } }
            if let result = model.duplicateResult {
                if result.cancelled { Text("Comparison stopped. These are partial results.").font(.caption).foregroundStyle(.secondary) }
                if !result.issues.isEmpty { Text("\(result.issues.count) file(s) could not be compared or changed during comparison.").font(.caption).foregroundStyle(.secondary) }
                if groups.isEmpty { Text("No verified duplicate groups found in eligible, locally stored files ≥ 1 MB.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 15) {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text("\(group.files.count) identical files").font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text("Potential: 0–\(formatBytes(group.potentialBytes))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(group.files) { file in
                                        HStack {
                                            Toggle(isOn: Binding(get: { selected.contains(file.id) }, set: { if $0 { selected.insert(file.id) } else { selected.remove(file.id) } })) {
                                                Text(file.url.path).lineLimit(1).truncationMode(.middle).help(file.url.path)
                                            }.toggleStyle(.checkbox).font(.caption)
                                            Spacer()
                                            Button { model.reveal(file.url) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Reveal in Finder")
                                        }
                                    }
                                }
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 280)
                    HStack {
                        Text(selectedAllInGroup ? "Keep at least one copy in each group." : "Hard-link aliases are excluded. Shared APFS blocks can mean zero savings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Review \(selected.count) selected…") {
                            model.requestDuplicateTrash(groups: groups, selected: selected)
                        }.disabled(selected.isEmpty || selectedAllInGroup || model.busy)
                    }
                    if (model.duplicateResult?.groups.count ?? 0) > 50 { Text("Showing the 50 largest groups. Scan a smaller folder to inspect more.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if !model.comparing {
                Text("Run this when you need it. Comparing content reads files from disk; Still never does this in the background.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
            }
        }.onChange(of: model.result?.files.count) { _, _ in selected = [] }
    }
}
