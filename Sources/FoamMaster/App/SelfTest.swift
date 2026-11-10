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
            let pat = m.pattern
            let mesh = PrintedParts.motorMount(m, foam: 6, webTop: 6, webBottom: 6)
            let wing = PrintedParts.motorMount(m, foam: 6, webTop: nil, webBottom: nil)
            let tl = PrintedParts.motorMount(m, foam: 6, webTop: nil, webBottom: 6)
            print("   mount \(m.rawValue): \(pat.label), shaft Ø\(String(format: "%.1f", m.shaftClearance * 2)), plate \(String(format: "%.1f", PrintedParts.motorMountPlate(m, foam: 6))) mm, tris cross \(mesh.triangles.count) wing \(wing.triangles.count) tailless \(tl.triangles.count), holes \(pat.positions.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) }.joined())")
            try? mesh.stlData(name: "mount").write(to: dir.appendingPathComponent("mount_\(m.rawValue)_cross.stl"))
            try? wing.stlData(name: "mount").write(to: dir.appendingPathComponent("mount_\(m.rawValue)_wing.stl"))
            // Render the cross mount alone, looking at the back of the firewall through the jaws, and at the motor face.
            for (tag, yaw) in [("back", Float(2.6)), ("front", Float(0.5))] {
                var sc = SceneData()
                sc.addMesh(mesh, color: SIMD4(0.55, 0.57, 0.62, 1))
                sc.center = [0, 0, 13]; sc.radius = 24
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(sc, resetCamera: true)
                    r.yaw = yaw; r.pitch = 0.3
                    if let img = r.snapshot(width: 600, height: 600) { savePNG(img, dir.appendingPathComponent("mount_\(m.rawValue)_\(tag).png")) }
                }
            }
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
            for part in PrintedParts.generate(d) where part.fileName.contains("motor_mount") || part.fileName.contains("nose_protector") {
                try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("dual_\(kind.rawValue)_\(part.fileName).stl"))
            }
        }
        for kind in AircraftKind.allCases {
            var c = kind.defaults
            c.tailWinglets = kind.hasTail; c.wingletHeight = 45
            c = Project.balanced(c)
            let d = DesignBuilder.build(c)
            let a = Analysis(design: d)
            print("   wl \(kind.title): AUW \(Int(a.totalMass)) g, winglets \(d.parts.contains { $0.role == .winglet }), ESCs \(d.components.filter { $0.name.hasPrefix("ESC") }.count), feasible \(a.feasible)")
            for ch in a.checks where ch.severity >= .warning { print("      [\(ch.severity)] \(ch.title): \(ch.detail)") }
            if kind == .trainer || kind == .jet {
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                    if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("wl_\(kind.rawValue)_3d.png")) }
                }
            }
        }
        // Close-ups of the motor area for visual checks.
        for (name, kind, dual) in [("trainer", AircraftKind.trainer, false), ("wing", .flyingWing, false), ("dualtrainer", .trainer, true), ("twin", .twinBoom, false), ("nutball", .nutBall, false), ("jet", .jet, false), ("delta", .delta, false), ("dualdelta", .delta, true), ("dualwing", .flyingWing, true), ("dualnose", .trainer, true)] {
            var c = kind.defaults; if dual { c.motorLayout = .dualTractor }
            c = Project.balanced(c)
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view) {
                r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                let x = Float(name == "dualnose" ? 0 : (c.motorXs.last ?? 0))
                r.target = SIMD3<Float>(x, 0, Float(name == "dualnose" ? -c.noseLength : c.firewallZ))
                r.zoom = 0.22; r.yaw = 0.9; r.pitch = 0.35
                if let img = r.snapshot(width: 1000, height: 700) { savePNG(img, dir.appendingPathComponent("close_\(name).png")) }
            }
        }
        // Propeller size / type / clearance per type.
        for kind in AircraftKind.allCases {
            for dual in [false, true] where !dual || kind.allowsDualMotors {
                var c = kind.defaults; if dual { c.motorLayout = .dualTractor }
                let a = Analysis(design: DesignBuilder.build(Project.balanced(c)))
                print("   prop \(kind.title)\(dual ? " dual" : ""): gap \(String(format: "%.1f", a.propGap)) mm, standoff \(String(format: "%.1f", c.mountStandoff)), \(c.propRecommendation), firewall \(String(format: "%.1f", c.firewallZ)), plane \(String(format: "%.1f", c.propPlaneZ))\(kind.isJet ? String(format: ", slot %.0f…%.0f ±%.0f", c.jetSlotFront, c.jetSlotRear, c.jetSlotHalfWidth) : ""), errors \(a.checks.filter { $0.severity == .error }.map(\.title))")
            }
        }
        // Wider fuselage cross and 800 mm span.
        for kind in [AircraftKind.trainer, .jet, .aerobat] {
            for extra in [0.0, 20, 40] {
                var c = kind.defaults; c.plateWidthExtra = extra
                c = Project.balanced(c)
                let a = Analysis(design: DesignBuilder.build(c))
                print("   cross \(kind.title) +\(Int(extra)) mm: plate \(Int(c.fuselagePlateWidth)) mm, twist \(String(format: "%.1f", a.structure?.tailTwistDeg ?? 0))°, AUW \(Int(a.totalMass)) g, feasible \(a.feasible)")
            }
        }
        for kind in AircraftKind.allCases {
            var c = kind.defaults; c.wingspan = 800
            c = Project.balanced(c)
            let a = Analysis(design: DesignBuilder.build(c))
            print("   span800 \(kind.title): AUW \(Int(a.totalMass)) g, score \(a.score), feasible \(a.feasible)" + a.checks.filter { $0.severity >= .warning }.map { " [\($0.title)]" }.joined())
        }
        // Jet side view: prop window in the fuselage with a frame above and below.
        do {
            let c = Project.balanced(AircraftKind.jet.defaults)
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view) {
                r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                r.target = SIMD3<Float>(0, 0, Float(c.jetPropZ)); r.zoom = 0.45; r.yaw = 1.45; r.pitch = 0.1
                if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("jet_side.png")) }
            }
            print("   jet window: fuselage \(Int(d.config.fuselageHeight)) mm (min \(Int(c.minFuselageHeight))), window ±\(Int(c.jetWindowHeight)) mm, prop gap \(String(format: "%.1f", a.propGap)) mm, feasible \(a.feasible)" + a.checks.filter { $0.severity >= .warning }.map { " [\($0.title)]" }.joined())
        }
        // Single aileron servo: standing servo + double arm, seen from above-behind.
        for kind in [AircraftKind.trainer, .aerobat, .glider] {
            var c = kind.defaults; c.aileronServos = 1
            c = Project.balanced(c)
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            print("   1-servo \(kind.title): \(d.controls.surfaceCount) surfaces, \(Set(d.controls.map(\.servoID)).count) servos, \(d.channels) ch, feasible \(a.feasible)" + d.geometryIssues.map { " [\($0)]" }.joined())
            if kind == .trainer {
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                    r.target = SIMD3<Float>(0, -15, 50); r.zoom = 0.22; r.yaw = 2.5; r.pitch = -0.6
                    if let img = r.snapshot(width: 1000, height: 700) { savePNG(img, dir.appendingPathComponent("aileron_single.png")) }
                }
            }
        }
        do {
            let d = DesignBuilder.build(Project.balanced(AircraftKind.trainer.defaults)); let a = Analysis(design: d)
            print("   weight rows: " + WeightBars.groups(d, a).map { "\($0.label) \(String(format: "%.1f", $0.mass))" }.joined(separator: " | "))
        }
        // Automatic power system per type (and after making the trainer heavier).
        do {
            let t0 = Date()
            for kind in AircraftKind.allCases {
                if let r = PowerOptimizer.best(for: kind.defaults) {
                    print("   power \(kind.title): \(r.config.motor.rawValue) + \(r.config.battery.name), \(r.config.propRecommendation), T/W \(String(format: "%.2f", r.analysis.thrustToWeight)) (target \(String(format: "%.2f", kind.recommendedThrustToWeight))), AUW \(Int(r.analysis.totalMass)) g, \(Int(r.analysis.flightTime)) min, score \(r.analysis.score)")
                } else { print("   power \(kind.title): none") }
            }
            var heavy = AircraftKind.trainer.defaults; heavy.material = .depron10; heavy.wingspan = 800
            if let r = PowerOptimizer.best(for: heavy) {
                print("   power trainer 800/10mm: \(r.config.motor.rawValue) + \(r.config.battery.name), T/W \(String(format: "%.2f", r.analysis.thrustToWeight)), AUW \(Int(r.analysis.totalMass)) g")
            }
            print("   power search: \(String(format: "%.2f", Date().timeIntervalSince(t0) / 9)) s per search")
        }
        // Rounded wing tips, fin/rudder top and elevator tips on the tailed types.
        for kind in AircraftKind.allCases where kind.hasTail {
            var c = kind.defaults; c.wingTipRounding = 30; c.finTopRounding = 25; c.stabTipRounding = 20
            c = Project.balanced(c)
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            let bad = d.parts.filter { !Poly.isSimple($0.outline) }.map(\.name)
            print("   rounded \(kind.title): feasible \(a.feasible), score \(a.score), outline points \(d.parts.map { $0.outline.count }.reduce(0, +))\(bad.isEmpty ? "" : ", NOT SIMPLE: \(bad)")" + d.geometryIssues.map { " [\($0)]" }.joined())
            if kind == .trainer || kind == .twinBoom || kind == .jet {
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(SceneBuilder.aircraft(d, a, deflection: 0.3, showCG: false), resetCamera: true)
                    if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("rounded_\(kind.rawValue).png")) }
                }
            }
        }
        // Printed nose cap and control horn on their own, and the receiver channel plans.
        do {
            var c = AircraftKind.trainer.defaults; c.motorLayout = .dualTractor
            for (name, mesh, center, rad) in [("nosecap", PrintedParts.noseProtector(for: c), SIMD3<Float>(0, 0, 4), Float(28)),
                                              ("horn", PrintedParts.controlHorn(foam: 6).transformed { SIMD3<Double>($0.x, $0.z, $0.y) }, SIMD3<Float>(0, 3, 0), Float(14))] {
                var sc = SceneData(); sc.addMesh(mesh, color: SIMD4(0.55, 0.6, 0.68, 1)); sc.center = center; sc.radius = rad
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(sc, resetCamera: true); r.yaw = name == "horn" ? 1.2 : 2.5; r.pitch = 0.4
                    if let img = r.snapshot(width: 700, height: 600) { savePNG(img, dir.appendingPathComponent("part_\(name).png")) }
                }
                try? mesh.stlData(name: name).write(to: dir.appendingPathComponent("part_\(name).stl"))
            }
            for t in [3.0, 5, 6, 10] {
                var cc = AircraftKind.trainer.defaults; cc.motorLayout = .dualTractor
                cc.material = FoamMaterial.allCases.first { $0.family == .depron && $0.thickness == t }!
                try? PrintedParts.noseProtector(for: cc).stlData(name: "cap").write(to: dir.appendingPathComponent("part_nosecap_\(Int(t))mm.stl"))
                try? PrintedParts.controlHorn(foam: t).stlData(name: "horn").write(to: dir.appendingPathComponent("part_horn_\(Int(t))mm.stl"))
            }
            for kind in AircraftKind.allCases {
                let d = DesignBuilder.build(kind.defaults)
                print("   channels \(kind.title): " + d.channelPlan.map { "CH\($0.channel) \($0.function)" }.joined(separator: ", "))
            }
        }
        // Tail close-ups from the side with the elevator up: the rudder cut-out must clear it.
        for kind in [AircraftKind.trainer, .jet, .nutBall] {
            let c = Project.balanced(kind.defaults)
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view), let el = d.controls.first(where: { $0.name == "Elevator" }) {
                r.setScene(SceneBuilder.aircraft(d, a, deflection: -0.75, showCG: false), resetCamera: true)
                r.target = SIMD3<Float>(0, 15, Float(el.hingeMid.z) + 15)
                r.zoom = 0.2; r.yaw = 1.75; r.pitch = 0.12
                if let img = r.snapshot(width: 1000, height: 700) { savePNG(img, dir.appendingPathComponent("tail_\(kind.rawValue).png")) }
            }
        }
        // Hover picking: probe a grid of points over the trainer and list what is under them.
        do {
            let d = DesignBuilder.build(Project.balanced(AircraftKind.trainer.defaults)); let a = Analysis(design: d)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
            if let r = Renderer(view: view) {
                r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: true), resetCamera: true)
                var seen = Set<String>()
                for gy in stride(from: 100.0, through: 400, by: 12) {
                    for gx in stride(from: 100.0, through: 700, by: 12) {
                        if let n = r.pick(CGPoint(x: gx, y: gy), in: CGSize(width: 800, height: 500)) { seen.insert(n) }
                    }
                }
                print("   hover names (\(seen.count)): " + seen.sorted().joined(separator: " | "))
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
