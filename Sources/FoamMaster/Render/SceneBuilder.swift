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
    /// Name of what is being added – every triangle remembers it so the 3D view can say what is under the mouse.
    var label = ""
    var triLabels: [Int32] = []
    var labelNames: [String] = []
    private var labelLookup: [String: Int32] = [:]

    mutating func addTriangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, color: SIMD4<Float>) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let nf = SIMD4<Float>(Float(n.x), Float(n.y), Float(n.z), 1)
        for p in [a, b, c] {
            triangles.append(GPUVertex(position: SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1), normal: nf, color: color))
        }
        let name = label.isEmpty ? (Palette.name(for: color) ?? "") : label
        if let i = labelLookup[name] { triLabels.append(i) } else {
            let i = Int32(labelNames.count)
            labelNames.append(name); labelLookup[name] = i; triLabels.append(i)
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
    static let carbon = SIMD4<Float>(0.24, 0.26, 0.32, 1)
    static let strutLine = SIMD4<Float>(0.72, 0.76, 0.86, 1)
    static let motor = SIMD4<Float>(0.75, 0.2, 0.25, 1)
    static let battery = SIMD4<Float>(0.62, 0.42, 0.95, 1)
    static let servo = SIMD4<Float>(0.2, 0.45, 0.95, 1)
    static let printed = SIMD4<Float>(0.07, 0.07, 0.08, 1)
    static let prop = SIMD4<Float>(1.0, 0.82, 0.1, 1)
    static let esc = SIMD4<Float>(0.2, 0.82, 0.35, 1)
    static let receiver = SIMD4<Float>(0.1, 0.85, 0.92, 1)
    static let linkage = SIMD4<Float>(0.95, 0.95, 0.95, 1)
    static let armDetail = SIMD4<Float>(0.55, 0.57, 0.62, 1)
    static let steel = SIMD4<Float>(0.80, 0.83, 0.88, 1)
    /// Pushrod carbon rod – lighter than the structural carbon so the thin rods stay visible from a distance.
    static let pushrod = SIMD4<Float>(0.58, 0.62, 0.72, 1)
    static let heatShrink = SIMD4<Float>(0.86, 0.30, 0.22, 1)
    static let cg = SIMD4<Float>(1.0, 0.2, 0.6, 1)
    static let edge = SIMD4<Float>(0.1, 0.12, 0.18, 0.55)
    static let grid = SIMD4<Float>(0.4, 0.7, 1.0, 0.12)

    static func name(for c: SIMD4<Float>) -> String? {
        let all: [(SIMD4<Float>, String)] = [(depron, "Foam"), (epp, "Foam"), (control, "Control surface"), (carbon, "Carbon"), (motor, "Motor"),
                                             (battery, "Battery"), (servo, "Servo"), (printed, "Printed part"), (prop, "Propeller"),
                                             (esc, "ESC"), (receiver, "Receiver"), (linkage, "Servo arm"), (steel, "Pushrod"), (pushrod, "Pushrod"), (heatShrink, "Pushrod"), (armDetail, "Servo arm"), (cg, "Centre of gravity")]
        return all.first { $0.0 == c }?.1
    }
}

