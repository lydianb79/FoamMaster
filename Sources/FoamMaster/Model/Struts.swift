import Foundation
import simd

/// Carbon stabilisation struts: thin solid carbon rods that brace the wing and the tail boom as triangles (as on the
/// superlite indoor profile planes). Each rod end sits in a small printed anchor glued onto the foam.
enum StrutMode: String, CaseIterable, Identifiable, Codable {
    /// Added only when the wing or fuselage would otherwise fail the stiffness checks.
    case auto
    /// Always fitted where the airframe allows it.
    case always
    case off
    var id: String { rawValue }
    var name: String { [.auto: "Auto", .always: "Always", .off: "Off"][self]! }
    var detail: String {
        [.auto: "Added only when the wing or fuselage would be too flexible",
         .always: "Wing and tail struts wherever they fit",
         .off: "No struts – stiffness from foam and spar only"][self]!
    }
}

enum StrutGroup { case wing, tail, fin }

/// One end of a strut: a printed anchor glued onto a foam surface, the rod plugged into its inclined boss.
struct StrutAnchor {
    var partIndex: Int
    var instanceIndex: Int
    /// Anchor centre on the part's plan, and the rod direction projected onto the plan (unit).
    var plan: Vec2
    var planDir: Vec2
    /// Anchor centre on the foam surface, outward surface normal, unit vector along the surface towards the rod.
    var surface: SIMD3<Double>
    var normal: SIMD3<Double>
    var along: SIMD3<Double>
    /// Rod angle above the surface (radians).
    var elevation: Double
    /// Where the rod ends (back face of the anchor boss).
    var rodEnd: SIMD3<Double>
    var padSize: Vec2
}

struct Strut {
    var label: String
    var name: String
    var group: StrutGroup
    var diameter: Double
    /// `a` is the wing end, `b` the fuselage end.
    var a: StrutAnchor
    var b: StrutAnchor
    var length: Double { simd_distance(a.rodEnd, b.rodEnd) }
    var direction: SIMD3<Double> { simd_normalize(b.rodEnd - a.rodEnd) }
    var rod: CarbonSpar { CarbonSpar.strutRod(diameter) }
    var rodMass: Double { length / 1000 * rod.gramsPerMeter }
    /// Axial stiffness EA / L (N/mm).
    var axialStiffness: Double { StructureReport.carbonE * rod.roundArea / max(length, 1) }
    /// Stiffness of one anchor on the foam (N/mm): a glued pad acts like a rigid punch on the foam,
    /// k ≈ 2·a·(E·sin²φ + G·cos²φ) with a = equivalent pad radius and φ = rod angle to the surface (the rod pulls
    /// partly normal to the foam, partly along it in shear).
    static func anchorStiffness(_ end: StrutAnchor, _ m: FoamMaterial) -> Double {
        let a = (end.padSize.x * end.padSize.y / .pi).squareRoot()
        let s2 = sin(end.elevation) * sin(end.elevation)
        return 2 * a * (m.modulus * s2 + m.shearModulus * (1 - s2))
    }
    /// Effective axial stiffness of the strut as built (N/mm): rod in series with both anchors on the foam.
    func stiffness(_ m: FoamMaterial) -> Double {
        1 / (1 / axialStiffness + 1 / Self.anchorStiffness(a, m) + 1 / Self.anchorStiffness(b, m))
    }
    /// Euler buckling load, pinned ends (N).
    var bucklingLoad: Double { .pi * .pi * rod.roundEI / (length * length) }
}

extension CarbonSpar {
    static let strutDiameters: [Double] = [1, 1.5, 2]
    static func strutRod(_ d: Double) -> CarbonSpar {
        CarbonSpar(name: "Carbon rod Ø\(d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)) mm",
                   widthMM: d, heightMM: d, gramsPerMeter: (.pi / 4 * d * d * 1.55 * 10).rounded() / 10)
    }
}

