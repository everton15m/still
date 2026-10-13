import SwiftUI
import AppKit
import StorageCore

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(StillAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("showMenuBar") private var showMenuBar = false

    var body: some Scene {
        Window("Still", id: "dashboard") {
            DashboardView().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Current Folder") { model.rescanCurrentFolder() }.keyboardShortcut("r").disabled(model.busy || model.result == nil)
                Button("Scan Startup Storage") { model.scan() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy)
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.busy)
                Button("Cancel Current Task") { model.cancel() }.keyboardShortcut(".").disabled(!model.canCancel)
            }
        }
        Settings { SettingsView().environmentObject(model) }
        MenuBarExtra("Still", systemImage: model.isLow ? "externaldrive.badge.exclamationmark" : "externaldrive", isInserted: $showMenuBar) {
            MenuIndicator().environmentObject(model)
        }
    }
}

@MainActor
final class StillAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "StillIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { DashboardOpener.open() }
        return true
    }
}

struct MenuIndicator: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.capacity.map { "\(formatBytes($0.available)) available" } ?? "Reading storage…")
        Button("Open Still") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh Capacity") { model.refreshCapacity() }
        Divider()
        Button("Quit Still") { NSApp.terminate(nil) }
    }
}