enum SceneBuilder {
    static func aircraft(_ d: Design, _ a: Analysis?, deflection: Double, showCG: Bool) -> SceneData {
        var scene = SceneData()
        let base = d.config.material.family == .depron ? Palette.depron : Palette.epp

        // Surface preview: the slider is one coherent control input – positive = pull and turn left: elevator and
        // elevons trailing edge up, left aileron up / right aileron down, rudder trailing edge to the left – up to the
        // type's maximum throw. Every moved surface is remembered so its horn, pushrod and servo arm follow.
        let maxThrow = d.config.kind.maxSurfaceThrow * .pi / 180
        var moves: [SurfaceMove] = []
        for part in d.parts {
            let regions = part.regions.isEmpty ? [Region(polygon: part.outline, isControl: false)] : part.regions
            let mainRegion = regions.first { !$0.isControl }?.polygon ?? part.outline
            let mainOutline = part.regions.isEmpty ? part.outline : outlineWithNotches(part, main: mainRegion)
            for inst in part.instances {
                for r in regions {
                    scene.label = r.isControl ? controlName(part, d.config) : "\(part.name) – \(d.config.material.displayName)"
                    // Control surfaces are drawn slightly inset so the hinge and side gaps are visible.
                    let poly = r.isControl ? Poly.inset(r.polygon, by: 0.6) : mainOutline
                    let holes = part.holes.map(\.polygon).filter { Poly.contains(r.polygon, Poly.centroid($0)) }
                    var transform: (SIMD3<Double>) -> SIMD3<Double> = { $0 }
                    if r.isControl, deflection != 0, let axis = hingeAxis(part, r.polygon) {
                        let a3 = inst.point(axis.0), b3 = inst.point(axis.1)
                        let probe = inst.point(Poly.centroid(r.polygon))
                        let test = simd_quatd(angle: 0.1, axis: simd_normalize(b3 - a3))
                        let moved = test.act(probe - a3) + a3
                        // Sign of a positive rotation about this hinge line for the wanted motion.
                        let horizontal = abs(inst.normal.y) > 0.5
                        let aileron = horizontal && part.role == .wing && d.config.kind.hasTail && !d.config.kind.isNutBall
                        var sense: Double
                        if horizontal {
                            sense = moved.y > probe.y ? 1 : -1                      // trailing edge up
                            if aileron && probe.x > 0 { sense = -sense }            // right aileron down
                        } else {
                            sense = moved.x < probe.x ? 1 : -1                      // trailing edge to the left
                        }
                        let qq = simd_quatd(angle: sense * deflection * maxThrow, axis: simd_normalize(b3 - a3))
                        transform = { qq.act($0 - a3) + a3 }
                        moves.append(SurfaceMove(a: a3, b: b3, q: qq, normal: inst.normal))
                    }
                    addSlab(&scene, poly, holes: holes, placement: inst, thickness: part.thickness,
                            color: r.isControl ? Palette.control : base, transform: transform)
                }
            }
            // Carbon: wing spars (if enabled), truss strips, boom grooves, X-bracing – drawn as strips on both faces.
            for f in part.features {
                if case let .rod(p0, p1, dia) = f {
                    // Rod in its groove under the wing: drawn 0.3 mm proud of the underside so it shows from below
                    // (flush it would flicker with the foam), plus a thin dark band on the top surface along the
                    // spar line so the spar is also visible from above.
                    scene.label = "Carbon rod spar – \(d.config.sparSpec.name), groove underneath"
                    for inst in part.instances {
                        // Offsets along the WORLD up direction: mirrored wing halves have a downward placement normal.
                        let flip: Double = inst.normal.y < 0 ? -1 : 1
                        let up = inst.normal * flip
                        let off = (-part.thickness / 2 + dia / 2 - 0.3) * flip
                        let a3 = inst.point(p0, offset: off), b3 = inst.point(p1, offset: off)
                        let dir = simd_normalize(b3 - a3), side = simd_normalize(simd_cross(dir, up))
                        let rod = Mesh3D.extrude(Poly.circle(.zero, dia / 2, segments: 12), z0: 0, z1: simd_distance(a3, b3))
                            .transformed { p in a3 + side * p.x + up * p.y + dir * p.z }
                        scene.addMesh(rod, color: Palette.carbon)
                        let ta = inst.point(p0, offset: part.thickness / 2 * flip), tb = inst.point(p1, offset: part.thickness / 2 * flip)
                        scene.addMesh(strip(from: ta, to: tb, normal: up, width: dia, height: 0.25), color: SIMD4(0.12, 0.13, 0.16, 1))
                    }
                    continue
                }
                guard case let .spar(p0, p1, width) = f else { continue }
                let w = max(width, 1.6)
                scene.label = "Carbon boom groove – \(CarbonSpar.tube4.name)"
                for inst in part.instances {
                    for side in [-1.0, 1.0] {
                        let a = inst.point(p0, offset: side * part.thickness / 2), b = inst.point(p1, offset: side * part.thickness / 2)
                        scene.addMesh(strip(from: a, to: b, normal: inst.normal * side, width: w), color: Palette.carbon)
                    }
                }
            }
        }

        // Components – printed parts use the same meshes as the exported STLs.
        let c = d.config
        let t = c.material.thickness
        let tw = t * Double(c.fuselageType.webLayers)
        for item in d.components {
            let p = item.position
            scene.label = item.name
            switch item.category {
            case "Battery":
                let s = c.battery.size
                // Printed tray between foam and battery, battery sits on it.
                if c.kind.isTailless {
                    let down: Double = 1
                    let tray = Mesh3D.box(min: [-s.w / 2 - 1.2, -0.6, -s.l / 2 - 2], max: [s.w / 2 + 1.2, 0.6, s.l / 2 + 2])
                    scene.label = "Battery tray (printed)"
                    scene.addMesh(tray.translated([p.x, down * (t / 2 + 0.6), p.z]), color: Palette.printed)
                    let q = p + [0, down * 1.2, 0]
                    scene.label = "Battery – \(c.battery.name), \(Int(c.battery.mass)) g"
                    scene.addMesh(.box(min: q - [s.w, s.h, s.l] / 2, max: q + [s.w, s.h, s.l] / 2), color: Palette.battery)
                } else {
                    let tray = Mesh3D.box(min: [-0.6, -s.w / 2 - 1.2, -s.l / 2 - 2], max: [0.6, s.w / 2 + 1.2, s.l / 2 + 2])
                    scene.label = "Battery tray (printed)"
                    scene.addMesh(tray.translated([tw / 2 + 0.6, p.y, p.z]), color: Palette.printed)
                    let q = p + [1.2, 0, 0]
                    scene.label = "Battery – \(c.battery.name), \(Int(c.battery.mass)) g"
                    scene.addMesh(.box(min: q - [s.h, s.w, s.l] / 2, max: q + [s.h, s.w, s.l] / 2), color: Palette.battery)
                }
            case "Power" where item.name.contains("brushless"):
                let right = item.position.x > 0.1
                let r = c.motor.bellDiameter / 2
                let out: Double = c.isPusher ? 1 : -1          // direction from firewall towards the prop
                let fw = c.firewallZ, L = c.motorLength
                // Stator base on the firewall, rotating bell, shaft to the prop hub.
                scene.label = "Motor – \(c.motor.name), \(c.motor.pattern.label) mount pattern"
                scene.addMesh(cylinder(center: [p.x, 0, fw + out * L * 0.15], radius: r * 0.82, length: L * 0.3), color: SIMD4(0.25, 0.25, 0.28, 1))
                scene.addMesh(cylinder(center: [p.x, 0, fw + out * L * 0.62], radius: r, length: L * 0.64), color: Palette.motor)
                let shaftStart = fw + out * L * 0.94, shaftEnd = c.propPlaneZ
                scene.addMesh(cylinder(center: [p.x, 0, (shaftStart + shaftEnd) / 2], radius: 1.2, length: abs(shaftEnd - shaftStart) + 1),
                              color: SIMD4(0.75, 0.75, 0.78, 1))
                let pr = c.propRadius
                let z = c.propPlaneZ
                for k in 0..<48 {
                    let a0 = Double(k) / 48 * 2 * .pi, a1 = Double(k + 1) / 48 * 2 * .pi
                    scene.addLine([p.x + cos(a0) * pr, sin(a0) * pr, z], [p.x + cos(a1) * pr, sin(a1) * pr, z], color: SIMD4(1, 1, 1, 0.25))
                }
                // Counter-rotating pair: the right-hand prop is the mirror image of the left one.
                scene.label = "Propeller – \(c.propRecommendation)"
                scene.addMesh(propeller(radius: pr, blades: c.kind.propBlades, z: z, hub: r * 0.45, outward: out, mirrored: c.isPusher != right)
                                .translated([p.x, 0, 0]), color: Palette.prop)
            case "Power" where item.name.hasPrefix("ESC"):
                let e: SIMD3<Double> = c.motor.escMass > 4 ? [24, 13, 5] : [18, 10, 4]
                scene.label = "\(item.name) – \(c.motor.escMass > 4 ? 12 : 6) A brushless ESC, \(c.battery.cells)S"
                // Flat under a wing, or flat against the fuselage side.
                let size: SIMD3<Double> = (c.isDual || c.kind.isTailless) ? [e.y, e.z, e.x] : [e.z, e.y, e.x]
                scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.esc)
                scene.addLine(p, [c.motorXs.min(by: { abs($0 - p.x) < abs($1 - p.x) }) ?? 0, 0, c.motorZ], color: SIMD4(0.9, 0.3, 0.3, 0.8))
            case "Radio" where item.name.hasPrefix("Receiver"):
                let size: SIMD3<Double> = c.kind.isTailless ? [10, 3, 14] : [3, 10, 14]
                scene.label = "Receiver – micro, \(d.channels)+ channels (servos + throttle)"
                scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.receiver)
            case "Printed" where item.name.hasPrefix("Motor mount"):
                // The real clamp mount: plate on the firewall, jaws over the structure (aft for tractors, forward for pushers).
                let mesh = PrintedParts.motorMount(for: c)
                let placed = c.isPusher ? mesh.transformed { q in SIMD3<Double>(-q.x, q.y, -q.z) } : mesh
                scene.label = "Motor mount (printed) – \(c.motor.pattern.label), clamp for \(Int(t)) mm foam"
                scene.addMesh(placed.translated([p.x, 0, c.firewallZ]), color: Palette.printed)
            case "Printed" where item.name.hasPrefix("Nose protector"):
                let z0 = c.kind.isTailless ? 0 : -c.noseLength
                scene.label = c.kind.isTailless ? "Nose protector (printed) – apex guard" : "Nose protector (printed) – + channel cap"
                scene.addMesh(PrintedParts.noseProtector(for: c).translated([0, 0, z0]), color: Palette.printed)
            case "Printed":
                continue   // horns are drawn with their linkages
            case "Hardware" where item.name.hasPrefix("Tail booms"):
                let len = c.tailArm + c.hStabChord * 0.55 - c.rootChord * 0.15
                scene.label = "Tail boom – \(CarbonSpar.tube4.name)"
                for x in [-c.boomX, c.boomX] {
                    scene.addMesh(cylinder(center: [x, p.y, p.z], radius: 2, length: len, segments: 10), color: Palette.carbon)
                }
            default:
                if item.name.hasPrefix("Servo") {
                    let s = c.servo.size
                    // H sideways (shaft axis), W vertical, L fore-aft – see DesignBuilder.armTip.
                    // The single central aileron servo stands upright in the plate (shaft up): W sideways, H vertical.
                    let standing = item.name.contains("double arm")
                    let size: SIMD3<Double> = standing ? [s.w, s.h, s.l] : [s.h, s.w, s.l]
                    scene.label = "\(item.name) – \(c.servo.name)"
                    scene.addMesh(.box(min: p - size / 2, max: p + size / 2), color: Palette.servo)
                    // Servos are glued straight into their flush cutouts – no frames.
                }
            }
        }
        // Carbon struts with their printed anchors (same mesh as the STL).
        for st in d.struts {
            scene.label = "Carbon strut \(st.label) – \(st.rod.name), \(Int(st.length.rounded())) mm"
            let a3 = st.a.rodEnd, dir = st.direction
            let side = simd_normalize(abs(dir.y) < 0.9 ? simd_cross(dir, [0, 1, 0]) : simd_cross(dir, [1, 0, 0]))
            let up = simd_cross(side, dir)
            // Display only: at least Ø1.6 mm and a light line along the axis, so a Ø1 rod stays visible against
            // the dark background at any zoom (geometry, STLs and checks use the true diameter).
            let rod = Mesh3D.extrude(Poly.circle(.zero, max(st.diameter, 1.6) / 2, segments: 10), z0: 0, z1: st.length)
                .transformed { p in a3 + side * p.x + up * p.y + dir * p.z }
            scene.addMesh(rod, color: Palette.carbon)
            scene.addLine(a3, st.b.rodEnd, color: Palette.strutLine)
            for end in [st.a, st.b] {
                if let sd = end.saddle {
                    // Drawn once for the pair (with the right-hand strut).
                    if st.label.hasSuffix("R"), let left = d.struts.first(where: { $0.label == sd.label + "L" }) {
                        scene.label = "Strut saddle \(sd.label) (printed, one piece for both rods) – \(Int((end.elevation * 180 / .pi).rounded()))°"
                        scene.addMesh(PrintedParts.strutSaddle(right: end, left: left.b, dia: st.diameter), color: Palette.printed)
                    }
                    continue
                }
                if let sp = end.shared {
                    if st.label == sp.labels[0], let other = d.struts.first(where: { $0.label == sp.labels[1] }) {
                        scene.label = "Double strut anchor \(sp.labels.joined(separator: " + ")) (printed, one pad for both rods)"
                        scene.addMesh(PrintedParts.strutDoubleAnchor(end, other.a, dia1: st.diameter, dia2: other.diameter, design: d), color: Palette.printed)
                    }
                    continue
                }
                scene.label = "Strut anchor \(st.label) (printed) – \(Int((end.elevation * 180 / .pi).rounded()))°"
                scene.addMesh(PrintedParts.placedAnchor(end, dia: st.diameter, pad: true), color: Palette.printed)
            }
        }
        // Linkages: the servo arm as supplied with the servo, the pushrod (Ø1 mm carbon rod with Ø0.8 mm steel-wire
        // Z-bend ends joined by heat-shrink) and the printed horn standing out of the surface.
        var drawnDoubleArm = false
        for ctrl in d.controls {
            // The surface this control drives: hinge line through its hinge point, horn standing out of its face.
            let move = moves.filter { abs(simd_dot(simd_normalize(ctrl.hornAxis), $0.normal)) > 0.7 }
                .min { $0.distance(to: ctrl.hingeMid) < $1.distance(to: ctrl.hingeMid) }
                .flatMap { $0.distance(to: ctrl.hingeMid) < 3 ? $0 : nil }
            let moveHorn: (SIMD3<Double>) -> SIMD3<Double> = { p in move.map { $0.apply(p) } ?? p }
            let rest = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
            let horn = moveHorn(ctrl.hornPosition)
            // Servo arm turned about its shaft so the pushrod keeps its length to the moved horn.
            var armTurn = simd_quatd(angle: 0, axis: [0, 1, 0])
            var pivot = rest
            if ctrl.armPosition != .zero, move != nil {
                let shaft = ctrl.shaft(c.servo)
                let axis: SIMD3<Double> = ctrl.isDoubleArm ? [0, 1, 0] : [1, 0, 0]
                pivot = shaft
                let l0 = simd_distance(rest, ctrl.hornPosition)
                func f(_ phi: Double) -> Double { simd_distance(simd_quatd(angle: phi, axis: axis).act(rest - shaft) + shaft, horn) - l0 }
                var best = 0.0, bestErr = abs(f(0))
                // Root nearest to 0 (scan outwards both ways, refine by bisection).
                search: for k in 1...140 {
                    for sgn in [1.0, -1.0] {
                        let p0 = sgn * Double(k - 1) * 0.01, p1 = sgn * Double(k) * 0.01
                        if abs(f(p1)) < bestErr { bestErr = abs(f(p1)); best = p1 }
                        if f(p0) * f(p1) <= 0 {
                            var lo = p0, hi = p1
                            for _ in 0..<30 { let m = (lo + hi) / 2; if f(lo) * f(m) <= 0 { hi = m } else { lo = m } }
                            best = (lo + hi) / 2
                            break search
                        }
                    }
                }
                armTurn = simd_quatd(angle: best, axis: axis)
            }
            let turnArm: (SIMD3<Double>) -> SIMD3<Double> = { p in armTurn.act(p - pivot) + pivot }
            let arm = turnArm(rest)
            let th = ServoClass.armThickness
            // Direction along which the pushrod's Z-bend crosses the arm (through its hole, towards the servo case).
            var throughArm: SIMD3<Double> = [0, 0, 0]
            if ctrl.armPosition != .zero {
                let shaft = ctrl.shaft(c.servo)
                let gap = ServoClass.armGap
                if ctrl.isDoubleArm {
                    // Shaft down: spline hub below the case, the double arm horizontal across, pushrods below its ends.
                    let yTop = shaft.y - gap
                    let half = abs(rest.x - shaft.x)
                    if !drawnDoubleArm {
                    drawnDoubleArm = true
                    scene.label = "Double servo arm – both ailerons (comes with the servo)"
                    scene.addMesh(armMesh(length: half, double: true, origin: [shaft.x, yTop, shaft.z], along: [1, 0, 0], across: [0, 0, 1], normal: [0, -1, 0]).transformed(turnArm), color: Palette.linkage)
                    scene.addMesh(placed(cylinderMesh(radius: 2.3, from: 0, to: gap), origin: [shaft.x, yTop, shaft.z], [1, 0, 0], [0, 0, 1], [0, 1, 0]), color: Palette.linkage)
                    scene.label = "Servo arm screw"
                    scene.addMesh(placed(cylinderMesh(radius: 1.1, from: -0.4, to: 0, segments: 12), origin: [shaft.x, yTop - th, shaft.z], [1, 0, 0], [0, 0, 1], [0, 1, 0]), color: Palette.armDetail)
                    }
                    throughArm = [0, 1, 0]
                } else {
                    // Shaft sideways: spline hub from the case face to the arm, the arm from the shaft to the pushrod hole.
                    let side: Double = rest.x >= ctrl.servoPosition.x ? 1 : -1
                    let x0 = shaft.x + side * gap
                    let up: Double = arm.y >= shaft.y ? 1 : -1
                    let reach = simd_length(SIMD2(arm.y - shaft.y, arm.z - shaft.z))
                    let dir = reach > 0.1 ? SIMD3<Double>(0, (arm.y - shaft.y) / reach, (arm.z - shaft.z) / reach) : [0, up, 0]   // already turned
                    let across = simd_cross([side, 0, 0], dir)
                    scene.label = "Servo arm – \(ctrl.name) (comes with the servo)"
                    scene.addMesh(armMesh(length: reach, double: false, origin: [x0, shaft.y, shaft.z], along: dir, across: across, normal: [side, 0, 0]), color: Palette.linkage)
                    scene.addMesh(placed(cylinderMesh(radius: 2.3, from: -gap, to: 0), origin: [x0, shaft.y, shaft.z], dir, across, [side, 0, 0]), color: Palette.linkage)
                    scene.label = "Servo arm screw"
                    scene.addMesh(placed(cylinderMesh(radius: 1.1, from: th, to: th + 0.4, segments: 12), origin: [x0, shaft.y, shaft.z], dir, across, [side, 0, 0]), color: Palette.armDetail)
                    throughArm = [-side, 0, 0]
                }
            }
            // Pushrod: steel Z-bend through the arm hole, steel end, heat-shrink joint, carbon rod, joint, steel end and
            // Z-bend through the horn. Drawn about twice as thick as real (Ø2 / Ø1.5 mm) so the rods stay visible in the whole-model view.
            let len = simd_length(horn - arm)
            if len > 1 {
                let u = (horn - arm) / len
                let steel = min(35, len * 0.3)
                let a1 = arm + u * steel, h1 = horn - u * steel
                scene.label = "Pushrod – \(ctrl.name): Ø1 mm carbon rod, Ø0.8 mm steel-wire Z-bend ends, heat-shrink joints"
                scene.addMesh(rodMesh(a1, h1, radius: 1.0), color: Palette.pushrod)
                scene.addMesh(rodMesh(arm, a1, radius: 0.75), color: Palette.steel)
                scene.addMesh(rodMesh(h1, horn, radius: 0.75), color: Palette.steel)
                for j in [a1, h1] { scene.addMesh(rodMesh(j - u * 5, j + u * 5, radius: 1.3), color: Palette.heatShrink) }
                if simd_length(throughArm) > 0 {
                    let p1 = arm + throughArm * (th + 1.1)
                    scene.addMesh(rodMesh(arm, p1, radius: 0.75, cap: true), color: Palette.steel)
                    scene.addMesh(rodMesh(p1, p1 - u * 2.5, radius: 0.75, cap: true), color: Palette.steel)
                }
                // Z-bend through the horn's pushrod hole (across the horn plate).
                let ha = simd_normalize(ctrl.hornAxis)
                let ey = simd_normalize(moveHorn(ctrl.hornPosition + simd_cross(ha, [0, 0, 1])) - horn)
                let hz = horn + ey * 1.4
                scene.addMesh(rodMesh(horn - ey * 0.4, hz, radius: 0.75, cap: true), color: Palette.steel)
                scene.addMesh(rodMesh(hz, hz + u * 2.5, radius: 0.75, cap: true), color: Palette.steel)
                scene.addLine(arm, horn, color: Palette.strutLine)
            }
            // The printed horn (same mesh as the STL): plate in the plane of the pushrod motion – horn axis and flight
            // direction –, tab in the slot 6 mm behind the hinge, pushrod hole above the hinge line.
            let a = simd_normalize(ctrl.hornAxis)
            let ex = SIMD3<Double>(0, 0, 1), ey = simd_cross(a, ex)
            let origin = ctrl.hornPosition - a * 9 + [0, 0, 4]
            let hornMesh = PrintedParts.controlHorn(foam: t).transformed { p in moveHorn(origin + ex * p.x + ey * p.y + a * p.z) }
            scene.label = "Control horn (printed) – \(ctrl.name)"
            scene.addMesh(hornMesh, color: Palette.printed)
        }

        scene.fitBounds()

        if showCG, let a {
            scene.label = String(format: "Centre of gravity – now %.0f mm, target %.0f mm behind the root LE", a.cg.z, a.recommendedCG)
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
            scene.label = "\(p.name) – \(p.quantity)×, \(String(format: "%.1f", p.mass)) g"
            scene.addMesh(m, color: Palette.printed)
            x += (b.max.x - b.min.x) + 10
        }
        scene.fitBounds()
        addGrid(&scene, y: Double(scene.center.y - scene.radius * 0.6), spacing: 10, extent: 12)
        return scene
    }

    // MARK: Helpers

    /// Hover name of a control surface region of a part.
    static func controlName(_ part: Part, _ c: AircraftConfig) -> String {
        switch part.role {
        case .wing: return c.kind.isTailless ? "Elevon (control surface)" : (c.kind.isNutBall ? "Elevator (control surface)" : "Aileron (control surface)")
        case .fin, .winglet: return "Rudder (control surface)"
        case .stabilizer: return "Elevator (control surface)"
        default: return part.outline.allSatisfy({ $0.y >= -0.01 }) ? "Rudder (control surface)" : "Elevator (control surface)"
        }
    }

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
    /// of tractor props (reverse rotation), so `mirrored` flips the blade handedness; the pitch always gives
    /// forward thrust (trailing edge aft).
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
                // The trailing edge always sits AFT (+z) of the leading edge: the blade throws air backwards and
                // pulls / pushes the plane forward – for a tractor and a pusher alike (only the spinner side and the
                // rotation sense differ).
                let le = SIMD3<Double>(r * mx, half * cos(pitch), -half * sin(pitch))
                let te = SIMD3<Double>(r * mx, -half * cos(pitch), half * sin(pitch))
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

    /// Thin flat strip lying on a surface (carbon strips / rods).
    static func strip(from a: SIMD3<Double>, to b: SIMD3<Double>, normal n: SIMD3<Double>, width w: Double, height h: Double = 0.6) -> Mesh3D {
        let d = simd_normalize(b - a), side = simd_normalize(simd_cross(n, d)) * (w / 2), up = simd_normalize(n) * h
        let c = [a - side, a + side, b + side, b - side]
        let top = c.map { $0 + up }
        var m = Mesh3D()
        func quad(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ r: SIMD3<Double>, _ s: SIMD3<Double>) { m.triangles += [(p, q, r), (p, r, s)] }
        quad(c[0], c[1], c[2], c[3]); quad(top[3], top[2], top[1], top[0])
        for i in 0..<4 { let j = (i + 1) % 4; quad(c[i], c[j], top[j], top[i]) }
        return m
    }

    /// Places a mesh built in local coordinates (x, y, z) at `o` with the axes ex, ey, ez; mirrored frames keep their
    /// triangles facing outward.
    static func placed(_ m: Mesh3D, origin o: SIMD3<Double>, _ ex: SIMD3<Double>, _ ey: SIMD3<Double>, _ ez: SIMD3<Double>) -> Mesh3D {
        var out = m.transformed { o + ex * $0.x + ey * $0.y + ez * $0.z }
        if simd_dot(simd_cross(ex, ey), ez) < 0 { out.triangles = out.triangles.map { ($0.0, $0.2, $0.1) } }
        return out
    }

    /// Cylinder along local z from `z0` to `z1`.
    static func cylinderMesh(radius r: Double, from z0: Double, to z1: Double, segments n: Int = 20) -> Mesh3D {
        Mesh3D.extrude(Poly.circle(.zero, r, segments: n), z0: z0, z1: z1)
    }

    /// Round rod from a to b (optionally with a little ball at each end so bends look continuous).
    static func rodMesh(_ a: SIMD3<Double>, _ b: SIMD3<Double>, radius r: Double, cap: Bool = false) -> Mesh3D {
        let l = simd_length(b - a)
        guard l > 1e-6 else { return Mesh3D() }
        let dir = (b - a) / l
        let side = simd_normalize(abs(dir.y) < 0.9 ? simd_cross(dir, [0, 1, 0]) : simd_cross(dir, [1, 0, 0]))
        let up = simd_cross(dir, side)
        var m = placed(cylinderMesh(radius: r, from: 0, to: l, segments: 10), origin: a, side, up, dir)
        if cap { m.append(sphere(center: b, radius: r)) }
        return m
    }

    /// A servo arm as supplied with micro servos: a round hub tapering to a rounded tip (single) or to both tips
    /// (double), `length` from the shaft to the outer pushrod hole, ServoClass.armThickness thick, with a row of
    /// small holes. Built in the plane spanned by `along` / `across` from `origin` (the arm face nearest the case)
    /// towards `normal`.
    static func armMesh(length: Double, double: Bool, origin: SIMD3<Double>, along: SIMD3<Double>, across: SIMD3<Double>, normal: SIMD3<Double>) -> Mesh3D {
        let hubR = 2.9, tipR = 1.5
        let reach = length + 1.2           // a little past the outer hole
        var pts = Poly.circle(Vec2(0, 0), hubR, segments: 24) + Poly.circle(Vec2(reach, 0), tipR, segments: 16)
        if double { pts += Poly.circle(Vec2(-reach, 0), tipR, segments: 16) }
        else { pts += Poly.circle(Vec2(-2.2, 0), 2.2, segments: 16) }      // short stub behind the hub
        let outline = StrutPlanner.convexHull(pts)
        let th = ServoClass.armThickness
        var m = placed(Mesh3D.extrude(outline, z0: 0, z1: th), origin: origin, along, across, normal)
        // Holes: small dark dots on the outer face (outer one is the pushrod's).
        var dots = Mesh3D()
        for k in 0..<4 {
            let x = length - Double(k) * 2.2
            guard x > hubR + 0.8 else { break }
            for sx in double ? [1.0, -1.0] : [1.0] {
                dots.append(placed(cylinderMesh(radius: 0.45, from: th, to: th + 0.05, segments: 8), origin: origin + along * (sx * x), along, across, normal))
            }
        }
        m.append(dots)
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

/// A control surface turned about its hinge line (surface preview).
struct SurfaceMove {
    var a: SIMD3<Double>, b: SIMD3<Double>
    var q: simd_quatd
    var normal: SIMD3<Double>
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { q.act(p - a) + a }
    /// Distance of a point from the hinge segment.
    func distance(to p: SIMD3<Double>) -> Double {
        let ab = b - a
        let k = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
        return simd_distance(p, a + ab * k)
    }
}
