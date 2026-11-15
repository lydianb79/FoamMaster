import AppKit
import SwiftUI

/// `FoamMaster --screenshots <dir>`: drives the app through gallery, editor (3D Plane) and the flight
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
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        mainWindow?.setFrame(NSRect(x: 40, y: 40, width: 1480, height: 920), display: true)
        withAnimation { project.showAbout = false }
        after(8) {
            capture(mainWindow, "gallery")
            project.start(.aerobat, choice: AircraftKind.aerobat.defaultSetupChoice)
            project.inspectorTab = .analysis
            after(6) {
                capture(mainWindow, "editor")
                after(1) {
                    SimSession.open(project)
                    after(4) {
                        guard let s = SimSession.current else { NSApp.terminate(nil); return }
                        let ctl = s.controller
                        ctl.camera = .chase; ctl.renderer?.camera = .chase           // (not saved to the pilot's settings)
                        ctl.input.keyDown(ctl.input.controls.key(.throttleUp), repeat: false)
                        after(1.2) {
                            ctl.input.keyUp(ctl.input.controls.key(.throttleUp))
                            ctl.input.keyDown(ctl.input.controls.key(.launch), repeat: false)
                            after(0.3) {
                                ctl.input.keyUp(ctl.input.controls.key(.launch))
                                after(2.2) {
                                    capture(s.window, "simulator")
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
