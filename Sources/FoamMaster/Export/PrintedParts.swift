import Foundation
import simd

struct PrintedPart: Identifiable {
    let id = UUID()
    var name: String
    var fileName: String
    var quantity: Int
    var mesh: Mesh3D
    var note: String

    /// grams, PETG/PLA at ~85 % effective density for thin walls.
    var mass: Double { mesh.volume * 1.24e-3 * 0.85 }
}

/// Parametric generators for all 3D printable hardware of a design.
enum PrintedParts {
    static func generate(_ d: Design) -> [PrintedPart] {
        let c = d.config
        let t = c.material.thickness
        var out: [PrintedPart] = []

        if c.isDual {
            // Wing-only clamp: grips the leading edge from above and below (no vertical slot).
            out.append(PrintedPart(name: "Motor mount (wing LE)", fileName: "motor_mount_\(c.motor.rawValue)_wing", quantity: 2,
                                   mesh: motorMount(for: c), note: "\(c.motor.pattern.label) motor pattern, wing clamp for \(Int(t)) mm foam, M2 clamp bolt – leading edge at the MOTOR marks"))
        } else {
            out.append(PrintedPart(name: "Motor mount", fileName: "motor_mount_\(c.motor.rawValue)", quantity: 1,
                                   mesh: motorMount(for: c),
                                   note: "\(c.motor.pattern.label) motor pattern, + clamp for \(Int(t)) mm foam, M2 clamp bolt – " + (c.kind.isTailless ? "front of the trailing-edge cutout" : (c.kind.isTwinBoom ? "pod tail" : (c.kind.isJet ? "front of the prop slot" : (c.kind.isNutBall ? "nose of the disc" : "fuselage nose"))))))
        }
        if !d.controls.isEmpty {
            out.append(PrintedPart(name: "Control horn", fileName: "control_horn_\(Int(t))mm", quantity: d.controls.count,
                                   mesh: controlHorn(foam: t), note: "tab fits a 10 × 1.6 mm slot"))
        }

        // Servo frames grouped by cutout size.
        var groups: [String: (size: Vec2, count: Int)] = [:]
        for cut in d.servoCutouts {
            let b = Poly.bounds(cut.rect)
            let sz = b.max - b.min
            let key = String(format: "%.1fx%.1f", sz.x, sz.y)
            groups[key, default: (sz, 0)].count += 1
        }
        for (key, g) in groups.sorted(by: { $0.key < $1.key }) {
            out.append(PrintedPart(name: "Servo frame \(key) mm", fileName: "servo_frame_\(key.replacingOccurrences(of: ".", with: "_"))",
                                   quantity: g.count, mesh: servoFrame(cutout: g.size, foam: t), note: "press-fit into servo cutout"))
        }

        out.append(PrintedPart(name: "Battery tray", fileName: "battery_tray_\(c.battery.rawValue)", quantity: 1,
                               mesh: batteryTray(c.battery), note: "velcro base with side rails"))
        return out
    }

    // MARK: Generators (all dimensions in mm)

    static let mountPlate = 2.4
    /// Side length of the square firewall plate of the motor mount.
    static func motorMountPlate(_ m: MotorClass, foam t: Double) -> Double {
        max(m.boltCircle + m.screwHole * 2 + 6, m.bellDiameter * 0.8, t + 14)
    }
    static let mountJaw = 24.0
    /// Firewall thickness: thick enough for the counterbored screw heads plus 1.4 mm under them.
    static func firewallThickness(_ m: MotorClass) -> Double { max(mountPlate, m.pattern.headHeight + 1.4) }

    /// Motor mount matching the aircraft: wing-only clamp for dual tractors, + channel clamp otherwise.
    /// Motor mount matching the structure it grips:
    /// dual tractor → wing clamp; flying wing / delta → wing on top, keel slot below;
    /// fuselage types → + channel for the horizontal plate and both vertical halves.
    static func motorMount(for c: AircraftConfig) -> Mesh3D {
        let t = c.material.thickness
        if c.isDual { return motorMount(c.motor, foam: t, web: 0) }
        if c.kind.isTailless { return motorMount(c.motor, foam: t, webTop: nil, webBottom: t) }
        let tw = t * Double(c.fuselageType.webLayers)
        return motorMount(c.motor, foam: t, webTop: tw, webBottom: tw)
    }

