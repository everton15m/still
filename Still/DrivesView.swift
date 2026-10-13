import SwiftUI
import NTFSBridgeCore

struct DrivesView: View {
    @StateObject private var drives = DrivesModel()
    @EnvironmentObject private var storage: AppModel
    @State private var writeRequest: Volume?
    @State private var ejectRequest: Volume?

    private var busy: Bool { storage.busy || drives.busyDevice != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connected drives").font(.title3.weight(.semibold))
                Spacer()
                if drives.volumes.contains(where: { $0.isNTFS }) {
                    Button(!drives.ready && DriverLayout.installed ? "Update NTFS Helper…" : "Set Up NTFS…") { drives.setupPresented = true }.controlSize(.small).disabled(busy)
                }
                Button { drives.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh connected drives").disabled(busy || drives.refreshing)
            }
            if drives.volumes.isEmpty {
                Text(drives.refreshing ? "Looking for external drives…" : "Connect a drive to open it in Finder or manage NTFS write access here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(drives.volumes) { volume in
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(StillStyle.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(volume.name).font(.subheadline.weight(.medium))
                            Text(volume.filesystem.uppercased()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(volume.accessLabel) · \(formatBytes(volume.total)) total\(volume.available.map { " · \(formatBytes($0)) available" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = volume.writeEligibility, volume.isNTFS {
                            Text(reason).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if drives.busyDevice == volume.device { ProgressView().controlSize(.small) }
                    VStack(alignment: .trailing, spacing: 7) {
                        if volume.isNTFS && volume.writable != true && volume.writeEligibility == nil {
                            HStack(spacing: 8) {
                                Button("Check NTFS…") { drives.check(volume) }.disabled(busy)
                                Button("Enable Write Access…") {
                                    if drives.ready { writeRequest = volume }
                                    else { drives.setupPresented = true }
                                }.disabled(busy)
                            }
                        }
                        HStack {
                            Button("Finder") { drives.open(volume) }.disabled(busy || volume.mountPoint == nil)
                            Button { ejectRequest = volume } label: { Image(systemName: "eject.fill") }
                                .help("Eject the whole physical drive, including all its partitions").disabled(busy)
                        }
                    }.controlSize(.small)
                }
                if volume.id != drives.volumes.last?.id { Divider() }
            }
            if !drives.ready && drives.volumes.contains(where: { $0.isNTFS }) {
                Text(DriverLayout.installed ? "The NTFS helper needs the bundled update before a diagnostic or write request can run." : "NTFS writing needs the one-time macFUSE and helper setup. Other drive formats use macOS’s existing support.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card()
        .sheet(isPresented: $drives.setupPresented) { NTFSSetupView(drives: drives) }
        .sheet(item: $drives.diagnostic) { notice in NTFSDiagnosticView(report: notice.report) }
        .alert(item: $drives.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Enable write access to \(writeRequest?.name ?? "NTFS")?", isPresented: Binding(get: { writeRequest != nil }, set: { if !$0 { writeRequest = nil } }), titleVisibility: .visible) {
            if let volume = writeRequest { Button("Enable Write Access") { drives.enable(volume); writeRequest = nil } }
            Button("Cancel", role: .cancel) { writeRequest = nil }
        } message: {
            Text("Close files on this NTFS volume first. Still will request administrator authorization, unmount it, check its identity and NTFS metadata, then enable writes only if the checks pass. Unsafe volumes remain read-only.")
        }
        .confirmationDialog("Eject \(ejectRequest?.name ?? "this drive")?", isPresented: Binding(get: { ejectRequest != nil }, set: { if !$0 { ejectRequest = nil } }), titleVisibility: .visible) {
            if let volume = ejectRequest { Button("Eject Drive") { drives.eject(volume); ejectRequest = nil } }
            Button("Cancel", role: .cancel) { ejectRequest = nil }
        } message: {
            Text("This ejects the entire physical drive, including its other partitions. Close files on all its volumes first. A busy drive will not be force-ejected.")
        }
    }
}

private struct NTFSSetupView: View {
    @ObservedObject var drives: DrivesModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set up NTFS write access", systemImage: "externaldrive.badge.checkmark").font(.title2.weight(.semibold))
            Text("Install macFUSE 5.4 or later and the bundled NTFS helper once. Still uses the FSKit backend; it does not require changing Recovery security or disabling SIP.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("1. Install macFUSE and enable its FSKit file system extension if macOS requests approval.").font(.subheadline)
            Link("Official macFUSE downloads", destination: URL(string: "https://macfuse.io/")!)
            Text("2. Install or update the NTFS helper. Installer asks for administrator approval. It installs the driver and a short-lived helper, without a background daemon.").font(.subheadline)
            Button("Open Helper Installer…") { drives.openHelperInstaller() }
            Text("NTFS-3G is open source. macFUSE includes closed-source components. Actual write support depends on macOS, the FSKit extension, and a clean, supported NTFS volume.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { drives.refresh(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540).tint(StillStyle.accent)
    }
}

private struct NTFSDiagnosticView: View {
    let report: NTFSSafetyReport
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("NTFS check", systemImage: "doc.text.magnifyingglass").font(.title2.weight(.semibold))
            Text(report.explanation).fixedSize(horizontal: false, vertical: true)
            Label("Native read-only access restored", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Technical details") {
                Text(report.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 550)
    }
}
