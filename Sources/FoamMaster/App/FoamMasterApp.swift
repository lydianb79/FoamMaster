import SwiftUI
import AppKit

@main
struct FoamMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var project = Project()
    @AppStorage(ThemePalette.storageKey) private var theme = ThemePalette.defaultName

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--strutstest") {
            let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "strutstest")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            MainActor.assumeIsolated { SelfTest.strutReport(dir) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest") {
            MainActor.assumeIsolated { SelfTest.run(outDir: i + 1 < args.count ? args[i + 1] : "selftest") }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("FoamMaster") {
            RootView()
                .environmentObject(project)
                .frame(minWidth: 1280, minHeight: 780)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 920)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About FoamMaster") { withAnimation { project.showAbout = true } }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Model…") { project.config = nil }.keyboardShortcut("n")
            }
            CommandMenu("Theme") {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemePalette.all) { Text($0.name + ($0.name == ThemePalette.defaultName ? " (default)" : "")).tag($0.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            CommandMenu("Model") {
                Button("Randomize") { project.randomize() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(project.config == nil)
                Button("Export Plans PDF…") { project.exportPlans() }.keyboardShortcut("e")
                    .disabled(project.config == nil)
                Button("Print Plans…") { project.printPlans() }.keyboardShortcut("p")
                    .disabled(project.config == nil)
                Button("Export STL Files…") { project.exportSTLs() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(project.config == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// No window tabs – removes "Show Tab Bar" / "Show All Tabs" from the View menu.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