    /// Profile extruded along an axis. axis 2: profile (x, y) along z · 1: profile (x, z) along y · 0: profile (y, z) along x.
    static func prism(_ profile: [Vec2], holes: [[Vec2]] = [], axis: Int, from a: Double, to b: Double) -> Mesh3D {
        let m = Mesh3D.extrude(profile, holes: holes, z0: a, z1: b)
        switch axis {
        case 0: return m.transformed { p in SIMD3<Double>(p.z, p.x, p.y) }                     // cyclic = rotation
        case 1: return Mesh3D(triangles: m.transformed { p in SIMD3<Double>(p.x, p.z, p.y) }   // swap = mirror → flip winding
                                .triangles.map { ($0.0, $0.2, $0.1) })
        default: return m
        }
    }

    /// Clamp-type motor mount. Firewall plate (z 0…plate) with the motor bolt pattern; clamp jaws extend +z over
    /// the foam. Jaw gaps = foam thickness + 0.2 mm, an M2 clamp bolt passes through jaws and foam, and a 0.3 mm
    /// lip at the jaw tips bites into the foam. `web` = vertical web thickness (0 = wing-only clamp).
    static func motorMount(_ m: MotorClass, foam t: Double, web: Double? = nil) -> Mesh3D {
        let tw = web ?? t
        if tw > 0 { return motorMount(m, foam: t, webTop: tw, webBottom: tw) }
        return motorMount(m, foam: t, webTop: nil, webBottom: nil)
    }

    /// Axis-aligned block (x0…x1, y0…y1, z0…z1) minus rectangular voids that run through it along z, built from
    /// boxes: the voids are the screwdriver / screw-head access bores and the square clamp-bolt channel.
    static func block(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ z0: Double, _ z1: Double,
                      voids: [(x0: Double, x1: Double, y0: Double, y1: Double)]) -> Mesh3D {
        var mesh = Mesh3D(triangles: [])
        guard x1 > x0, y1 > y0, z1 > z0 else { return mesh }
        let vs = voids.filter { $0.x1 > x0 && $0.x0 < x1 && $0.y1 > y0 && $0.y0 < y1 }
        let xs = Array(Set([x0, x1] + vs.flatMap { [$0.x0, $0.x1] }.filter { $0 > x0 && $0 < x1 })).sorted()
        for (xa, xb) in zip(xs, xs.dropFirst()) {
            let xm = (xa + xb) / 2
            var y = y0
            for v in vs.filter({ $0.x0 < xm && xm < $0.x1 }).sorted(by: { $0.y0 < $1.y0 }) {
                if v.y0 > y { mesh.append(.box(min: [xa, y, z0], max: [xb, min(v.y0, y1), z1])) }
                y = max(y, v.y1)
            }
            if y < y1 { mesh.append(.box(min: [xa, y, z0], max: [xb, y1, z1])) }
        }
        return mesh
    }

