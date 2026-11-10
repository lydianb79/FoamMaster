import Foundation
import AppKit
import MetalKit
import SwiftUI

/// `FoamMaster --selftest <outdir>`: builds every model type, prints the analysis and writes PDFs/STLs.
enum SelfTest {
    @MainActor static func run(outDir: String) {
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for kind in AircraftKind.allCases {
            var c = kind.defaults
            let p = Project()
            c = Project.balanced(c); _ = p
            let d = DesignBuilder.build(c)
            let a = Analysis(design: d)
            print("== \(kind.title): AUW \(Int(a.totalMass)) g, foam \(Int(a.foamMass)) g, WL \(String(format: "%.1f", a.wingLoading)), CG \(String(format: "%.1f", a.cg.z)) target \(String(format: "%.1f", a.recommendedCG)), bat \(Int(c.batteryPosition)), TW \(String(format: "%.2f", a.thrustToWeight)), score \(a.score) feasible \(a.feasible)")
            for ch in a.checks where ch.severity >= .warning { print("   [\(ch.severity)] \(ch.title): \(ch.detail)") }
            if let img = Thumbnailer.image(for: d, key: kind.rawValue + "-test"), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                savePNG(cg, dir.appendingPathComponent("thumb_\(kind.rawValue).png"))
            }
            let pdf = PlanPDF.render(d, a)
            try? pdf.write(to: dir.appendingPathComponent("\(kind.rawValue).pdf"))
            let layout = PlanLayout.make(d.parts)
            print("   plan: \(layout.columns)x\(layout.rows), \(layout.usedTiles.count) tiles, pdf \(pdf.count / 1024) KB")
            for part in PrintedParts.generate(d) {
                try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("\(kind.rawValue)_\(part.fileName).stl"))
                print("   stl \(part.fileName): \(part.mesh.triangles.count) tris, \(String(format: "%.2f", part.mass)) g")
            }
            let scene = SceneBuilder.aircraft(d, a, deflection: 0.5, showCG: true)
            print("   scene: \(scene.triangles.count / 3) tris, \(scene.lines.count / 2) lines")
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view) {
                r.setScene(scene, resetCamera: true)
                if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("\(kind.rawValue)_3d.png")) }
            }
        }
        let project = Project()
        project.start(.flyingWing)
        snapshotView(GalleryContent().environmentObject(project), size: CGSize(width: 1300, height: 820), to: dir.appendingPathComponent("ui_gallery.png"))
        for (i, kind) in [AircraftKind.trainer].enumerated() {
            project.start(kind)
            let ui = HStack(spacing: 0) {
                ParameterContent().frame(width: 320)
                VStack { AnalysisPanel(design: project.design!, analysis: project.analysis!); Spacer() }.padding(14).frame(width: 390)
                VStack { PlansPanel(design: project.design!, analysis: project.analysis!); Spacer() }.padding(14).frame(width: 390)
            }.environmentObject(project).frame(height: 1250).background(Theme.background).preferredColorScheme(.dark)
            snapshotView(ui, size: CGSize(width: 1100, height: 1250), to: dir.appendingPathComponent("ui_editor\(i).png"))
        }
        for kind in [AircraftKind.trainer, .aerobat, .glider] {
            for f in FuselageType.allCases {
                var c = kind.defaults; c.fuselageType = f
                let a = Analysis(design: DesignBuilder.build(c))
                print("   \(kind.title) \(f.name): twist \(String(format: "%.1f", a.structure?.tailTwistDeg ?? 0))°, bend \(String(format: "%.2f", a.structure?.tailBendDeg ?? 0))°, wing \(String(format: "%.1f", (a.structure?.wingDeflectionRatio ?? 0) * 100))%, AUW \(Int(a.totalMass)) g")
            }
            print("   recommended: \(FixFinder.recommendedStructure(for: kind.defaults).name)")
        }
        for kind in AircraftKind.allCases {
            let d = DesignBuilder.build(kind.defaults)
            print("   controls \(kind.title): \(d.controls.surfaceCount) surfaces, \(Set(d.controls.map(\.servoID)).count) servos – \(d.controls.map { "\($0.name)→\($0.servoID)" }.joined(separator: ", "))")
        }
        var bad = AircraftKind.trainer.defaults
        bad.tailArm = 150; bad.sparEnabled = false; bad.fuselageType = .cross
        let t0 = Date()
        let fixes = FixFinder.suggestions(for: bad)
        print("fixes for broken trainer (\(String(format: "%.2f", Date().timeIntervalSince(t0))) s):")
        for f in fixes { print("   \(f.solvesAll ? "✓" : "~") \(f.title) – \(f.detail)") }
        for m in MotorClass.allCases {
            let plate = max(m.boltCircle + m.screwHole * 2 + 6, m.bellDiameter * 0.75)
            var holes: [[Vec2]] = [Poly.circle(.zero, max(2.5, m.boltCircle * 0.28), segments: 32)]
            for k in 0..<4 { let a = Double(k) * .pi / 2 + .pi / 4; holes.append(Poly.circle(Vec2(cos(a), sin(a)) * m.boltCircle / 2, m.screwHole / 2, segments: 16)) }
            let tri = Poly.triangulate(outer: Poly.rect(center: .zero, size: Vec2(plate, plate)), holes: holes)
            let expected = 4 + holes.reduce(0) { $0 + $1.count } + 2 * holes.count - 2
            print("   tri \(m.rawValue): \(tri.triangles.count / 3) of \(expected)")
        }
        for kind in AircraftKind.allCases where kind.allowsDualMotors {
            var c = kind.defaults
            c.motorLayout = .dualTractor
            c = Project.balanced(c)
            let d = DesignBuilder.build(c)
            let a = Analysis(design: d)
            print("   dual \(kind.title): AUW \(Int(a.totalMass)) g, TW \(String(format: "%.2f", a.thrustToWeight)), motors ±\(Int(c.dualMotorX)) mm, bat \(c.battery.name) @ \(Int(c.batteryPosition)), feasible \(a.feasible)")
            for ch in a.checks where ch.severity >= .warning { print("      [\(ch.severity)] \(ch.title): \(ch.detail)") }
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view) {
                r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: true), resetCamera: true)
                if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("dual_\(kind.rawValue)_3d.png")) }
            }
            for part in PrintedParts.generate(d) where part.fileName.contains("motor_mount") {
                try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("dual_\(kind.rawValue)_\(part.fileName).stl"))
            }
        }
        for kind in AircraftKind.allCases {
            var c = kind.defaults
            c.tailWinglets = true; c.wingletHeight = 45; c.aio = true
            c = Project.balanced(c)
            let d = DesignBuilder.build(c)
            let a = Analysis(design: d)
            print("   wl+aio \(kind.title): AUW \(Int(a.totalMass)) g, winglets \(d.parts.contains { $0.role == .winglet }), ESCs \(d.components.filter { $0.name.hasPrefix("ESC") }.count), feasible \(a.feasible)")
            for ch in a.checks where ch.severity >= .warning { print("      [\(ch.severity)] \(ch.title): \(ch.detail)") }
            if kind == .trainer || kind == .jet {
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                    if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("wl_\(kind.rawValue)_3d.png")) }
                }
            }
            for part in PrintedParts.generate(d) where part.fileName.contains("aio") {
                try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("\(kind.rawValue)_\(part.fileName).stl"))
            }
        }
        for kind in [AircraftKind.flyingWing, .delta] {
            for fpv in [FPVSystem.analog, .o4Lite] {
                var c = kind.defaults; c.fpv = fpv
                c = Project.balanced(c)
                let d = DesignBuilder.build(c); let a = Analysis(design: d)
                let batFront = c.batteryPosition - c.battery.size.l / 2
                print("   fpv \(kind.title) \(fpv.name): camera z \(Int(c.fpvCameraZ)), battery front \(Int(batFront)) (\(c.battery.name)), clear \(batFront > c.fpvCameraZ + 9), feasible \(a.feasible), score \(a.score)")
                for ch in a.checks where ch.severity >= .warning { print("      [\(ch.severity)] \(ch.title): \(ch.detail)") }
                if fpv == .o4Lite && kind == .flyingWing {
                    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                    if let r = Renderer(view: view) {
                        r.setScene(SceneBuilder.aircraft(d, a, deflection: 0.4, showCG: false), resetCamera: true)
                        r.pitch = -0.35
                        if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("fpv_wing_under.png")) }
                        r.pitch = 0.6
                        if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("fpv_wing_top.png")) }
                    }
                }
            }
        }
        var feasible = 0
        for _ in 0..<20 {
            let c = AircraftConfig.random(kind: AircraftKind.allCases.randomElement()!)
            if Analysis(design: DesignBuilder.build(c)).feasible { feasible += 1 }
        }
        print("raw random feasible: \(feasible)/20")
    }
}

@MainActor func snapshotView<V: View>(_ v: V, size: CGSize, to url: URL) {
    let r = ImageRenderer(content: ZStack { Theme.background; v }.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
    r.scale = 1
    if let img = r.cgImage { savePNG(img, url) }
}

func savePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
