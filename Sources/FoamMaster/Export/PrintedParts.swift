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
                                   mesh: motorMount(for: c), note: "\(c.motor.pattern.label) motor pattern, wing clamp for \(Int(t)) mm foam, M2 clamp bolts\(c.mountStandoff > 0 ? ", \(Int(c.mountStandoff)) mm standoff so the prop clears the swept leading edge" : "") – leading edge at the MOTOR marks"))
        } else {
            out.append(PrintedPart(name: "Motor mount", fileName: "motor_mount_\(c.motor.rawValue)", quantity: 1,
                                   mesh: motorMount(for: c),
                                   note: "\(c.motor.pattern.label) motor pattern, + clamp for \(Int(t)) mm foam, M2 clamp bolt – " + (c.kind.isTailless ? "front of the trailing-edge cutout" : (c.kind.isTwinBoom ? "pod tail" : (c.kind.isJet ? "front of the prop slot" : (c.kind.isNutBall ? "nose of the disc" : "fuselage nose"))))))
        }
        if c.isDual {
            out.append(PrintedPart(name: "Nose protector", fileName: "nose_protector_\(c.kind.isTailless ? "apex" : "cross")_\(Int(t))mm", quantity: 1,
                                   mesh: noseProtector(for: c),
                                   note: c.kind.isTailless ? "glue-on apex guard following the swept leading edge for \(Int(t)) mm foam – protects the nose on landings"
                                                           : "+ channel cap for \(Int(t)) mm foam (plate and both fuselage halves), glue on – protects the nose on landings"))
        }
        if !d.controls.isEmpty {
            out.append(PrintedPart(name: "Control horn", fileName: "control_horn_\(Int(t))mm", quantity: d.controls.count,
                                   mesh: controlHorn(foam: t), note: "tab for the 10 × 1.6 mm slot, \(String(format: "%.1f", t - 0.5)) mm deep for \(Int(t)) mm foam; pushrod hole above the hinge line"))
        }

        // Servos are glued straight into their flush cutouts – no printed servo frames.

        // Strut anchors grouped by rod size and boss angle (left and right ends are the same part).
        var anchors: [String: (dia: Double, deg: Int, labels: [String])] = [:]
        for st in d.struts {
            for end in [st.a, st.b] where end.saddle == nil && end.shared == nil {
                let deg = Int((end.elevation * 180 / .pi).rounded())
                let key = String(format: "d%.1f_%02d", st.diameter, deg)
                anchors[key, default: (st.diameter, deg, [])].labels.append(st.label)
            }
        }
        for (key, g) in anchors.sorted(by: { $0.key < $1.key }) {
            let dTxt = g.dia == g.dia.rounded() ? String(format: "%.0f", g.dia) : String(format: "%.1f", g.dia)
            let labels = Array(Set(g.labels.map { String($0.dropLast()) })).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
            out.append(PrintedPart(name: "Strut anchor Ø\(dTxt) mm · \(g.deg)°", fileName: "strut_anchor_\(key.replacingOccurrences(of: ".", with: "_"))deg",
                                   quantity: g.labels.count, mesh: strutAnchor(dia: g.dia, elevation: Double(g.deg) * .pi / 180),
                                   note: "rod hole Ø\(String(format: "%.2f", g.dia + 0.25)) mm at \(g.deg)° to the foam – glue onto the \(labels.joined(separator: ", ")) pads on the plan, boss pointing along the arrow"))
        }

        // Double anchors: two rod ends side by side on the wing share one pad (left and right are mirror images).
        var doneShared = Set<String>()
        for st in d.struts {
            guard let sp = st.a.shared, doneShared.insert(sp.labels.joined()).inserted,
                  let other = d.struts.first(where: { $0.label != st.label && sp.labels.contains($0.label) }) else { continue }
            let name = sp.labels.joined(separator: " + ")
            out.append(PrintedPart(name: "Double strut anchor \(name)", fileName: "strut_double_\(sp.labels.joined(separator: "_").lowercased())",
                                   quantity: 1, mesh: strutDoubleAnchorPrint(st.a, other.a, dia1: st.diameter, dia2: other.diameter, design: d),
                                   note: "one pad for the wing ends of \(name): glue onto the \(sp.labels.map { String($0.dropLast()) }.joined(separator: "+")) mark under the \(st.a.surface.x > 0 ? "right" : "left") wing, bosses pointing along the arrows"))
        }

        // One-piece saddles at the bottom of the fuselage (one per left/right pair, each fitted to its spot).
        for r in d.struts where r.label.hasSuffix("R") {
            guard let sd = r.b.saddle, let l = d.struts.first(where: { $0.label == sd.label + "L" }) else { continue }
            let dTxt = r.diameter == r.diameter.rounded() ? String(format: "%.0f", r.diameter) : String(format: "%.1f", r.diameter)
            let deg = Int((r.b.elevation * 180 / .pi).rounded())
            out.append(PrintedPart(name: "Strut saddle \(sd.label) · Ø\(dTxt) mm", fileName: "strut_saddle_\(sd.label.lowercased())",
                                   quantity: 1, mesh: strutSaddlePrint(right: r.b, left: l.b, dia: r.diameter),
                                   note: "one piece for \(sd.label) L + R: slide over the bottom edge of the fuselage at the \(sd.label) saddle mark and glue\(sd.footDepth > 0 ? " (the rods plug into the foot below the edge)" : "") – rod holes Ø\(String(format: "%.2f", r.diameter + 0.25)) mm at \(deg)° to the foam"))
        }

        out.append(PrintedPart(name: "Battery tray", fileName: "battery_tray_\(c.battery.rawValue)", quantity: 1,
                               mesh: batteryTray(c.battery), note: "velcro base with side rails"))
        // Safety net: every exported STL faces outward (positive signed volume).
        for i in out.indices where out[i].mesh.signedVolume < 0 { out[i].mesh = out[i].mesh.flipped }
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
        if c.isDual { return motorMount(c.motor, foam: t, webTop: nil, webBottom: nil, standoff: c.mountStandoff) }
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
    /// `blank`: solid front plate without the motor holes – used for the nose protector of dual-motor layouts.
    static func motorMount(_ m: MotorClass, foam t: Double, webTop: Double?, webBottom: Double?, standoff: Double = 0, blank: Bool = false) -> Mesh3D {
        let wingClamp = webTop == nil && webBottom == nil
        let pat = m.pattern
        let headD = pat.headDiameter + 0.4
        let th = blank ? mountPlate : firewallThickness(m), len = mountJaw
        let plate = motorMountPlate(m, foam: t)
        let e = plate / 2
        let screws = blank ? [] : pat.positions
        let shaft = Poly.circle(.zero, m.shaftClearance, segments: 32)
        // Firewall: clearance holes through, counterbores for the heads on the back face.
        let cb = th - pat.headHeight
        var mesh = blank ? Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)), z0: 0, z1: th) : Mesh3D.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)),
                                  holes: [shaft] + screws.map { Poly.circle($0, pat.clearance / 2, segments: 16) }, z0: 0, z1: cb)
        if !blank {
            mesh.append(.extrude(Poly.rect(center: .zero, size: Vec2(plate, plate)),
                                 holes: [shaft] + screws.map { Poly.circle($0, headD / 2, segments: 20) }, z0: cb, z1: th))
        }
        // Access bores (square, head size + clearance) through any jaw that covers a screw.
        let bore = headD / 2 + 0.2
        let bores = screws.map { (x0: $0.x - bore, x1: $0.x + bore, y0: $0.y - bore, y1: $0.y + bore) }
        let gapY = t / 2 + 0.1, jaw = 3.0, rb = 1.1
        // Optional standoff: square tube (1.6 mm walls) between the firewall and the jaws.
        if standoff > 0 {
            let w = 1.6
            mesh.append(block(-e, e, -e, -e + w, th, th + standoff, voids: []))
            mesh.append(block(-e, e, e - w, e, th, th + standoff, voids: []))
            mesh.append(block(-e, -e + w, -e + w, e - w, th, th + standoff, voids: []))
            mesh.append(block(e - w, e, -e + w, e - w, th, th + standoff, voids: []))
        }
        let base = th + standoff
        let z0 = base, z1 = base + len, zb = base + len - 7
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
                let tri = y0 > 0 ? [Vec2(y0, base), Vec2(y1, base), Vec2(y0, base + len * 0.6)] : [Vec2(y0, base), Vec2(y1, base), Vec2(y1, base + len * 0.6)]
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

    /// Nose protector for dual-motor layouts (nothing sits on the nose any more): tailed planes get a + channel cap
    /// (flat + front plate, U-channels for the plate and both webs, sized to the foam thickness); tailless wings a glue-on apex guard that follows
    /// the swept leading edge (lip in front, jaw under the wing – the top stays free for the battery).
    /// Mesh frame: z = 0 at the foam nose / apex, +z aft, y up.
    static func noseProtector(for c: AircraftConfig) -> Mesh3D {
        let t = c.material.thickness
        if c.kind.isTailless {
            let k = c.sweep / max(c.semiSpan, 1), xg = 18.0
            let gapY = t / 2 + 0.1
            // Lip: 2 mm chevron strip just ahead of the leading edge, full foam height + jaw.
            let lip = Poly.ccw([Vec2(-xg, k * xg - 2.2), Vec2(0, -2.2), Vec2(xg, k * xg - 2.2), Vec2(xg, k * xg - 0.2), Vec2(0, -0.2), Vec2(-xg, k * xg - 0.2)])
            var mesh = prism(lip, axis: 1, from: -gapY - 1.6, to: gapY)
            // Jaw under the wing, 7 mm deep (stops ahead of the keel).
            let jaw = Poly.ccw([Vec2(-xg, k * xg - 2.2), Vec2(0, -2.2), Vec2(xg, k * xg - 2.2), Vec2(xg, k * xg + 7), Vec2(0, 7), Vec2(-xg, k * xg + 7)])
            mesh.append(prism(jaw, axis: 1, from: -gapY - 1.6, to: -gapY))
            return mesh
        }
        // + channel cap: a flat + shaped front plate (1.6 mm) with walls along both sides of every arm, forming four
        // U-channels that take the plate and the two fuselage halves (channel width = foam thickness + 0.2 mm).
        let tw = t * Double(c.fuselageType.webLayers)
        let S = 9.0, wall = 1.4, front = 1.6
        let f = c.noseFace(at: 0)
        let hy = t / 2 + 0.1, vx = tw / 2 + 0.1            // channel half widths
        let ex = f.halfWidth + 0.5                           // arm ends (a little past the foam)
        let et = t / 2 + f.top + 0.5, eb = -(t / 2 + f.bottom + 0.5)
        let ox = vx + wall, oy = hy + wall                  // outer half widths of the arms
        // Front plate as two overlapping bars (horizontal and vertical arm of the +).
        var mesh = Mesh3D.box(min: [-ex, -oy, -front], max: [ex, oy, 0])
        mesh.append(.box(min: [-ox, eb, -front], max: [ox, et, 0]))
        // Walls of the horizontal arms (above and below the plate) and of the vertical arms (both sides of the webs).
        for sx in [-1.0, 1.0] {
            let x0 = sx > 0 ? vx : -ex, x1 = sx > 0 ? ex : -vx
            mesh.append(.box(min: [x0, hy, 0], max: [x1, oy, S]))
            mesh.append(.box(min: [x0, -oy, 0], max: [x1, -hy, S]))
        }
        for (y0, y1) in [(hy, et), (eb, -hy)] {
            mesh.append(.box(min: [vx, y0, 0], max: [ox, y1, S]))
            mesh.append(.box(min: [-ox, y0, 0], max: [-vx, y1, S]))
        }
        return mesh
    }

    /// Control horn: base flange glued on the surface, a tab below it for the 10 × 1.6 mm horn slot (depth = foam
    /// thickness − 0.5 mm, so it never pokes out the other side), and a triangular horn plate rising to a round boss
    /// with the pushrod hole exactly above the hinge line (every horn slot sits 6 mm behind its hinge).
    /// Mesh frame: x along the chord (+x aft), z up from the surface, plate in the x–z plane.
    static let hornHoleHeight = 10.0
    static func controlHorn(foam t: Double) -> Mesh3D {
        let flangeT = 1.2, plateT = 1.6, H = hornHoleHeight, r = 3.0
        // The slot centre is 6 mm behind the hinge: the hole (x = −6) is exactly over the hinge line, while flange
        // and plate start 0.5 mm behind it – nothing touches the fixed surface, the boss overhangs in the air.
        let cx = -6.0, front = cx + 0.5
        var mesh = Mesh3D.box(min: [front, -3, 0], max: [9.5, 3, flangeT])
        mesh.append(.box(min: [-4.8, -0.7, -(t - 0.5)], max: [4.8, 0.7, 0]))     // tab in the slot
        let arc: [Vec2] = (0...16).map { k in
            let a = (65.0 + 150.0 * Double(k) / 16) * .pi / 180
            return Vec2(cx + r * cos(a), H + r * sin(a))
        }
        let profile = Poly.ccw([Vec2(9.5, 0), Vec2(9.5, flangeT + 0.8)] + arc + [Vec2(front, flangeT)])
        let hole = [Poly.circle(Vec2(cx, H), 0.95, segments: 16)]                // Ø1.9 for Z-bend / clevis / EZ connector
        let plate = Mesh3D.extrude(profile, holes: hole, z0: -plateT / 2, z1: plateT / 2)
            .transformed { p in SIMD3<Double>(p.x, p.z, p.y) }                   // profile (x, z), thickness along y
        mesh.append(plate.flipped)                                              // the axis swap mirrors – restore winding
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

    /// Strut anchor: a pad glued onto the foam (z 0…1.2) with an inclined square boss (rod hole Ø d + 0.25) at the
    /// rod's elevation, centred over the pad, and a wedge filling the gap under the boss.
    /// Mesh frame: x along the surface towards the rod, y across, z up from the foam.
    static func strutAnchor(dia: Double, elevation phi: Double, pad: Bool = true) -> Mesh3D {
        let padT = StrutPlanner.padThickness, Lb = StrutPlanner.bossLength, B = StrutPlanner.bossSide(dia)
        let size = StrutPlanner.padSize(dia: dia, elevation: phi)
        // Without the pad (saddle side plates carry the boss) the boss and wedge still start on top of a 1.2 mm plate.
        var mesh = pad ? Mesh3D.box(min: [-size.x / 2, -size.y / 2, 0], max: [size.x / 2, size.y / 2, padT]) : Mesh3D()
        // Boss: square tube along its local x, cross-section (y, z) with the rod hole, then tilted up by φ.
        let profile = Poly.rect(center: .zero, size: Vec2(B, B))
        let hole = [Poly.circle(.zero, (dia + 0.25) / 2, segments: 20)]
        let boss = prism(profile, holes: hole, axis: 0, from: 0, to: Lb)          // x = 0…Lb, profile in (y, z)
        let start = SIMD3<Double>(-Lb * cos(phi) / 2, 0, padT + B / 2 * cos(phi))
        mesh.append(boss.rotated(-phi, axis: [0, 1, 0]).translated(start))
        // Wedge under the boss: from the pad top up to the boss's lower edge.
        let n = SIMD3<Double>(-sin(phi), 0, cos(phi))                          // boss "down" is −n
        let low0 = start - n * (B / 2), low1 = low0 + SIMD3(cos(phi), 0, sin(phi)) * Lb
        if low1.z - padT > 0.05 {
            let tri = Poly.ccw([Vec2(low0.x, padT - 0.01), Vec2(low1.x, padT - 0.01), Vec2(low1.x, low1.z + 0.01)])
            mesh.append(prism(tri, axis: 1, from: -B / 2, to: B / 2))
        }
        return mesh
    }

    /// One anchor in the world frame (same transform as the 3D view), outward-wound.
    static func placedAnchor(_ end: StrutAnchor, dia: Double, pad: Bool) -> Mesh3D {
        let w = simd_cross(end.normal, end.along)
        let m = strutAnchor(dia: dia, elevation: end.elevation, pad: pad)
            .transformed { p in end.surface + end.along * p.x + w * p.y + end.normal * p.z }
        return simd_dot(simd_cross(end.along, w), end.normal) < 0 ? m.flipped : m
    }

    /// One-piece strut saddle in the world frame: the left and right rod bosses on side plates over both web faces,
    /// joined by a bridge under the bottom edge (no overlapping solids: plates start at the edge, bridge below it).
    static func strutSaddle(right r: StrutAnchor, left l: StrutAnchor, dia: Double) -> Mesh3D {
        guard let sd = r.saddle else { return Mesh3D() }
        let T = StrutPlanner.padThickness, fx = sd.faceX
        var m = placedAnchor(r, dia: dia, pad: false)
        m.append(placedAnchor(l, dia: dia, pad: false))
        // Side profiles in the (z, y) plane, extruded across x; the bridge follows the (sloped) bottom edge.
        func slab(_ zy: [Vec2], x0: Double, x1: Double) -> Mesh3D {
            // (u, v, w) → (x = w, y = v, z = u) is a mirror, so the winding is flipped back.
            Mesh3D.extrude(Poly.ccw(zy), z0: x0, z1: x1).transformed { p in [p.z, p.y, p.x] }.flipped
        }
        if sd.footDepth > 0 {
            // Foot: the side plates run down past the edge and a solid block fills the space under the web between
            // them; the bosses stand on the plates beside the foot, below the fuselage.
            let F = sd.footDepth
            let plate = [Vec2(sd.z0, sd.edgeY0 - F), Vec2(sd.z1, sd.edgeY1 - F), Vec2(sd.z1, sd.plateTop), Vec2(sd.z0, sd.plateTop)]
            let core = [Vec2(sd.z0, sd.edgeY0 - F), Vec2(sd.z1, sd.edgeY1 - F), Vec2(sd.z1, sd.edgeY1), Vec2(sd.z0, sd.edgeY0)]
            m.append(slab(plate, x0: fx, x1: fx + T))
            m.append(slab(plate, x0: -fx - T, x1: -fx))
            m.append(slab(core, x0: -fx, x1: fx))
            return m
        }
        let plate = [Vec2(sd.z0, sd.edgeY0), Vec2(sd.z1, sd.edgeY1), Vec2(sd.z1, sd.plateTop), Vec2(sd.z0, sd.plateTop)]
        let bridge = [Vec2(sd.z0, sd.edgeY0 - T), Vec2(sd.z1, sd.edgeY1 - T), Vec2(sd.z1, sd.edgeY1), Vec2(sd.z0, sd.edgeY0)]
        m.append(slab(plate, x0: fx, x1: fx + T))
        m.append(slab(plate, x0: -fx - T, x1: -fx))
        m.append(slab(bridge, x0: -fx - T, x1: fx + T))
        return m
    }

    /// Double anchor in the world frame: one pad (the joint outline on the wing face) with the bosses of both rods.
    static func strutDoubleAnchor(_ e1: StrutAnchor, _ e2: StrutAnchor, dia1: Double, dia2: Double, design d: Design) -> Mesh3D {
        guard let sp = e1.shared else { return Mesh3D() }
        let part = d.parts[sp.partIndex], inst = part.instances[sp.instanceIndex]
        let side = simd_dot(e1.normal, inst.normal) > 0 ? 1.0 : -1.0
        var pad = Mesh3D.extrude(Poly.ccw(sp.plan), z0: 0, z1: StrutPlanner.padThickness)
            .transformed { p in inst.point(Vec2(p.x, p.y), offset: side * (part.thickness / 2 + p.z)) }
        if side < 0 { pad = pad.flipped }
        var m = pad
        m.append(placedAnchor(e1, dia: dia1, pad: false))
        m.append(placedAnchor(e2, dia: dia2, pad: false))
        return m
    }

    /// Double anchor as printed: pad flat on the bed, bosses up.
    static func strutDoubleAnchorPrint(_ e1: StrutAnchor, _ e2: StrutAnchor, dia1: Double, dia2: Double, design d: Design) -> Mesh3D {
        let n = e1.normal
        let u = simd_normalize(abs(n.y) < 0.9 ? simd_cross([0, 1, 0], n) : simd_cross([1, 0, 0], n)), v = simd_cross(n, u)
        let o = (e1.surface + e2.surface) / 2
        return strutDoubleAnchor(e1, e2, dia1: dia1, dia2: dia2, design: d).transformed { p in let q = p - o; return [simd_dot(q, u), simd_dot(q, v), simd_dot(q, n)] }
    }

    /// Saddle as printed: bridge flat on the bed, side plates and bosses pointing up (proper rotation x, −z, y).
    static func strutSaddlePrint(right r: StrutAnchor, left l: StrutAnchor, dia: Double) -> Mesh3D {
        guard let sd = r.saddle else { return Mesh3D() }
        // Bridge underside flat on the bed: undo the edge slope first (rotate about x).
        let slope = atan2(sd.edgeY1 - sd.edgeY0, sd.z1 - sd.z0)
        let o = SIMD3<Double>(0, sd.edgeY - StrutPlanner.padThickness, (sd.z0 + sd.z1) / 2)
        let rot = simd_quatd(angle: -slope, axis: [1, 0, 0])
        let m = strutSaddle(right: r, left: l, dia: dia).transformed { p in let q = rot.act(p - o); return [q.x, -q.z, q.y] }
        let lo = m.bounds.min
        return m.translated([0, 0, -lo.z])
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
