import Foundation
import simd

struct GPUVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>   // w = 1 → lit, 0 → unlit
    var color: SIMD4<Float>
}

struct SceneData {
    var triangles: [GPUVertex] = []
    var lines: [GPUVertex] = []
    var center = SIMD3<Float>.zero
    var radius: Float = 300

    mutating func addTriangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, color: SIMD4<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let nf = SIMD4<Float>(Float(n.x), Float(n.y), Float(n.z), 1)
        for p in [a, b, c] {
            triangles.append(GPUVertex(position: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1), normal: nf, color: color))
        }
    }

    mutating func addLine(_ a: SIMD3<Double>, _ b: SIMD3<Double>, color: SIMD4<Float>) {
        for p in [a, b] {
            lines.append(GPUVertex(position: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1), normal: .zero, color: color))
        }
    }

    mutating func addMesh(_ m: Mesh3D, color: SIMD4<Float>) {
        for t in m.triangles where simd_length(simd_cross(t.1 - t.0, t.2 - t.0)) > 1e-9 { addTriangle(t.0, t.1, t.2, color: color) }
    }

    mutating func fitBounds() {
        guard !triangles.isEmpty else { return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for v in triangles { let p = SIMD3<Float>(v.position.x, v.position.y, v.position.z); lo = simd_min(lo, p); hi = simd_max(hi, p) }
        center = (lo + hi) / 2
        radius = max(simd_length(hi - lo) / 2, 20)
    }
}

enum Palette {
    static let depron = SIMD4<Float>(0.93, 0.94, 0.97, 1)
    static let epp = SIMD4<Float>(0.62, 0.80, 0.95, 1)
    static let control = SIMD4<Float>(1.0, 0.52, 0.18, 1)
    static let carbon = SIMD4<Float>(0.08, 0.08, 0.1, 1)
    static let motor = SIMD4<Float>(0.75, 0.2, 0.25, 1)
    static let battery = SIMD4<Float>(0.62, 0.42, 0.95, 1)
    static let servo = SIMD4<Float>(0.2, 0.45, 0.95, 1)
    static let printed = SIMD4<Float>(0.07, 0.07, 0.08, 1)
    static let vtx = SIMD4<Float>(0.2, 0.75, 0.45, 1)
    static let prop = SIMD4<Float>(1.0, 0.82, 0.1, 1)
    static let cg = SIMD4<Float>(1.0, 0.2, 0.6, 1)
    static let edge = SIMD4<Float>(0.1, 0.12, 0.18, 0.55)
    static let grid = SIMD4<Float>(0.4, 0.7, 1.0, 0.12)
}

