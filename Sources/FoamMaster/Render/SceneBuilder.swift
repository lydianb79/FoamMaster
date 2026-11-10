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
    static let battery = SIMD4<Float>(0.98, 0.82, 0.2, 1)
    static let servo = SIMD4<Float>(0.2, 0.45, 0.95, 1)
    static let printed = SIMD4<Float>(0.35, 0.95, 0.75, 1)
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
        for item in d.components {
            let p = item.position
            switch item.category {
            case "Battery":
                let s = d.config.battery.size
                let size: SIMD3<Double> = [s.h, s.w, s.l]
                let offset: SIMD3<Double> = [d.config.material.thickness / 2 + s.h / 2, 0, 0]
                scene.addMesh(.box(min: p + offset - size / 2, max: p + offset + size / 2), color: Palette.battery)
            case "Power" where item.name.contains("brushless"):
                let r = d.config.motor.bellDiameter / 2
                scene.addMesh(cylinder(center: p, radius: r, length: r * 1.1), color: Palette.motor)
                // Prop disc hint
                let pr = d.config.motor.propInches * 25.4 / 2
                let z = p.z + (d.config.kind.isPusher ? r * 0.9 : -r * 0.9)
                for k in 0..<48 {
                    let a0 = Double(k) / 48 * 2 * .pi, a1 = Double(k + 1) / 48 * 2 * .pi
                    scene.addLine([cos(a0) * pr, sin(a0) * pr, z], [cos(a1) * pr, sin(a1) * pr, z], color: SIMD4(1, 1, 1, 0.25))
                }
                scene.addMesh(Mesh3D.box(min: [-pr, -3, z - 0.6], max: [pr, 3, z + 0.6]).rotated(0.5, axis: [0, 0, 1]), color: SIMD4(0.15, 0.15, 0.18, 1))
            default:
                if item.name.hasPrefix("Servo") {
                    let s = d.config.servo.size
                    let vertical = !(d.config.kind.isTailless || item.name.contains("aileron") || item.name.contains("Aileron"))
                    let size: SIMD3<Double> = vertical ? [s.w, s.h, s.l] : [s.w, s.h, s.l]
                    scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.servo)
                }
            }
        }
        for ctrl in d.controls { scene.addLine(ctrl.servoPosition, ctrl.hornPosition, color: SIMD4(0.9, 0.9, 0.95, 0.8)) }

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
