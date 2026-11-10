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
                                   mesh: motorMount(c.motor, foam: t, web: 0), note: "clamps on the wing leading edge at the MOTOR marks"))
        } else {
            out.append(PrintedPart(name: "Motor mount", fileName: "motor_mount_\(c.motor.rawValue)", quantity: 1,
                                   mesh: motorMount(c.motor, foam: t, web: c.kind.hasFuselage ? t * Double(c.fuselageType.webLayers) : t),
                                   note: c.kind.isTailless ? "clamps on the wing trailing edge" : (c.kind.isTwinBoom ? "clamps on the pod tail" : "clamps on the fuselage nose")))
        }
        if c.fpv != .none {
            // Tailed aircraft: saddle that slides over the top edge of the vertical fuselage at the nose.
            // Tailless: flat base glued on the wing apex.
            let saddle: Double? = c.kind.isTailless ? nil : t
            let tilt = c.kind.cameraTilt
            out.append(PrintedPart(name: "FPV camera mount (\(c.fpv.name))", fileName: "camera_mount_\(c.fpv.rawValue)_\(Int(tilt))deg", quantity: 1,
                                   mesh: cameraMount(width: c.fpv.cameraWidth, tilt: tilt, saddleWeb: saddle),
                                   note: "\(c.fpv.mountNote), \(Int(tilt))° up-tilt, \(saddle == nil ? "flat base for the wing apex" : "saddle for the \(Int(t)) mm fuselage edge")"))
            let v = c.fpv.vtxSize
            out.append(PrintedPart(name: "VTX tray (\(c.fpv.name))", fileName: "vtx_tray_\(c.fpv.rawValue)", quantity: 1,
                                   mesh: vtxTray(length: v.l, width: v.w, height: v.h), note: "\(Int(v.l)) × \(Int(v.w)) mm pocket, zip-tie slots"))
            out.append(PrintedPart(name: "Antenna holder", fileName: "antenna_holder", quantity: 1,
                                   mesh: antennaHolder(), note: "keeps the antenna vertical and away from carbon"))
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

        if c.aio {
            out.append(PrintedPart(name: "AIO mount 26 × 26 mm", fileName: "aio_mount_26x26", quantity: 1, mesh: aioMount(),
                                   note: "4 standoffs for M2 on a \(Int(AIOController.holeSpacing)) mm square, glue \(c.kind.isTailless ? "on the wing centre" : "to the fuselage side")"))
        }
        out.append(PrintedPart(name: "Battery tray", fileName: "battery_tray_\(c.battery.rawValue)", quantity: 1,
                               mesh: batteryTray(c.battery), note: "velcro base with side rails"))
        return out
    }

    // MARK: Generators (all dimensions in mm)

    static func motorMount(_ m: MotorClass, foam t: Double, web: Double? = nil) -> Mesh3D {
        let tw = web ?? t
        let plate = max(m.boltCircle + m.screwHole * 2 + 6, m.bellDiameter * 0.75)
        let th = 2.0
        let r = m.boltCircle / 2
        var holes: [[Vec2]] = [Poly.circle(.zero, max(2.5, m.boltCircle * 0.28), segments: 32)]
        for k in 0..<4 {
            let a = Double(k) * .pi / 2 + .pi / 4
            holes.append(Poly.circle(Vec2(cos(a), sin(a)) * r, m.screwHole / 2, segments: 16))
        }
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)), holes: holes, z0: 0, z1: th)
        // Four corner blocks leave a + shaped channel that grips the vertical fuselage
        // halves and the horizontal plate (or wing + keel) at the same time.
        let gapX = tw / 2 + 0.15, gapY = t / 2 + 0.15, len = 22.0, e = plate / 2
        if tw <= 0 {
            // Wing-only clamp (dual tractor on the leading edge): solid jaws above and below the wing.
            mesh.append(.box(min: [-e, gapY, th], max: [e, e, th + len]))
            mesh.append(.box(min: [-e, -e, th], max: [e, -gapY, th + len]))
            return mesh
        }
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                let x0 = sx > 0 ? gapX : -e, x1 = sx > 0 ? e : -gapX
                let y0 = sy > 0 ? gapY : -e, y1 = sy > 0 ? e : -gapY
                mesh.append(.box(min: [x0, y0, th], max: [x1, y1, th + len]))
            }
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

    static func cameraMount(width w: Double, tilt: Double = 15, saddleWeb: Double? = nil) -> Mesh3D {
        let inner = w + 0.4, wall = 1.4, base = 1.2, h = w * 0.8
        var mesh = Mesh3D.box(min: [-inner / 2 - wall, -8, 0], max: [inner / 2 + wall, 8, base])
        if let web = saddleWeb {
            // Two skirts under the base form a slot that grips the fuselage top edge.
            let gap = web / 2 + 0.15
            mesh.append(.box(min: [gap, -8, -6], max: [gap + 1.2, 8, 0]))
            mesh.append(.box(min: [-gap - 1.2, -8, -6], max: [-gap, 8, 0]))
        }
        // Side cheeks (YZ profile, tilted back by the up-tilt) with an M2 screw hole.
        let a = tilt * .pi / 180
        let profile = [Vec2(-8, 0), Vec2(8, 0), Vec2(8 + h * tan(a), h), Vec2(-8 + h * tan(a), h)]
        let hole = [Poly.circle(Vec2(h * 0.6 * tan(a), h * 0.6), 1.1, segments: 14)]
        for x in [-inner / 2 - wall, inner / 2] {
            let cheek = Mesh3D.extrude(profile, holes: hole, z0: 0, z1: wall)
                .transformed { p in SIMD3<Double>(x + p.z, p.x, p.y) }
            // (u, v, w) → (w, u, v) is a cyclic axis swap, i.e. a proper rotation: normals stay outward.
            mesh.append(cheek)
        }
        return mesh
    }

    static func vtxTray(length l: Double, width w: Double, height h: Double) -> Mesh3D {
        let L = l + 3, W = w + 3
        let slots = [Poly.rect(center: Vec2(-L / 2 + 3, 0), size: Vec2(1.8, W * 0.6)), Poly.rect(center: Vec2(L / 2 - 3, 0), size: Vec2(1.8, W * 0.6))]
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(L, W)), holes: slots, z0: 0, z1: 1.2)
        let rim = max(2, h * 0.4)
        mesh.append(.extrude(Poly.rect(center: .zero, size: Vec2(L, W)), holes: [Poly.rect(center: .zero, size: Vec2(L - 2.4, W - 2.4))], z0: 1.2, z1: 1.2 + rim))
        return mesh
    }

    /// Flat mount for a 26 × 26 mm hole pattern board: base with lightening cut-out and four M2 standoffs.
    static func aioMount(spacing: Double = AIOController.holeSpacing, board: Double = AIOController.boardSize) -> Mesh3D {
        let base = board + 2, h = spacing / 2
        var mesh = Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(base, base)),
                                  holes: [Poly.rect(center: .zero, size: Vec2(spacing - 9, spacing - 9))], z0: 0, z1: 1.4)
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                // Ø5 standoff, Ø1.7 pilot hole for self-tapping M2, 4 mm high.
                mesh.append(Mesh3D.extrude(Poly.circle(.zero, 2.5, segments: 20), holes: [Poly.circle(.zero, 0.85, segments: 12)], z0: 1.4, z1: 5.4)
                                .translated([sx * h, sy * h, 0]))
            }
        }
        return mesh
    }

    static func antennaHolder() -> Mesh3D {
        var mesh = Mesh3D.box(min: [-6, -6, 0], max: [6, 6, 1.2])
        mesh.append(.extrude(Poly.circle(.zero, 3.6, segments: 24), holes: [Poly.circle(.zero, 2.2, segments: 24)], z0: 1.2, z1: 14))
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
