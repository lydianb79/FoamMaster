import SwiftUI
import AppKit

@main
struct FoamMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var project = Project()

    init() {
        let args = CommandLine.arguments
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
            CommandGroup(replacing: .newItem) {
                Button("New Model…") { project.config = nil }.keyboardShortcut("n")
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