/// Places struts where they stiffen the airframe without touching servos, servo arms, pushrods, horns, battery,
/// ESC, receiver, motor, propeller, control-surface travel, the foam itself or each other.
struct StrutPlanner {
    let d: Design
    let c: AircraftConfig
    let totalMass: Double
    let stallSpeed: Double
    let t: Double
    private var obstacles: [(lo: SIMD3<Double>, hi: SIMD3<Double>)] = []
    private var capsules: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double)] = []
    /// Swept control-surface points, bucketed in 6 mm cells.
    private var sweep: [SIMD3<Int32>: [SIMD3<Double>]] = [:]
    static let sweepCell = 6.0
    static func cell(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>((p / sweepCell).rounded(.down)) }

    /// Clear gap the rod keeps to every obstacle (mm, beyond the rod radius).
    static let clearance = 2.5
    /// Clear gap to the propeller disc / cylinder.
    static let propClearance = 6.0

    init(design: Design, totalMass: Double, stallSpeed: Double) {
        d = design; c = design.config; t = c.material.thickness
        self.totalMass = totalMass; self.stallSpeed = stallSpeed
        buildObstacles()
    }

    // MARK: Entry point

    /// Struts for the design (empty when none are needed or none fit).
    static func plan(_ d: Design, totalMass: Double, stallSpeed: Double) -> [Strut] {
        let c = d.config
        guard c.struts != .off else { return [] }
        let base = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed)
        let always = c.struts == .always
        let needWing = always || base.wingDeflectionRatio * 100 >= StructureReport.wingErrorPct
        let needTail = c.kind.hasTail && !c.kind.isTwinBoom
            && (always || (base.tailTwistDeg ?? 0) >= StructureReport.twistErrorDeg || (base.tailBendDeg ?? 0) >= StructureReport.bendErrorDeg)
        guard needWing || needTail else { return [] }
        let p = StrutPlanner(design: d, totalMass: totalMass, stallSpeed: stallSpeed)
        var struts: [Strut] = []
        if needTail { struts += p.tailStruts() }
        if needWing { struts += p.wingStruts(avoiding: struts) }
        // Whenever struts go in, the fin is braced too: one rod each side from the fixed stabiliser up to the fin.
        if !struts.isEmpty { struts += p.finStruts(avoiding: struts) }
        // Label S1, S2 … (left/right pairs share a number: S1 L / S1 R).
        var out: [Strut] = []
        var n = 0
        var lastKey = ""
        for s in struts {
            let key = s.name
            if key != lastKey { n += 1; lastKey = key }
            var s2 = s
            s2.label = "S\(n)\(s.a.surface.x < 0 ? "L" : "R")"
            out.append(s2)
        }
        return out
    }

    // MARK: Geometry queries

    struct Site {
        var part: Int, inst: Int
        var plan: Vec2
        var point: SIMD3<Double>
        var normal: SIMD3<Double>
    }

    /// Wing surface spot at world (x, z): top or bottom face.
    func wingSite(x: Double, z: Double, top: Bool) -> Site? {
        for (pi, part) in d.parts.enumerated() where part.role == .wing {
            for (ii, inst) in part.instances.enumerated() where abs(inst.normal.y) > 0.7 && abs(inst.v.x) > 0.5 && abs(inst.u.z) > 0.9 {
                let p = Vec2((z - inst.origin.z) / inst.u.z, (x - inst.origin.x) / inst.v.x)
                guard Poly.contains(part.outline, p) else { continue }
                let flip: Double = inst.normal.y < 0 ? -1 : 1
                let s: Double = top ? 1 : -1
                return Site(part: pi, inst: ii, plan: p, point: inst.point(p, offset: part.thickness / 2 * flip * s), normal: inst.normal * flip * s)
            }
        }
        return nil
    }

    /// Chord of the wing at span station x (world z of leading and trailing edge, from the wing parts' outlines).
    func wingChord(atX x: Double) -> (le: Double, te: Double)? {
        for part in d.parts where part.role == .wing {
            for inst in part.instances where abs(inst.normal.y) > 0.7 && abs(inst.v.x) > 0.5 && abs(inst.u.z) > 0.9 {
                let v = (x - inst.origin.x) / inst.v.x
                let us = Self.crossings(part.outline, atV: v)
                guard let lo = us.min(), let hi = us.max(), hi - lo > 10 else { continue }
                let z0 = inst.origin.z + inst.u.z * lo, z1 = inst.origin.z + inst.u.z * hi
                return (min(z0, z1), max(z0, z1))
            }
        }
        return nil
    }

    static func crossings(_ poly: [Vec2], atV v: Double) -> [Double] {
        var out: [Double] = []
        for i in poly.indices {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y - v) * (b.y - v) <= 0 && abs(b.y - a.y) > 1e-9 { out.append(a.x + (b.x - a.x) * (v - a.y) / (b.y - a.y)) }
        }
        return out
    }
    static func crossings(_ poly: [Vec2], atU u: Double) -> [Double] {
        crossings(poly.map { Vec2($0.y, $0.x) }, atV: u)
    }

    /// Vertical fuselage webs (spine, keel, fuselage halves, pod halves).
    var webs: [(part: Int, insts: [Int])] {
        d.parts.enumerated().compactMap { (pi, part) in
            guard part.role == .fuselage else { return nil }
            let ii = part.instances.indices.filter { abs(part.instances[$0].normal.x) > 0.9 && abs(part.instances[$0].u.z) > 0.9 }
            return ii.isEmpty ? nil : (pi, ii)
        }
    }

    /// Top (`top` true) or bottom edge of the webs at station z (world y), nil when there is no web there.
    func webEdge(z: Double, top: Bool) -> Double? {
        var best: Double?
        for w in webs {
            let part = d.parts[w.part], inst = part.instances[w.insts[0]]
            let ys = Self.crossings(part.outline, atU: (z - inst.origin.z) / inst.u.z).map { inst.origin.y + inst.v.y * $0 }
            guard let e = top ? ys.max() : ys.min() else { continue }
            if top ? e > t / 2 + 1 : e < -t / 2 - 1 {
                best = best.map { top ? max($0, e) : min($0, e) } ?? e
            }
        }
        return best
    }

    /// Spot on the outer face of a web (side +1 right, −1 left) at world (z, y).
    func webSite(z: Double, y: Double, side: Double) -> Site? {
        for w in webs {
            let part = d.parts[w.part]
            let inst = part.instances[w.insts[0]]
            let p = Vec2((z - inst.origin.z) / inst.u.z, (y - inst.origin.y) / inst.v.y)
            guard Poly.contains(part.outline, p) else { continue }
            let xs = w.insts.map { part.instances[$0].origin.x }
            let face = side > 0 ? xs.max()! + part.thickness / 2 : xs.min()! - part.thickness / 2
            let ii = side > 0 ? w.insts.max { part.instances[$0].origin.x < part.instances[$1].origin.x }!
                              : w.insts.min { part.instances[$0].origin.x < part.instances[$1].origin.x }!
            return Site(part: w.part, inst: ii, plan: p, point: [face, y, z], normal: [side, 0, 0])
        }
        return nil
    }

    /// Plan coordinates of a direction lying in a part instance's plane.
    func planDir(_ v: SIMD3<Double>, _ s: Site) -> Vec2 {
        let inst = d.parts[s.part].instances[s.inst]
        let p = Vec2(simd_dot(v, inst.u), simd_dot(v, inst.v))
        return simd_length(p) > 1e-9 ? simd_normalize(p) : Vec2(1, 0)
    }

    /// The anchor pad fits on the solid, fixed foam (not on a control surface, clear of slots and servo cutouts).
    func padFits(_ s: Site, dir: Vec2, size: Vec2) -> Bool {
        let part = d.parts[s.part]
        let fixed = part.regions.first { !$0.isControl }?.polygon ?? part.outline
        let w = Vec2(-dir.y, dir.x)
        let holes = part.holes.map { h -> (lo: Vec2, hi: Vec2) in
            let b = Poly.bounds(h.polygon)
            let m = h.kind == .servo ? PrintedParts.servoFrameFlange + 1.5 : 1.5
            return (b.min - Vec2(m, m), b.max + Vec2(m, m))
        }
        for i in 0...4 {
            for j in 0...4 {
                let q = s.plan + dir * (size.x + 3) * (Double(i) / 4 - 0.5) + w * (size.y + 3) * (Double(j) / 4 - 0.5)
                if !Poly.contains(fixed, q) || !Poly.contains(part.outline, q) { return false }
                if holes.contains(where: { q.x > $0.lo.x && q.x < $0.hi.x && q.y > $0.lo.y && q.y < $0.hi.y }) { return false }
            }
        }
        return true
    }

    // MARK: Anchors & rods

    static let bossLength = 8.0
    /// Extra control-surface travel kept free of struts beyond the type's maximum throw (degrees).
    static let throwMargin = 5.0
    static let padThickness = 1.2
    static func bossSide(_ dia: Double) -> Double { dia + 2.4 }

    /// Pad footprint (along the rod direction × across) for a rod elevation.
    static func padSize(dia: Double, elevation phi: Double) -> Vec2 {
        let B = bossSide(dia)
        let foot = bossLength * cos(phi) + B * sin(phi)
        return Vec2(max(9, foot + 3), max(8, B + 4))
    }

    func anchor(_ s: Site, towards other: SIMD3<Double>, dia: Double) -> StrutAnchor {
        let e = simd_normalize(other - s.point)
        var along = e - simd_dot(e, s.normal) * s.normal
        if simd_length(along) < 1e-6 { along = simd_normalize(simd_cross(s.normal, [0, 0, 1])) }
        along = simd_normalize(along)
        let phi = asin(min(1, max(0, simd_dot(e, s.normal))))
        let B = Self.bossSide(dia)
        // Boss axis starts B/2·cosφ above the pad top and is centred over the pad.
        let rodEnd = s.point + s.normal * (Self.padThickness + B / 2 * cos(phi)) - along * (Self.bossLength * cos(phi) / 2)
        let size = Self.padSize(dia: dia, elevation: phi)
        return StrutAnchor(partIndex: s.part, instanceIndex: s.inst, plan: s.plan, planDir: planDir(along, s), surface: s.point,
                           normal: s.normal, along: along, elevation: phi, rodEnd: rodEnd, padSize: size)
    }

    /// Strut between two sites; nil if the rod would run into the foam at either end (elevation ≤ 0).
    func strut(_ name: String, _ group: StrutGroup, wing: Site, body: Site, dia: Double) -> Strut? {
        guard simd_dot(body.point - wing.point, wing.normal) > 1, simd_dot(wing.point - body.point, body.normal) > 1 else { return nil }
        var a = anchor(wing, towards: body.point, dia: dia), b = anchor(body, towards: wing.point, dia: dia)
        // Second pass with the rod ends instead of the surface points (the bosses lift the rod slightly).
        a = anchor(wing, towards: b.rodEnd, dia: dia); b = anchor(body, towards: a.rodEnd, dia: dia)
        guard padFits(wing, dir: a.planDir, size: a.padSize), padFits(body, dir: b.planDir, size: b.padSize) else { return nil }
        return Strut(label: "", name: name, group: group, diameter: dia, a: a, b: b)
    }

    // MARK: Obstacles

    private mutating func buildObstacles() {
        let tw = t * Double(c.fuselageType.webLayers)
        func box(_ p: SIMD3<Double>, _ size: SIMD3<Double>, margin m: Double = 1) { obstacles.append((p - size / 2 - m, p + size / 2 + m)) }
        let lim = Analysis.batteryLimits(c)
        for item in d.components {
            let p = item.position
            switch item.category {
            case "Battery":
                let s = c.battery.size
                let size: SIMD3<Double> = c.kind.isTailless ? [s.w, s.h, s.l] : [s.h, s.w, s.l]
                let q = c.kind.isTailless ? p + [0, 1.2, 0] : p + [1.2, 0, 0]
                // The battery slides between its limits when the model is balanced: keep its whole travel free.
                let z0 = min(p.z, lim.lowerBound) - s.l / 2 - 2, z1 = max(p.z, lim.upperBound) + s.l / 2 + 2
                obstacles.append((SIMD3(q.x - size.x / 2 - 1.5, q.y - size.y / 2 - 1, z0), SIMD3(q.x + size.x / 2 + 1, q.y + size.y / 2 + 1, z1)))
                obstacles.append((SIMD3(tw / 2, q.y - size.y / 2 - 1, z0), SIMD3(tw / 2 + 1.5, q.y + size.y / 2 + 1, z1)))   // tray
            case "Power" where item.name.contains("brushless"):
                let r = c.motor.bellDiameter / 2 + 3
                obstacles.append((SIMD3(p.x - r, -r, min(c.firewallZ, c.motorZ) - c.motorLength - 3),
                                  SIMD3(p.x + r, r, max(c.firewallZ, c.motorZ) + c.motorLength + 3)))
            case "Power" where item.name.hasPrefix("ESC"):
                let e: SIMD3<Double> = c.motor.escMass > 4 ? [24, 13, 5] : [18, 10, 4]
                box(p, (c.isDual || c.kind.isTailless) ? [e.y, e.z, e.x] : [e.z, e.y, e.x], margin: 2)
            case "Radio" where item.name.hasPrefix("Receiver"):
                box(p, c.kind.isTailless ? [10, 3, 14] : [3, 10, 14], margin: 2)
            case "Printed" where item.name.hasPrefix("Motor mount") || item.name.hasPrefix("Nose protector"):
                let m = PrintedParts.motorMountPlate(c.motor, foam: t) / 2 + 2
                obstacles.append((SIMD3(p.x - m, -m, p.z - PrintedParts.mountJaw - 3), SIMD3(p.x + m, m, p.z + PrintedParts.mountJaw + 3)))
            default:
                if item.name.hasPrefix("Servo") {
                    let s = c.servo.size
                    let standing = item.name.contains("double arm")
                    box(p, standing ? [s.w, s.h, s.l] : [s.h, s.w, s.l], margin: 2)
                    // Servo frame flange on the foam.
                    if abs(p.y) < 0.5 { box(p, [s.h + 6, s.w + 6, s.l + 6], margin: 1) }
                }
            }
        }
        for ctrl in d.controls {
            let arm = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
            capsules.append((arm, ctrl.hornPosition, 3.5))                                   // pushrod (moves a little)
            capsules.append((arm, arm, 7))                                                   // servo arm swing
            capsules.append((ctrl.servoPosition, arm, 4))
            capsules.append((ctrl.hornPosition - ctrl.hornAxis * 12, ctrl.hornPosition, 6))  // horn
        }
        // Control surfaces over their whole travel (the type's max throw + 5° about the hinge line, every 5°), so no
        // rod or boss can sit inside the swept volume of an aileron, elevon, elevator or rudder.
        let travel = c.kind.maxSurfaceThrow + Self.throwMargin
        for part in d.parts {
            for r in part.regions where r.isControl {
                guard let axis = SceneBuilder.hingeAxis(part, r.polygon) else { continue }
                var pts = r.polygon
                let b = Poly.bounds(r.polygon)
                var u = b.min.x
                while u <= b.max.x {
                    var v = b.min.y
                    while v <= b.max.y { if Poly.contains(r.polygon, Vec2(u, v)) { pts.append(Vec2(u, v)) }; v += 3 }
                    u += 3
                }
                for inst in part.instances {
                    let a3 = inst.point(axis.0), b3 = inst.point(axis.1)
                    let ax = simd_normalize(b3 - a3)
                    for ang in stride(from: -travel, through: travel, by: 5) {
                        let q = simd_quatd(angle: ang * .pi / 180, axis: ax)
                        for p in pts {
                            for off in [-part.thickness / 2, part.thickness / 2] { let w = q.act(inst.point(p, offset: off) - a3) + a3; sweep[Self.cell(w), default: []].append(w) }
                        }
                    }
                }
            }
        }
    }

    static func distance(_ p: SIMD3<Double>, segment a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        let k = l2 > 1e-12 ? min(1, max(0, simd_dot(p - a, ab) / l2)) : 0
        return simd_distance(p, a + ab * k)
    }

    /// Gap between a point and the spinning propeller(s) (cylinder model, see PropClearance).
    func propGap(_ p: SIMD3<Double>) -> Double {
        let toMotor: Double = c.isPusher ? -1 : 1
        var g = Double.greatestFiniteMagnitude
        for mx in c.motorXs {
            let r = simd_length(SIMD2(p.x - mx, p.y))
            let s = (p.z - c.propPlaneZ) * toMotor
            let ax = s >= 0 ? max(0, s - c.propDepthIn) : max(0, -s - c.propDepthOut)
            let rad = max(0, r - c.propRadius)
            g = min(g, (ax * ax + rad * rad).squareRoot())
        }
        return g
    }

    /// The rod keeps clear of hardware, prop, moving surfaces, foam and the other struts.
    func isClear(_ s: Strut, others: [Strut]) -> Bool {
        let a = s.a.rodEnd, b = s.b.rodEnd
        let r = s.diameter / 2
        let L = simd_distance(a, b)
        let n = max(2, Int(L / 1.5))
        let need = r + Self.clearance
        for k in 0...n {
            let p = a + (b - a) * (Double(k) / Double(n))
            let along = L * Double(k) / Double(n)
            let nearEnd = along < Self.bossLength + 3 || along > L - Self.bossLength - 3
            if propGap(p) < Self.propClearance + r { return false }
            for o in obstacles {
                let q = simd_clamp(p, o.lo, o.hi)
                if simd_distance(p, q) < need { return false }
            }
            for cp in capsules where Self.distance(p, segment: cp.a, cp.b) < cp.r + need - 1 { return false }
            if !nearEnd && insideFoam(p, margin: r + 0.5) { return false }
            for o in others where Self.distance(p, segment: o.a.rodEnd, o.b.rodEnd) < r + o.diameter / 2 + 1.5 && !nearEnd { return false }
        }
        // Control-surface travel: the rod and both anchor bosses stay out of the swept volume.
        let bosses = [(s.a.rodEnd, s.a.rodEnd + simd_normalize(b - a) * Self.bossLength), (s.b.rodEnd, s.b.rodEnd + simd_normalize(a - b) * Self.bossLength)]
        let bossR = Self.bossSide(s.diameter) / 2 * 2.squareRoot()
        assert(max(need, bossR) + 0.5 + 1.5 < Self.sweepCell)
        // Every point within m of a segment lies in a cell next to a sample taken every 3 mm along it (m + 1.5 < cell).
        var cells = Set<SIMD3<Int32>>()
        for (p0, p1) in [(a, b)] + bosses {
            let k = max(1, Int(simd_distance(p0, p1) / 3))
            for i in 0...k {
                let c0 = Self.cell(p0 + (p1 - p0) * (Double(i) / Double(k)))
                for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 { cells.insert(c0 &+ SIMD3(dx, dy, dz)) } } }
            }
        }
        for cl in cells {
            for q in sweep[cl] ?? [] {
                if Self.distance(q, segment: a, b) < need + 0.5 { return false }
                for bs in bosses where Self.distance(q, segment: bs.0, bs.1) < bossR + 0.5 { return false }
            }
        }
        return true
    }

    func insideFoam(_ p: SIMD3<Double>, margin: Double) -> Bool {
        for part in d.parts {
            for inst in part.instances {
                let q = p - inst.origin
                let off = simd_dot(q, inst.normal)
                guard abs(off) < part.thickness / 2 + margin else { continue }
                let pp = Vec2(simd_dot(q, inst.u), simd_dot(q, inst.v))
                if Poly.contains(part.outline, pp) { return true }
            }
        }
        return false
    }

    // MARK: Fin struts

    /// Horizontal tail surface: the stabiliser (or the fuselage / tail plate that carries the elevator), its
    /// horizontal instance, the elevator hinge station (world z) and the elevator's half span.
    var stabiliser: (part: Int, inst: Int, hingeZ: Double, halfSpan: Double)? {
        // NutBall: the elevator runs across the disc's trailing edge, so the disc is the "stabiliser".
        for (pi, part) in d.parts.enumerated() where part.role == .stabilizer || part.role == .fuselage || (c.kind.isNutBall && part.role == .wing) {
            guard let ii = part.instances.indices.first(where: { abs(part.instances[$0].normal.y) > 0.7 && abs(part.instances[$0].u.z) > 0.9 }),
                  let elev = part.regions.first(where: \.isControl), let axis = SceneBuilder.hingeAxis(part, elev.polygon) else { continue }
            let inst = part.instances[ii]
            let zH = inst.point((axis.0 + axis.1) / 2).z
            let half = elev.polygon.map { abs(inst.point($0).x) }.max() ?? 0
            guard half > 20 else { continue }
            return (pi, ii, zH, half)
        }
        return nil
    }

    /// Top-face spot of a horizontal part at world (x, z).
    func flatSite(part pi: Int, inst ii: Int, x: Double, z: Double) -> Site? {
        let part = d.parts[pi], inst = part.instances[ii]
        let p = Vec2(simd_dot(SIMD3(x, inst.origin.y, z) - inst.origin, inst.u), simd_dot(SIMD3(x, inst.origin.y, z) - inst.origin, inst.v))
        guard Poly.contains(part.outline, p) else { return nil }
        let flip: Double = inst.normal.y < 0 ? -1 : 1
        return Site(part: pi, inst: ii, plan: p, point: inst.point(p, offset: part.thickness / 2 * flip), normal: inst.normal * flip)
    }

    /// One rod each side from the fixed part of the stabiliser (ahead of the elevator hinge, mid half-span) up to the
    /// fixed fin (ahead of the rudder hinge): braces the fin sideways and keeps clear of elevator and rudder travel,
    /// their horns and pushrods. Candidates in order of preference; the thinnest rod that fits and does not buckle.
    func finStruts(avoiding existing: [Strut]) -> [Strut] {
        guard !c.kind.isTailless, !c.kind.isTwinBoom, let st = stabiliser else { return [] }
        let stab = d.parts[st.part], inst = stab.instances[st.inst]
        // Only the fin rods' own buckling counts here (the wing / tail set was chosen before).
        let alreadyBuckles = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed, struts: existing).strutsBuckle
        // Fixed stabiliser chord at span station x: the outline interval that ends at (or behind) the hinge.
        func stabLE(_ x: Double) -> Double? {
            let v = simd_dot(SIMD3(x, inst.origin.y, 0) - inst.origin, inst.v)
            let zs = Self.crossings(stab.outline, atV: v).map { inst.origin.z + inst.u.z * $0 }.sorted()
            return zs.last { $0 < st.hingeZ - 15 }
        }
        for fx in [0.55, 0.45, 0.65, 0.35, 0.75, 0.25] {
            let x = fx * st.halfSpan
            guard let le = stabLE(x) else { continue }
            for fz in [0.5, 0.35, 0.65, 0.2, 0.8, 0.9] {
                let zs = le + 6 + fz * (st.hingeZ - 12 - le)
                guard zs < st.hingeZ - 8 else { continue }
                for dz in [0.0, -10, 10, -20, 20] {
                    let zf = zs + dz
                    guard zf < st.hingeZ - 8, let top = webEdge(z: zf, top: true) else { continue }
                    let root = t / 2
                    guard top - root > 30 else { continue }
                    for fh in [0.6, 0.5, 0.7, 0.4] {
                        let yf = root + fh * (top - root)
                        for dia in CarbonSpar.strutDiameters {
                            var pair: [Strut] = []
                            for side in [1.0, -1.0] {
                                guard let a = flatSite(part: st.part, inst: st.inst, x: side * x, z: zs),
                                      let b = webSite(z: zf, y: yf, side: side),
                                      let s = strut("Fin strut", .fin, wing: a, body: b, dia: dia) else { break }
                                pair.append(s)
                            }
                            guard pair.count == 2,
                                  isClear(pair[0], others: existing + [pair[1]]), isClear(pair[1], others: existing + [pair[0]]) else { continue }
                            let rep = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed, struts: existing + pair)
                            if !rep.strutsBuckle || alreadyBuckles { return pair }
                        }
                    }
                }
            }
        }
        return []
    }

    // MARK: Wing struts

    /// Pairs of rods per side from the wing (underside / top) to the bottom / top edge of the fuselage webs: they
    /// prop the wing at the strut station. Candidates are tried in order of preference (mid span, spar line); the
    /// first that fits and reaches the target – lightest rod set first, no buckling – wins.
    func wingStruts(avoiding existing: [Strut]) -> [Strut] {
        let s = c.semiSpan
        var fallback: (score: Double, struts: [Strut])?
        let rootClear = max(c.kind.hasFuselage ? c.fuselagePlateWidth / 2 : 0, c.isDual ? c.dualMotorX + c.propRadius + 8 : 0) + 30
        for f in [0.55, 0.45, 0.65, 0.38, 0.72] {
            let x = f * s
            guard x > rootClear, x < s - 25, let ch = wingChord(atX: x) else { continue }
            for q in [0.3, 0.38, 0.22, 0.46, 0.55, 0.15] {
                let z = ch.le + q * (ch.te - ch.le)
                for dz in [0.0, -14, 14, 28, -28, 42, -42] {
                    let zb = z + dz
                    var fitted = false
                    for dia in CarbonSpar.strutDiameters {
                        var lower: [Strut] = [], upper: [Strut] = []
                        for side in [1.0, -1.0] {
                            if let bottom = webEdge(z: zb, top: false), bottom < -(t / 2 + 14),
                               let w = wingSite(x: side * x, z: z, top: false) {
                                for inset in [7.0, 11, 15] {
                                    if let b = webSite(z: zb, y: bottom + inset, side: side),
                                       let st = strut("Wing strut below", .wing, wing: w, body: b, dia: dia) { lower.append(st); break }
                                }
                            }
                            if let top = webEdge(z: zb, top: true), top > t / 2 + 14,
                               let w = wingSite(x: side * x, z: z, top: true) {
                                for inset in [7.0, 11, 15] {
                                    if let b = webSite(z: zb, y: top - inset, side: side),
                                       let st = strut("Wing strut above", .wing, wing: w, body: b, dia: dia) { upper.append(st); break }
                                }
                            }
                        }
                        let lowerOK = lower.count == 2 && lower.allSatisfy { isClear($0, others: existing) }
                        let upperOK = upper.count == 2 && upper.allSatisfy { isClear($0, others: existing + (lowerOK ? lower : [])) }
                        // Rods below the wing work in tension under positive g – lightest and buckling-free first.
                        var sets: [[Strut]] = []
                        if lowerOK { sets.append(lower) }
                        if lowerOK && upperOK { sets.append(lower + upper) }
                        if upperOK { sets.append(upper) }
                        guard !sets.isEmpty else { break }   // a thicker rod will not fit where a thin one does not
                        fitted = true
                        for set in sets {
                            let rep = StructureReport(c, totalMass: totalMass + set.reduce(0) { $0 + $1.rodMass + 0.3 }, stallSpeed: stallSpeed, struts: existing + set)
                            let pct = rep.wingDeflectionRatio * 100
                            if pct < StructureReport.wingWarnPct && !rep.strutsBuckle { return set }
                            let score = pct + (rep.strutsBuckle ? 100 : 0)
                            if fallback == nil || score < fallback!.score { fallback = (score, set) }
                        }
                    }
                    _ = fitted
                }
            }
        }
        // Nothing reaches the target: the stiffest set that does not buckle, if it helps at all.
        if let fb = fallback, fb.score < 100 { return fb.struts }
        return []
    }

    // MARK: Tail struts

    /// Rods per side from the aft part of the wing (top and underside) to the top and bottom edges of the tail
    /// boom: they tie the tail to the wing against twisting and bending.
    func tailStruts() -> [Strut] {
        let s = c.semiSpan
        var fallback: (score: Double, struts: [Strut])?
        let rootClear = max(c.fuselagePlateWidth / 2, c.isDual ? c.dualMotorX + c.propRadius + 8 : 0) + 25
        let rc = c.rootChord
        // Boom stations aft of the wing (aft-most first), where the webs are deep enough for an anchor.
        let tailEnd = c.tailArm + c.hStabChord
        var upperZ: [Double] = [], lowerZ: [Double] = []
        var z = tailEnd
        while z > rc + 25 {
            if let top = webEdge(z: z, top: true), top < t / 2 + c.boomTopHeight + 3, top > t / 2 + 11 { upperZ.append(z) }
            if let bot = webEdge(z: z, top: false), bot < -(t / 2 + 11) { lowerZ.append(z) }
            z -= 8
        }
        func thin(_ zs: [Double]) -> [Double] { zs.count <= 8 ? zs : stride(from: 0, to: zs.count, by: max(1, zs.count / 8)).map { zs[$0] } }
        upperZ = thin(upperZ); lowerZ = thin(lowerZ)
        for f in [0.4, 0.5, 0.32, 0.6, 0.25] {
            let x = f * s
            guard x > rootClear, x < s - 25, let ch = wingChord(atX: x) else { continue }
            // Forward chord stations last: they give the rod room to drop clear of the aileron's travel behind the hinge.
            for q in [0.6, 0.52, 0.68, 0.44, 0.36, 0.3] {
                let zw = ch.le + q * (ch.te - ch.le)
                for dia in CarbonSpar.strutDiameters {
                    func pick(_ zs: [Double], top: Bool, name: String, others: [Strut]) -> [Strut] {
                        for zt in zs {
                            var pair: [Strut] = []
                            for side in [1.0, -1.0] {
                                guard let w = wingSite(x: side * x, z: zw, top: top), let edge = webEdge(z: zt, top: top) else { break }
                                for inset in [7.0, 10, 13] {
                                    if let b = webSite(z: zt, y: top ? edge - inset : edge + inset, side: side),
                                       let st = strut(name, .tail, wing: w, body: b, dia: dia) { pair.append(st); break }
                                }
                            }
                            if pair.count == 2 && pair.allSatisfy({ isClear($0, others: others) }) { return pair }
                        }
                        return []
                    }
                    let upper = pick(upperZ, top: true, name: "Tail strut above", others: [])
                    let lower = pick(lowerZ, top: false, name: "Tail strut below", others: upper)
                    var sets: [[Strut]] = []
                    if lower.count == 2 { sets.append(lower) }
                    if upper.count == 2 { sets.append(upper) }
                    if upper.count == 2 && lower.count == 2 { sets.append(upper + lower) }
                    guard !sets.isEmpty else { break }
                    for set in sets {
                        let rep = StructureReport(c, totalMass: totalMass + set.reduce(0) { $0 + $1.rodMass + 0.3 }, stallSpeed: stallSpeed, struts: set)
                        let tw = rep.tailTwistDeg ?? 0, bd = rep.tailBendDeg ?? 0
                        // 10 % margin: wing and fin struts added afterwards raise the weight (and load speed) a little.
                        if tw < 0.9 * StructureReport.twistWarnDeg && bd < 0.9 * StructureReport.bendWarnDeg && !rep.strutsBuckle { return set }
                        let score = tw / StructureReport.twistWarnDeg + bd / StructureReport.bendWarnDeg + (rep.strutsBuckle ? 100 : 0)
                        if fallback == nil || score < fallback!.score { fallback = (score, set) }
                    }
                }
            }
        }
        if let fb = fallback, fb.score < 100 { return fb.struts }
        return []
    }
}
