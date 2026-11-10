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