enum SceneBuilder {
    static func aircraft(_ d: Design, _ a: Analysis?, deflection: Double, showCG: Bool) -> SceneData {
        var scene = SceneData()
        let base = d.config.material.family == .depron ? Palette.depron : Palette.epp

        for part in d.parts {
            let regions = part.regions.isEmpty ? [Region(polygon: part.outline, isControl: false)] : part.regions
            let mainRegion = regions.first { !$0.isControl }?.polygon ?? part.outline
            let mainOutline = part.regions.isEmpty ? part.outline : outlineWithNotches(part, main: mainRegion)
            for inst in part.instances {
                for r in regions {
                    let poly = r.isControl ? r.polygon : mainOutline
                    let holes = part.holes.map(\.polygon).filter { Poly.contains(r.polygon, Poly.centroid($0)) }
                    var transform: (SIMD3<Double>) -> SIMD3<Double> = { $0 }
                    if r.isControl, deflection != 0, let axis = hingeAxis(part, r.polygon) {
                        let a3 = inst.point(axis.0), b3 = inst.point(axis.1)
                        var angle = deflection * 0.45
                        let probe = inst.point(Poly.centroid(r.polygon))
                        let q = simd_quatd(angle: angle, axis: simd_normalize(b3 - a3))
                        if abs(inst.normal.y) > 0.5, (q.act(probe - a3) + a3).y < probe.y { angle = -angle }
                        let qq = simd_quatd(angle: angle, axis: simd_normalize(b3 - a3))
                        transform = { qq.act($0 - a3) + a3 }
                    }
                    addSlab(&scene, poly, holes: holes, placement: inst, thickness: part.thickness,
                            color: r.isControl ? Palette.control : base, transform: transform)
                }
            }
            // Carbon spars
            for f in part.features {
                if case let .spar(p0, p1, _) = f, d.config.sparEnabled {
                    for inst in part.instances {
                        let off = part.thickness / 2 + 0.3
                        scene.addLine(inst.point(p0, offset: -off), inst.point(p1, offset: -off), color: Palette.carbon)
                    }
                }
            }
        }

        // Components
        let c = d.config
        for item in d.components {
            let p = item.position
            switch item.category {
            case "Battery":
                let s = c.battery.size
                let size: SIMD3<Double> = c.kind.isTailless ? [s.w, s.h, s.l] : [s.h, s.w, s.l]
                scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.battery)
            case "Power" where item.name.contains("brushless"):
                let right = item.position.x > 0.1
                let r = c.motor.bellDiameter / 2
                let out: Double = c.isPusher ? 1 : -1          // direction from firewall towards the prop
                scene.addMesh(cylinder(center: p, radius: r, length: c.motorLength * 0.85), color: Palette.motor)
                // Shaft from the bell to the prop hub.
                let shaftEnd = c.propPlaneZ
                scene.addMesh(cylinder(center: [p.x, 0, (p.z + out * c.motorLength * 0.42 + shaftEnd) / 2], radius: 1.2,
                                       length: abs(shaftEnd - (p.z + out * c.motorLength * 0.42)) + 1), color: SIMD4(0.75, 0.75, 0.78, 1))
                let pr = c.motor.propInches * 25.4 / 2
                let z = c.propPlaneZ
                for k in 0..<48 {
                    let a0 = Double(k) / 48 * 2 * .pi, a1 = Double(k + 1) / 48 * 2 * .pi
                    scene.addLine([p.x + cos(a0) * pr, sin(a0) * pr, z], [p.x + cos(a1) * pr, sin(a1) * pr, z], color: SIMD4(1, 1, 1, 0.25))
                }
                // Counter-rotating pair: the right-hand prop is the mirror image of the left one.
                scene.addMesh(propeller(radius: pr, blades: c.kind.propBlades, z: z, hub: r * 0.45, outward: out, mirrored: c.isPusher != right)
                                .translated([p.x, 0, 0]), color: Palette.prop)
            case "FPV":
                if item.name.hasPrefix("FPV camera") {
                    let w = c.fpv.cameraWidth
                    scene.addMesh(.box(min: p - [w / 2, w / 2, w / 2], max: p + [w / 2, w / 2, w / 2]), color: Palette.carbon)
                    scene.addMesh(cylinder(center: p - [0, 0, w / 2 + 2], radius: w * 0.3, length: 4), color: SIMD4(0.3, 0.35, 0.45, 1))
                } else {
                    let v = c.fpv.vtxSize
                    let size: SIMD3<Double> = c.kind.isTailless ? [v.w, v.h, v.l] : [v.h, v.w, v.l]
                    scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.vtx)
                    scene.addLine(p, p + [0, 30, 6], color: SIMD4(0.9, 0.9, 0.95, 0.9))
                }
            case "Printed":
                let size: SIMD3<Double>
                if item.name.hasPrefix("Horn") { continue }   // drawn with its linkage below
                if item.name.hasPrefix("Motor mount") { let m = c.motor.bellDiameter * 0.8; size = [m, m, 6] }
                else if item.name.hasPrefix("Camera mount") { size = [c.fpv.cameraWidth + 3, 2, 16] }
                else { size = [40, 2, 20] }
                scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.printed)
            case "Radio" where item.name.hasPrefix("AIO"):
                let b = AIOController.boardSize
                let size: SIMD3<Double> = c.kind.isTailless ? [b, 1.6, b] : [1.6, b, b]
                scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: SIMD4(0.1, 0.45, 0.25, 1))
            case "Hardware" where item.name.hasPrefix("Tail booms"):
                let len = c.tailArm + c.hStabChord * 0.55 - c.rootChord * 0.15
                for x in [-c.boomX, c.boomX] {
                    scene.addMesh(cylinder(center: [x, p.y, p.z], radius: 2, length: len, segments: 10), color: Palette.carbon)
                }
            default:
                if item.name.hasPrefix("Servo") {
                    let s = c.servo.size
                    // H sideways (shaft axis), W vertical, L fore-aft – see DesignBuilder.armTip.
                    let size: SIMD3<Double> = [s.h, s.w, s.l]
                    scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.servo)
                }
            }
        }
        // Linkages: servo arm (white), pushrod, and the printed horn standing out of the surface.
        for ctrl in d.controls {
            let arm = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
            let shaft = arm - [0, 10, 0]
            scene.addMesh(.box(min: simd_min(shaft, arm) - [0.8, 0, 2], max: simd_max(shaft, arm) + [0.8, 0, 2]), color: SIMD4(0.95, 0.95, 0.95, 1))
            scene.addLine(arm, ctrl.hornPosition, color: SIMD4(0.9, 0.9, 0.95, 0.9))
            let a = ctrl.hornAxis
            let base = ctrl.hornPosition - a * 9
            let lo = simd_min(base, ctrl.hornPosition), hi = simd_max(base, ctrl.hornPosition)
            // Horn plate lies in the plane of the pushrod motion (contains the horn axis and the flight direction).
            let thin: SIMD3<Double> = abs(a.y) > 0.5 ? [0.7, 0, 0] : [0, 0.7, 0]
            scene.addMesh(.box(min: lo - thin - [0, 0, 5], max: hi + thin + [0, 0, 5]), color: Palette.printed)
        }

        scene.fitBounds()

        if showCG, let a {
            scene.addMesh(sphere(center: a.cg, radius: 6), color: Palette.cg)
            let rc: SIMD3<Double> = [0, a.cg.y, a.recommendedCG]
            scene.addLine(rc + [-60, 0, 0], rc + [60, 0, 0], color: SIMD4(0.3, 1, 0.6, 0.9))
            scene.addLine([-70, a.cg.y, a.cgRange.lowerBound], [70, a.cg.y, a.cgRange.lowerBound], color: SIMD4(0.3, 1, 0.6, 0.35))
            scene.addLine([-70, a.cg.y, a.cgRange.upperBound], [70, a.cg.y, a.cgRange.upperBound], color: SIMD4(0.3, 1, 0.6, 0.35))
            scene.addLine(a.cg + [0, -80, 0], a.cg + [0, 40, 0], color: SIMD4(1, 0.3, 0.7, 0.6))
        }
        addGrid(&scene, y: Double(scene.center.y - scene.radius * 0.55))
        return scene
    }

    static func printed(_ parts: [PrintedPart]) -> SceneData {
        var scene = SceneData()
        var x = 0.0
        for p in parts {
            let b = p.mesh.bounds
            let m = p.mesh.rotated(-.pi / 2, axis: [1, 0, 0]).translated([x - b.min.x, 0, 0])
            scene.addMesh(m, color: Palette.printed)
            x += (b.max.x - b.min.x) + 10
        }
        scene.fitBounds()
        addGrid(&scene, y: Double(scene.center.y - scene.radius * 0.6), spacing: 10, extent: 12)
        return scene
    }

    // MARK: Helpers

    static func outlineWithNotches(_ part: Part, main: [Vec2]) -> [Vec2] { main }

    static func hingeAxis(_ part: Part, _ region: [Vec2]) -> (Vec2, Vec2)? {
        var best: (Vec2, Vec2)?
        var bestD = Double.greatestFiniteMagnitude
        for f in part.features {
            guard case let .hinge(a, b) = f else { continue }
            let m = (a + b) / 2
            let d = region.map { simd_distance($0, m) }.min() ?? .greatestFiniteMagnitude
            let inside = Poly.contains(region, m) ? 0.0 : d
            if inside < bestD { bestD = inside; best = (a, b) }
        }
        return best
    }

    static func addSlab(_ scene: inout SceneData, _ poly: [Vec2], holes: [[Vec2]], placement p: Placement, thickness t: Double,
                        color: SIMD4<Float>, transform: (SIMD3<Double>) -> SIMD3<Double>) {
        let mesh = Mesh3D.extrude(poly, holes: holes, z0: -t / 2, z1: t / 2)
        let n = p.normal
        let mapped = mesh.transformed { q in transform(p.origin + p.u * q.x + p.v * q.y + n * q.z) }
        scene.addMesh(mapped, color: color)
        for loop in [Poly.ccw(poly)] + holes {
            for side in [-t / 2, t / 2] {
                for i in 0..<loop.count {
                    scene.addLine(transform(p.point(loop[i], offset: side * 1.01)), transform(p.point(loop[(i + 1) % loop.count], offset: side * 1.01)), color: Palette.edge)
                }
            }
        }
    }

    static func addGrid(_ scene: inout SceneData, y: Double, spacing: Double = 50, extent: Int = 10) {
        let c = scene.center
        let cx = (Double(c.x) / spacing).rounded() * spacing, cz = (Double(c.z) / spacing).rounded() * spacing
        let e = Double(extent) * spacing
        for i in -extent...extent {
            let o = Double(i) * spacing
            let col = i == 0 ? SIMD4<Float>(0.4, 0.7, 1, 0.3) : Palette.grid
            scene.addLine([cx + o, y, cz - e], [cx + o, y, cz + e], color: col)
            scene.addLine([cx - e, y, cz + o], [cx + e, y, cz + o], color: col)
        }
    }

    /// Propeller: spinner + n blades with a realistic planform (narrow root, widest at ~35 % radius,
    /// rounded tip) and pitch – each blade is twisted from ~35° at the root to ~12° at the tip.
    /// `outward` = direction (±z) the spinner points (away from the motor). Pusher props are the mirror image
    /// of tractor props (reverse rotation), so `mirrored` flips the blade handedness.
    static func propeller(radius R: Double, blades n: Int, z: Double, hub: Double, outward: Double = -1, mirrored: Bool = false) -> Mesh3D {
        var m = Mesh3D()
        let stations: [(r: Double, chord: Double)] = [(0.12, 0.13), (0.25, 0.2), (0.38, 0.22), (0.55, 0.19), (0.72, 0.15), (0.88, 0.1), (0.97, 0.06), (1.0, 0.02)]
        let thick = max(0.6, R * 0.012)
        for b in 0..<n {
            let phi = Double(b) / Double(n) * 2 * .pi + 0.4
            var lead: [SIMD3<Double>] = [], trail: [SIMD3<Double>] = []
            for st in stations {
                let r = st.r * R, ch = st.chord * R
                let pitch = (35 - 23 * st.r) * .pi / 180
                // Blade section in the local frame: x = radius, chord line tilted by the pitch angle about x.
                let half = ch / 2
                let mx: Double = mirrored ? -1 : 1
                let le = SIMD3<Double>(r * mx, half * cos(pitch), -half * sin(pitch) * outward * -1)
                let te = SIMD3<Double>(r * mx, -half * cos(pitch), half * sin(pitch) * outward * -1)
                lead.append(le); trail.append(te)
            }
            let rot = simd_quatd(angle: phi, axis: [0, 0, 1])
            func w(_ p: SIMD3<Double>, _ off: Double) -> SIMD3<Double> { rot.act(p + [0, 0, off]) + [0, 0, z] }
            for i in 0..<(stations.count - 1) {
                for off in [-thick / 2, thick / 2] {
                    m.triangles.append((w(lead[i], off), w(trail[i], off), w(trail[i + 1], off)))
                    m.triangles.append((w(lead[i], off), w(trail[i + 1], off), w(lead[i + 1], off)))
                }
                // leading and trailing edge walls
                m.triangles.append((w(lead[i], -thick / 2), w(lead[i + 1], -thick / 2), w(lead[i + 1], thick / 2)))
                m.triangles.append((w(trail[i], -thick / 2), w(trail[i + 1], thick / 2), w(trail[i + 1], -thick / 2)))
            }
        }
        m.append(cylinder(center: [0, 0, z], radius: hub, length: R * 0.12))
        // Spinner: nose cone on the outward side of the hub.
        let tipZ = z + outward * hub * 0.8
        var spinner = sphere(center: [0, 0, tipZ], radius: hub)
        spinner = spinner.transformed { p in [p.x, p.y, tipZ + (p.z - tipZ) * (((p.z - tipZ) * outward) > 0 ? 1.8 : 0.4)] }
        m.append(spinner)
        return m
    }

    static func cylinder(center c: SIMD3<Double>, radius r: Double, length l: Double, segments n: Int = 24) -> Mesh3D {
        Mesh3D.extrude(Poly.circle(.zero, r, segments: n), z0: -l / 2, z1: l / 2).translated(c)
    }

    static func sphere(center c: SIMD3<Double>, radius r: Double) -> Mesh3D {
        var m = Mesh3D()
        let st = 10, sl = 16
        func p(_ i: Int, _ j: Int) -> SIMD3<Double> {
            let th = Double(i) / Double(st) * .pi, ph = Double(j) / Double(sl) * 2 * .pi
            return c + [sin(th) * cos(ph), cos(th), sin(th) * sin(ph)] * r
        }
        for i in 0..<st {
            for j in 0..<sl {
                m.triangles.append((p(i, j), p(i + 1, j + 1), p(i + 1, j)))
                m.triangles.append((p(i, j), p(i, j + 1), p(i + 1, j + 1)))
            }
        }
        return m
    }
}
