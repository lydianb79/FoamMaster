import AppKit
import SwiftUI

/// `FoamMaster --screenshots <dir>`: drives the app through gallery, setup sheet, editor (3D Plane) and the flight
/// simulator and saves each window as a PNG – the README's screenshots. An app may capture its own windows, so no
/// screen-recording permission is needed. Quits when done.
@MainActor
enum Screenshots {
    static func run(_ dir: URL, project: Project) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func capture(_ window: NSWindow?, _ name: String) {
            guard let window, let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                                [.boundsIgnoreFraming, .bestResolution]) else {
                print("screenshot \(name): no image"); return
            }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print("screenshot \(name): \(img.width) × \(img.height)")
        }
        var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.title != "Flight Simulator" && $0.frame.width > 800 } }
        var sim: SimController? { SimSession.current?.controller }
        func key(_ a: SimAction, down: Bool) {
            guard let input = sim?.input else { return }
            if down { input.keyDown(input.controls.key(a), repeat: false) } else { input.keyUp(input.controls.key(a)) }
        }

        // Each step runs after the given pause (seconds) after the one before.
        let steps: [(Double, () -> Void)] = [
            (0, {
                mainWindow?.setFrame(NSRect(x: 40, y: 40, width: 1480, height: 920), display: true)
                withAnimation { project.showAbout = false }
            }),
            (8, { capture(mainWindow, "gallery") }),
            (0, { project.setupSheetRequest = .some(.aerobat) }),
            // (the setup sheet is a window of its own, attached to the main one; it sizes its option set first)
            (5, { capture(mainWindow?.attachedSheet, "setup") }),
            (0, { project.setupSheetRequest = .some(nil) }),
            (1.5, {
                project.start(.aerobat, choice: AircraftKind.aerobat.defaultSetupChoice)
                project.inspectorTab = .analysis
            }),
            (6, { capture(mainWindow, "editor") }),
            (1, { SimSession.open(project) }),
            (4, {
                sim?.camera = .chase; sim?.renderer?.camera = .chase      // (not saved to the pilot's settings)
                key(.throttleUp, down: true)
            }),
            (1.8, { key(.throttleUp, down: false); key(.launch, down: true) }),
            (0.3, { key(.launch, down: false) }),
            (3.0, {
                capture(SimSession.current?.window, "simulator")
                NSApp.terminate(nil)
            })
        ]
        var t = 0.0
        for (pause, step) in steps {
            t += pause
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: step)
        }
    }
}