    /// `webTop` / `webBottom`: thickness of the vertical web above / below the horizontal surface, or nil when
    /// there is none (that jaw is then solid across). Both nil = wing-only clamp with vertical clamp bolts.
    ///
    /// The firewall carries the motor's own hole pattern with counterbores so the screw heads sit flush (the foam
    /// butts against the back face). Holes that end up under a jaw get an access bore through the jaw, so the
    /// motor can be screwed on before the clamp is pushed onto the foam.
    static func motorMount(_ m: MotorClass, foam t: Double, webTop: Double?, webBottom: Double?) -> Mesh3D {
        let wingClamp = webTop == nil && webBottom == nil
        let pat = m.pattern
        let headD = pat.headDiameter + 0.4
        let th = firewallThickness(m), len = mountJaw
        let plate = motorMountPlate(m, foam: t)
        let e = plate / 2
        let screws = pat.positions
        let shaft = Poly.circle(.zero, m.shaftClearance, segments: 32)
        // Firewall: clearance holes through, counterbores for the heads on the back face.
        let cb = th - pat.headHeight
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)),
                                  holes: [shaft] + screws.map { Poly.circle($0, pat.clearance / 2, segments: 16) }, z0: 0, z1: cb)
        mesh.append(.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)),
                             holes: [shaft] + screws.map { Poly.circle($0, headD / 2, segments: 20) }, z0: cb, z1: th))
        // Access bores (square, head size + clearance) through any jaw that covers a screw.
        let bore = headD / 2 + 0.2
        let bores = screws.map { (x0: $0.x - bore, x1: $0.x + bore, y0: $0.y - bore, y1: $0.y + bore) }
        let gapY = t / 2 + 0.1, jaw = 3.0, rb = 1.1
        let z0 = th, z1 = th + len, zb = th + len - 7
        /// Jaw block with the bores; the clamp bolt runs through it as a square channel (strip void at zb).
        func jawBlock(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, boltStrip: (x0: Double, x1: Double, y0: Double, y1: Double)) -> Mesh3D {
            var j = block(x0, x1, y0, y1, z0, zb - rb, voids: bores)
            j.append(block(x0, x1, y0, y1, zb - rb, zb + rb, voids: bores + [boltStrip]))
            j.append(block(x0, x1, y0, y1, zb + rb, z1, voids: bores))
            return j
        }
        if wingClamp {
            // Wing clamp: full-width jaws above and below the wing, two bolts vertically through both and the wing.
            let xb = e - 4
            for (y0, y1) in [(gapY, gapY + jaw), (-gapY - jaw, -gapY)] {
                var j = block(-e, e, y0, y1, z0, zb - rb, voids: bores)
                j.append(block(-e, e, y0, y1, zb - rb, zb + rb,
                               voids: bores + [(x0: -xb - rb, x1: -xb + rb, y0: y0, y1: y1), (x0: xb - rb, x1: xb + rb, y0: y0, y1: y1)]))
                j.append(block(-e, e, y0, y1, zb + rb, z1, voids: bores))
                mesh.append(j)
                // Grip lip on the wing face.
                let ly0 = y0 > 0 ? gapY - 0.3 : -gapY, ly1 = y0 > 0 ? gapY : -gapY + 0.3
                mesh.append(block(-e, e, ly0, ly1, z1 - 2, z1, voids: bores))
            }
            // Gussets between plate and jaws at both sides.
            for (y0, y1) in [(gapY + jaw, e), (-e, -gapY - jaw)] {
                let tri = y0 > 0 ? [Vec2(y0, th), Vec2(y1, th), Vec2(y0, th + len * 0.6)] : [Vec2(y0, th), Vec2(y1, th), Vec2(y1, th + len * 0.6)]
                for x0 in [-e, e - 2] { mesh.append(prism(Poly.ccw(tri), axis: 0, from: x0, to: x0 + 2)) }
            }
            return mesh
        }
        // Cross clamp: corner jaws leave a channel for each vertical web and the horizontal plate / wing;
        // the bolt runs sideways through the jaws and the web. A side without a web gets one solid jaw.
        for sy in [-1.0, 1.0] {
            let y0 = sy > 0 ? gapY : -e, y1 = sy > 0 ? e : -gapY
            guard let web = sy > 0 ? webTop : webBottom else {
                let yIn = sy > 0 ? gapY : -gapY - jaw, yOut = sy > 0 ? gapY + jaw : -gapY
                let xb = e - 4
                let lo = min(yIn, yOut), hi = max(yIn, yOut)
                var j = block(-e, e, lo, hi, z0, zb - rb, voids: bores)
                j.append(block(-e, e, lo, hi, zb - rb, zb + rb,
                               voids: bores + [(x0: -xb - rb, x1: -xb + rb, y0: lo, y1: hi), (x0: xb - rb, x1: xb + rb, y0: lo, y1: hi)]))
                j.append(block(-e, e, lo, hi, zb + rb, z1, voids: bores))
                mesh.append(j)
                mesh.append(block(-e, e, sy > 0 ? gapY - 0.3 : -gapY, sy > 0 ? gapY : -gapY + 0.3, z1 - 2, z1, voids: bores))
                continue
            }
            let gapX = web / 2 + 0.1
            let yb = (y0 + y1) / 2
            let strip = (x0: -e, x1: e, y0: yb - rb, y1: yb + rb)
            mesh.append(jawBlock(gapX, e, y0, y1, boltStrip: strip))
            mesh.append(jawBlock(-e, -gapX, y0, y1, boltStrip: strip))
            // Grip lips on the web faces.
            mesh.append(block(gapX - 0.3, gapX, y0, y1, z1 - 2, z1, voids: bores))
            mesh.append(block(-gapX, -gapX + 0.3, y0, y1, z1 - 2, z1, voids: bores))
        }
        return mesh
    }

    static func controlHorn(foam t: Double) -> Mesh3D {
        var mesh = Mesh3D.box(min: [-7, -4, 0], max: [7, 4, 1])
        let profile: [Vec2] = [Vec2(-5, -t), Vec2(5, -t), Vec2(5, 0), Vec2(6.5, 0), Vec2(3.5, 14), Vec2(-3.5, 14), Vec2(-6.5, 0), Vec2(-5, 0)]
        let holes = [6.0, 8.8, 11.6].map { Poly.circle(Vec2(0, $0), 0.55, segments: 12) }
        let fin = Mesh3D.extrude(profile, holes: holes, z0: -0.6, z1: 0.6).rotated(.pi / 2, axis: [1, 0, 0])
        mesh.append(fin)
        return mesh
    }

    static func servoFrame(cutout: Vec2, foam t: Double) -> Mesh3D {
        let inner = Poly.rect(center: .zero, size: cutout - Vec2(1.0, 1.0))
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: cutout + Vec2(5, 5)), holes: [inner], z0: 0, z1: 1.2)
        let lip = Poly.rect(center: .zero, size: cutout - Vec2(0.2, 0.2))
        mesh.append(.extrude(lip, holes: [inner], z0: 1.2, z1: 1.2 + max(1.5, t - 0.5)))
        return mesh
    }

    static func dihedralJoiner(angle: Double, chord: Double, foam t: Double) -> Mesh3D {
        let w = min(chord * 0.25, 22), len = 42.0, th = min(1.4, t - 0.4)
        let a = angle * .pi / 180
        var mesh = Mesh3D.box(min: [0, -w / 2, 0], max: [len, w / 2, th]).rotated(-a, axis: [0, 1, 0])
        mesh.append(Mesh3D.box(min: [-len, -w / 2, 0], max: [0, w / 2, th]).rotated(a, axis: [0, 1, 0]))
        // Centre web fills the fuselage slot.
        mesh.append(.box(min: [-t / 2, -w / 2, 0], max: [t / 2, w / 2, th + 1]))
        return mesh
    }

    static func batteryTray(_ b: BatteryPack) -> Mesh3D {
        let l = b.size.l + 4, w = b.size.w + 2.4
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(l, w)),
                                  holes: [Poly.rect(center: .zero, size: Vec2(l - 14, w - 8))], z0: 0, z1: 1.2)
        mesh.append(.box(min: [-l / 2, w / 2 - 1.2, 1.2], max: [l / 2, w / 2, 1.2 + min(6, b.size.h * 0.5)]))
        mesh.append(.box(min: [-l / 2, -w / 2, 1.2], max: [l / 2, -w / 2 + 1.2, 1.2 + min(6, b.size.h * 0.5)]))
        return mesh
    }
}
