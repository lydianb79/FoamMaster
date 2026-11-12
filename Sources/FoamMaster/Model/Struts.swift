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
    var name: String { [.auto: "Auto", .always: "On", .off: "Off"][self]! }
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
    /// Set when this end shares a one-piece saddle with its mirror end (bottom of the fuselage).
    var saddle: StrutSaddle? = nil
    /// > 0: the boss sits on the side of a printed foot under the bottom edge of the web (depth of the foot); the
    /// end then always gets a saddle.
    var footDepth: Double = 0
    /// Set when this end shares one printed pad with the end of another strut beside it (wing underside).
    var shared: SharedPad? = nil
}

/// One printed anchor for two rod ends side by side: a pad covering both footprints with both bosses on it.
struct SharedPad {
    /// Labels of the two struts (sorted), the part / instance and the pad outline on the part plan.
    var labels: [String]
    var partIndex: Int
    var instanceIndex: Int
    var plan: [Vec2]
}

/// One-piece printed mount for a left/right strut pair at the bottom edge of the fuselage web: a side plate on each
/// face carrying that side's rod boss, joined by a bridge under the edge. World frame (the webs are symmetric about
/// x = 0, so the saddle is too).
struct StrutSaddle {
    /// Pair label without the side (S1 …) and the web part / instance the plates sit on.
    var label: String
    var partIndex: Int
    var instanceIndex: Int
    /// Outer face of the web (|x|), bottom edge (top of the bridge, world y), top of the side plates, z extent.
    var faceX: Double
    /// Bottom edge at z0 and z1 (the bridge follows the edge's slope).
    var edgeY0: Double
    var edgeY1: Double
    var plateTop: Double
    /// Depth of the solid foot under the edge carrying the bosses (0 = plain bridge, bosses on the side plates).
    var footDepth: Double = 0
    var z0: Double
    var z1: Double
    /// Outline of the side plates on the part plan (edge up to the plate top).
    var plan: [Vec2]
    var edgeY: Double { (edgeY0 + edgeY1) / 2 }
    var plateArea: Double { (plateTop - edgeY) * (z1 - z0) }
    var bridgeArea: Double { 2 * faceX * (z1 - z0) }
    var center: SIMD3<Double> { [0, (edgeY + plateTop) / 2, (z0 + z1) / 2] }
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
    /// Stiffness of one anchor on the foam along the rod (N/mm). A glued pad acts like a rigid punch on the foam:
    /// normal to the surface k_n = 2·a·E, along it k_t = 2·a·G (a = equivalent pad radius). The rod is pinned, so the
    /// anchor may move freely across it: the axial stiffness is the compliance along the rod,
    /// k = 1 / (sin²φ / k_n + cos²φ / k_t), φ = rod angle to the surface.
    ///
    /// Saddle ends (one-piece mount wrapping the bottom edge of the web): with a symmetric load (3 g pull, elevator)
    /// the sideways pulls of the left and right rods meet in the bridge (a PETG tie, E·A/L), and the vertical share of
    /// both rods goes into both side plates in shear plus the bridge bearing on the edge – shared by the two rods.
    /// With an antisymmetric load (rudder twist) both rods push the saddle the same way sideways: both plates and the
    /// edge carry it, again shared by the two rods.
    static func anchorStiffness(_ end: StrutAnchor, _ m: FoamMaterial, symmetric: Bool = true) -> Double {
        let e = end.normal * sin(end.elevation) + end.along * cos(end.elevation)
        guard let sd = end.saddle else {
            let a = (end.padSize.x * end.padSize.y / .pi).squareRoot()
            let s2 = sin(end.elevation) * sin(end.elevation)
            return 1 / (s2 / (2 * a * m.modulus) + (1 - s2) / (2 * a * m.shearModulus))
        }
        let ap = (sd.plateArea / .pi).squareRoot(), ab = (sd.bridgeArea / .pi).squareRoot()
        let en = simd_dot(e, end.normal), ey = e.y, ez = e.z
        // Sideways (normal to the web).
        let kn: Double
        if symmetric {
            let tie = StrutPlanner.petgModulus * StrutPlanner.padThickness * (sd.z1 - sd.z0) / (2 * sd.faceX)
            kn = tie
        } else {
            kn = (2 * 2 * ap * m.modulus + 2 * ab * m.shearModulus) / 2
        }
        // In the web plane: both plates in shear, vertical also the bridge bearing on the edge; two rods share it.
        let kz = 2 * 2 * ap * m.shearModulus / 2
        let ky = (2 * 2 * ap * m.shearModulus + 2 * ab * m.modulus) / 2
        return 1 / (en * en / kn + ey * ey / ky + ez * ez / kz)
    }
    /// Effective axial stiffness of the strut as built (N/mm): rod in series with both anchors on the foam.
    /// `symmetric`: left and right rods loaded alike (wing, elevator) or opposite (rudder twist, fin).
    func stiffness(_ m: FoamMaterial, symmetric: Bool = true) -> Double {
        1 / (1 / axialStiffness + 1 / Self.anchorStiffness(a, m, symmetric: symmetric) + 1 / Self.anchorStiffness(b, m, symmetric: symmetric))
    }
    /// Euler buckling load, pinned ends (N).
    var bucklingLoad: Double { .pi * .pi * rod.roundEI / (length * length) }
}

extension CarbonSpar {
    static let strutDiameters: [Double] = [1, 1.5, 2, 2.5, 3]
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
    private var obstacles: [(lo: SIMD3<Double>, hi: SIMD3<Double>, name: String)] = []
    private var capsules: [(a: SIMD3<Double>, b: SIMD3<Double>, r: Double, name: String)] = []
    /// Swept control-surface points, bucketed in 6 mm cells.
    /// Moving surfaces (one per part instance) for the exact swept-volume test.
    private var swept: [SweptSurface] = []

    /// A control surface in its part instance's frame: hinge line (a0, along e), the side it lies on (eo), its outline,
    /// half thickness and travel. A point is inside the swept volume when, turned back towards the rest position by
    /// at most the travel, it lies in the surface slab (grown by the margin).
    struct SweptSurface {
        var origin: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, n: SIMD3<Double>
        var a0: Vec2, e: Vec2, eo: Vec2
        var poly: [Vec2]
        var half: Double
        var travel: Double
        var sRange: ClosedRange<Double>
        var reach: Double
        var center: SIMD3<Double>
        var radius: Double

        func contains(_ p: SIMD3<Double>, margin m: Double) -> Bool {
            guard simd_distance(p, center) < radius + m else { return false }
            let q = p - origin
            let P = Vec2(simd_dot(q, u), simd_dot(q, v)), off = simd_dot(q, n)
            let sAlong = simd_dot(P - a0, e)
            guard sAlong > sRange.lowerBound - m, sAlong < sRange.upperBound + m else { return false }
            let w = simd_dot(P - a0, eo)
            let rho = (w * w + off * off).squareRoot()
            guard rho < reach + m else { return false }
            let th = atan2(off, w)
            let th2 = th - min(max(th, -travel), travel)
            let n2 = rho * sin(th2), w2 = rho * cos(th2)
            guard abs(n2) <= half + m, w2 > -m else { return false }
            let flat = a0 + e * sAlong + eo * w2
            return Poly.contains(poly, flat) || Self.edgeDistance(poly, flat) <= m
        }

        static func edgeDistance(_ poly: [Vec2], _ q: Vec2) -> Double {
            var best = Double.greatestFiniteMagnitude
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count], ab = b - a
                let l2 = simd_length_squared(ab)
                let k = l2 > 1e-12 ? min(1, max(0, simd_dot(q - a, ab) / l2)) : 0
                best = min(best, simd_distance(q, a + ab * k))
            }
            return best
        }
    }

    func inSweptVolume(_ p: SIMD3<Double>, margin: Double) -> Bool { swept.contains { $0.contains(p, margin: margin) } }

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
        let needWing = c.wingStruts == .always || (c.wingStruts == .auto && base.wingDeflectionRatio * 100 >= StructureReport.wingErrorPct)
        let needTail = c.offersTailStruts && (c.tailStruts == .always || (c.tailStruts == .auto
            && ((base.tailTwistDeg ?? 0) >= StructureReport.twistErrorDeg || (base.tailBendDeg ?? 0) >= StructureReport.bendErrorDeg)))
        let wantFin = c.offersFinStruts && c.finStruts == .always
        guard needWing || needTail || wantFin else { return [] }
        let p = StrutPlanner(design: d, totalMass: totalMass, stallSpeed: stallSpeed)
        var struts: [Strut] = []
        if needTail { struts += p.tailStruts() }
        if needWing { struts += p.wingStruts(avoiding: struts) }
        // Fin bracing: one rod each side from the fixed stabiliser up to the fin – on Auto whenever other struts go in.
        if c.finStruts == .always || (c.finStruts == .auto && !struts.isEmpty) { struts += p.finStruts(avoiding: struts) }
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
        return p.combineWingEnds(p.combineBottomMounts(out))
    }

    /// Wing ends of two different struts lying side by side on the same wing face get one printed pad with both
    /// bosses, when the joint pad fits on the fixed foam clear of slots and cutouts.
    func combineWingEnds(_ struts: [Strut]) -> [Strut] {
        var out = struts
        for i in out.indices where out[i].a.shared == nil {
            for j in out.indices where j > i && out[j].a.shared == nil {
                let a = out[i].a, b = out[j].a
                guard a.partIndex == b.partIndex, a.instanceIndex == b.instanceIndex, simd_dot(a.normal, b.normal) > 0.99,
                      simd_distance(a.surface, b.surface) < 22 else { continue }
                // Joint outline: convex hull of both pad rectangles (plan coordinates), 1 mm margin.
                var pts: [Vec2] = []
                for e in [a, b] {
                    let w = Vec2(-e.planDir.y, e.planDir.x)
                    for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
                        pts.append(e.plan + e.planDir * (sx * (e.padSize.x / 2 + 1)) + w * (sy * (e.padSize.y / 2 + 1)))
                    } }
                }
                let hull = Self.convexHull(pts)
                let part = d.parts[a.partIndex]
                let fixed = part.regions.first { !$0.isControl }?.polygon ?? part.outline
                let holes = part.holes.map { h -> (lo: Vec2, hi: Vec2) in
                    let bb = Poly.bounds(h.polygon); let m = h.kind == .servo ? 1.5 : 1.5
                    return (bb.min - Vec2(m, m), bb.max + Vec2(m, m))
                }
                // Sample the hull edges and inside on a 2 mm grid.
                let bb = Poly.bounds(hull)
                var ok = true
                var u = bb.min.x
                while ok && u <= bb.max.x {
                    var v = bb.min.y
                    while v <= bb.max.y {
                        let q = Vec2(u, v)
                        if Poly.contains(hull, q) && (!Poly.contains(fixed, q) || !Poly.contains(part.outline, q)
                            || holes.contains(where: { q.x > $0.lo.x && q.x < $0.hi.x && q.y > $0.lo.y && q.y < $0.hi.y })) { ok = false; break }
                        v += 2
                    }
                    u += 2
                }
                guard ok else { continue }
                let sp = SharedPad(labels: [out[i].label, out[j].label].sorted(), partIndex: a.partIndex, instanceIndex: a.instanceIndex, plan: hull)
                out[i].a.shared = sp; out[j].a.shared = sp
                break
            }
        }
        return out
    }

    static func convexHull(_ points: [Vec2]) -> [Vec2] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Vec2] = [], upper: [Vec2] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Left and right rods that end side by side near the bottom edge of the same fuselage web get one printed
    /// saddle instead of two anchors – when the saddle (plates + bridge under the edge) is clear of the hardware.
    /// Pairs are found by their mirrored geometry (works before labelling, during the candidate search).
    func combineBottomMounts(_ struts: [Strut]) -> [Strut] {
        var out = struts
        var used: [(part: Int, z0: Double, z1: Double)] = []
        for i in out.indices { out[i].b.saddle = nil }
        for i in out.indices where out[i].b.surface.x > 0 {
            let base = out[i].label.hasSuffix("R") ? String(out[i].label.dropLast()) : out[i].label
            guard let j = out.indices.first(where: { k in
                k != i && abs(out[k].b.surface.x + out[i].b.surface.x) < 0.01 && simd_distance(SIMD2(out[k].b.surface.y, out[k].b.surface.z), SIMD2(out[i].b.surface.y, out[i].b.surface.z)) < 0.01
                    && abs(out[k].a.surface.x + out[i].a.surface.x) < 0.01 }) else { continue }
            let r = out[i].b, l = out[j].b
            let foot = r.footDepth
            guard abs(r.normal.x) > 0.9, abs(l.normal.x) > 0.9, r.partIndex == l.partIndex, r.surface.y < 0,
                  abs(r.surface.x + l.surface.x) < 0.01, abs(r.surface.y - l.surface.y) < 0.01, abs(r.surface.z - l.surface.z) < 0.01,
                  let edgeC = webEdge(z: r.surface.z, top: false), foot > 0 || r.surface.y - edgeC < 20 else { continue }
            // Plate = bounding box (in the web plane) of the rotated pad, extended down to the edge.
            let w = simd_cross(r.normal, r.along)
            var ys: [Double] = [], zs: [Double] = []
            for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
                let q = r.surface + r.along * (sx * r.padSize.x / 2) + w * (sy * r.padSize.y / 2)
                ys.append(q.y); zs.append(q.z)
            } }
            let z0 = zs.min()! - 1, z1 = zs.max()! + 1
            guard let e0 = webEdge(z: z0, top: false), let e1 = webEdge(z: z1, top: false) else { continue }
            // With a foot the plates only clip over the edge (8 mm up the foam); otherwise they reach the pad top.
            let edgeY = min(e0, e1), top = foot > 0 ? max(e0, e1) + 8 : ys.max()! + 0.5
            let fx = abs(r.surface.x), T = Self.padThickness
            // Clear of hardware (battery travel, servos, ESC, receiver …) and pushrods.
            let lo = SIMD3<Double>(-fx - T, edgeY - max(T, foot), z0), hi = SIMD3<Double>(fx + T, top, z1)
            let blocked = obstacles.contains { o in all(o.hi .> lo - 1) && all(o.lo .< hi + 1) }
                || capsules.contains { cp in
                    let c = simd_clamp((cp.a + cp.b) / 2, lo, hi)
                    return Self.distance(c, segment: cp.a, cp.b) < cp.r + 1 }
            // Two saddles never share the same stretch of edge.
            guard !blocked, !used.contains(where: { $0.part == r.partIndex && $0.z0 < z1 + 2 && z0 < $0.z1 + 2 }) else { continue }
            used.append((r.partIndex, z0, z1))
            let inst = d.parts[r.partIndex].instances[r.instanceIndex]
            let toPlan = { (y: Double, z: Double) in Vec2((z - inst.origin.z) / inst.u.z, (y - inst.origin.y) / inst.v.y) }
            let plan = [toPlan(e0, z0), toPlan(e1, z1), toPlan(top, z1), toPlan(top, z0)]
            let sd = StrutSaddle(label: base, partIndex: r.partIndex, instanceIndex: r.instanceIndex, faceX: fx,
                                 edgeY0: e0, edgeY1: e1, plateTop: top, footDepth: foot, z0: z0, z1: z1, plan: plan)
            out[i].b.saddle = sd; out[j].b.saddle = sd
        }
        return out
    }

    // MARK: Geometry queries

    struct Site {
        var part: Int, inst: Int
        var plan: Vec2
        var point: SIMD3<Double>
        var normal: SIMD3<Double>
        /// Foot depth when the site is on a printed foot under the web's bottom edge (no foam there).
        var foot: Double = 0
    }

    /// Spot on the side of a printed foot under the bottom edge of the web at station z (side +1 right, −1 left):
    /// the rod then stays below the fuselage, clear of the battery and everything else on its sides.
    func footSite(z: Double, side: Double, dia: Double) -> Site? {
        guard let edge = webEdge(z: z, top: false), edge < -(t / 2 + 3) else { return nil }
        for w in webs {
            let part = d.parts[w.part], inst = part.instances[w.insts[0]]
            let p = Vec2((z - inst.origin.z) / inst.u.z, (edge + 1 - inst.origin.y) / inst.v.y)
            guard Poly.contains(part.outline, p) else { continue }
            let xs = w.insts.map { part.instances[$0].origin.x }
            let face = side > 0 ? xs.max()! + part.thickness / 2 : xs.min()! - part.thickness / 2
            let ii = side > 0 ? w.insts.max { part.instances[$0].origin.x < part.instances[$1].origin.x }!
                              : w.insts.min { part.instances[$0].origin.x < part.instances[$1].origin.x }!
            let foot = Self.bossSide(dia) + 5
            // The boss stands on the side plate (one plate thickness outside the web face).
            return Site(part: w.part, inst: ii, plan: Vec2((z - inst.origin.z) / inst.u.z, (edge - foot / 2 - inst.origin.y) / inst.v.y),
                        point: [face + side * Self.padThickness * 0, edge - foot / 2, z], normal: [side, 0, 0], foot: foot)
        }
        return nil
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
            let m = h.kind == .servo ? 1.5 : 1.5
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
    /// Printed PETG/PLA (N/mm²) for the saddle bridge.
    static let petgModulus = 2000.0
    /// Buckling safety used while choosing rods (15 % above the check's 1.5).
    static let planBuckling = StructureReport.strutBucklingSafety * 1.15
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
        guard padFits(wing, dir: a.planDir, size: a.padSize), body.foot > 0 || padFits(body, dir: b.planDir, size: b.padSize) else { return nil }
        b.footDepth = body.foot
        return Strut(label: "", name: name, group: group, diameter: dia, a: a, b: b)
    }

    // MARK: Obstacles

    private mutating func buildObstacles() {
        let tw = t * Double(c.fuselageType.webLayers)
        func box(_ p: SIMD3<Double>, _ size: SIMD3<Double>, margin m: Double = 1, _ name: String) { obstacles.append((p - size / 2 - m, p + size / 2 + m, name)) }
        let lim = Analysis.batteryLimits(c)
        for item in d.components {
            let p = item.position
            switch item.category {
            case "Battery":
                let s = c.battery.size
                let size: SIMD3<Double> = c.kind.isTailless ? [s.w, s.h, s.l] : [s.h, s.w, s.l]
                let q = c.kind.isTailless ? p + [0, 1.2, 0] : p + [1.2, 0, 0]
                // The struts are re-planned on every build from the balanced battery position: keep that spot free
                // plus ±15 mm for fine-tuning the balance on the real model (within the physical limits).
                let z0 = max(p.z - 15, lim.lowerBound) - s.l / 2 - 2, z1 = min(p.z + 15, lim.upperBound) + s.l / 2 + 2
                obstacles.append((SIMD3(q.x - size.x / 2 - 1.5, q.y - size.y / 2 - 1, z0), SIMD3(q.x + size.x / 2 + 1, q.y + size.y / 2 + 1, z1), "battery travel"))
                obstacles.append((SIMD3(tw / 2, q.y - size.y / 2 - 1, z0), SIMD3(tw / 2 + 1.5, q.y + size.y / 2 + 1, z1), "battery tray"))
            case "Power" where item.name.contains("brushless"):
                let r = c.motor.bellDiameter / 2 + 3
                obstacles.append((SIMD3(p.x - r, -r, min(c.firewallZ, c.motorZ) - c.motorLength - 3),
                                  SIMD3(p.x + r, r, max(c.firewallZ, c.motorZ) + c.motorLength + 3), "motor"))
            case "Power" where item.name.hasPrefix("ESC"):
                let e: SIMD3<Double> = c.motor.escMass > 4 ? [24, 13, 5] : [18, 10, 4]
                box(p, (c.isDual || c.kind.isTailless) ? [e.y, e.z, e.x] : [e.z, e.y, e.x], margin: 2, "ESC")
            case "Radio" where item.name.hasPrefix("Receiver"):
                box(p, c.kind.isTailless ? [10, 3, 14] : [3, 10, 14], margin: 2, "receiver")
            case "Printed" where item.name.hasPrefix("Motor mount") || item.name.hasPrefix("Nose protector"):
                let m = PrintedParts.motorMountPlate(c.motor, foam: t) / 2 + 2
                obstacles.append((SIMD3(p.x - m, -m, p.z - PrintedParts.mountJaw - 3), SIMD3(p.x + m, m, p.z + PrintedParts.mountJaw + 3), "motor mount"))
            default:
                if item.name.hasPrefix("Servo") {
                    let s = c.servo.size
                    let standing = item.name.contains("double arm")
                    box(p, standing ? [s.w, s.h, s.l] : [s.h, s.w, s.l], margin: 2, item.name)
                }
            }
        }
        for ctrl in d.controls {
            let arm = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
            capsules.append((arm, ctrl.hornPosition, 3.5, ctrl.name + " pushrod"))                     // pushrod (moves a little)
            // Servo arm swinging about its shaft (arm length + its half width).
            let shaft = ctrl.shaft(c.servo)
            let swing = (ctrl.isDoubleArm ? c.servo.doubleArmHalf : c.servo.armLength) + ServoClass.armWidth / 2
            capsules.append((shaft, shaft, swing, ctrl.name + " servo arm"))
            capsules.append((shaft, arm, 3, ctrl.name + " servo arm"))
            capsules.append((ctrl.hornPosition - ctrl.hornAxis * 12, ctrl.hornPosition, 6, ctrl.name + " horn"))  // horn
        }
        // Control surfaces over their whole travel (the type's max throw + 5° about the hinge line, every 5°), so no
        // rod or boss can sit inside the swept volume of an aileron, elevon, elevator or rudder.
        let travel = c.kind.maxSurfaceThrow + Self.throwMargin
        for part in d.parts {
            for r in part.regions where r.isControl {
                guard let axis = SceneBuilder.hingeAxis(part, r.polygon) else { continue }
                let e = simd_normalize(axis.1 - axis.0)
                var eo = Vec2(-e.y, e.x)
                if simd_dot(Poly.centroid(r.polygon) - axis.0, eo) < 0 { eo = -eo }
                let ss = r.polygon.map { simd_dot($0 - axis.0, e) }, ws = r.polygon.map { simd_dot($0 - axis.0, eo) }
                for inst in part.instances {
                    let pts3 = r.polygon.map { inst.point($0) }
                    let ctr = pts3.reduce(SIMD3<Double>.zero, +) / Double(pts3.count)
                    let reach = (ws.max() ?? 0) + part.thickness
                    swept.append(SweptSurface(origin: inst.origin, u: inst.u, v: inst.v, n: inst.normal, a0: axis.0, e: e, eo: eo,
                                              poly: r.polygon, half: part.thickness / 2, travel: travel * .pi / 180,
                                              sRange: (ss.min() ?? 0)...(ss.max() ?? 0), reach: reach,
                                              center: ctr, radius: (pts3.map { simd_distance($0, ctr) }.max() ?? 0) + reach))
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
    func isClear(_ s: Strut, others: [Strut]) -> Bool { blocker(s, others: others) == nil }

    /// What the rod (or one of its bosses) runs into, nil when it is clear.
    func blocker(_ s: Strut, others: [Strut]) -> String? {
        let a = s.a.rodEnd, b = s.b.rodEnd
        let r = s.diameter / 2
        let L = simd_distance(a, b)
        let n = max(2, Int(L / 1.5))
        let need = r + Self.clearance
        // Control-surface travel first (exact swept-volume test, the most common blocker): the rod and both anchor
        // bosses stay out of every surface's travel, sampled every 1 mm.
        let bosses = [(s.a.rodEnd, s.a.rodEnd + simd_normalize(b - a) * Self.bossLength), (s.b.rodEnd, s.b.rodEnd + simd_normalize(a - b) * Self.bossLength)]
        let bossR = Self.bossSide(s.diameter) / 2 * 2.squareRoot()
        for (p0, p1, m, what) in [(a, b, need + 0.5, "rod")] + bosses.map({ ($0.0, $0.1, bossR + 0.5, "boss") }) {
            let k = max(1, Int(simd_distance(p0, p1)))
            for i in 0...k where inSweptVolume(p0 + (p1 - p0) * (Double(i) / Double(k)), margin: m) {
                return "control-surface travel (\(what))"
            }
        }
        for k in 0...n {
            let p = a + (b - a) * (Double(k) / Double(n))
            let along = L * Double(k) / Double(n)
            let nearEnd = along < Self.bossLength + 3 || along > L - Self.bossLength - 3
            if propGap(p) < Self.propClearance + r { return "prop" }
            for o in obstacles {
                let q = simd_clamp(p, o.lo, o.hi)
                if simd_distance(p, q) < need { return "hardware box \(o.name)" }
            }
            for cp in capsules where Self.distance(p, segment: cp.a, cp.b) < cp.r + need - 1 { return "linkage \(cp.name)" }
            if !nearEnd && insideFoam(p, margin: r + 0.5) { return "foam" }
            for o in others where Self.distance(p, segment: o.a.rodEnd, o.b.rodEnd) < r + o.diameter / 2 + 1.5 && !nearEnd { return "other strut" }
        }
        return nil
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
    func finStruts(avoiding existing: [Strut], tally: ((String) -> Void)? = nil) -> [Strut] {
        guard !c.kind.isTailless, !c.kind.isTwinBoom else { return [] }
        guard let st = stabiliser else { tally?("no stabiliser"); return [] }
        let stab = d.parts[st.part], inst = stab.instances[st.inst]
        // Only the fin rods' own buckling counts here (the wing / tail set was chosen before).
        let alreadyBuckles = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed, struts: combineBottomMounts(existing), bucklingSafety: Self.planBuckling).strutsBuckle
        // Fixed stabiliser chord at span station x: the outline interval that ends at (or behind) the hinge.
        func stabLE(_ x: Double) -> Double? {
            let v = simd_dot(SIMD3(x, inst.origin.y, 0) - inst.origin, inst.v)
            let zs = Self.crossings(stab.outline, atV: v).map { inst.origin.z + inst.u.z * $0 }.sorted()
            return zs.last { $0 < st.hingeZ - 15 }
        }
        for fx in [0.55, 0.45, 0.65, 0.35, 0.75, 0.25] {
            let x = fx * st.halfSpan
            guard let le = stabLE(x) else { tally?("no stab chord"); continue }
            for fz in [0.5, 0.35, 0.65, 0.2, 0.8, 0.9] {
                let zs = le + 6 + fz * (st.hingeZ - 12 - le)
                guard zs < st.hingeZ - 8 else { tally?("stab station behind hinge"); continue }
                for dz in [0.0, -10, 10, -20, 20] {
                    let zf = zs + dz
                    guard zf < st.hingeZ - 8, let top = webEdge(z: zf, top: true) else { tally?("no fin at station"); continue }
                    let root = t / 2
                    guard top - root > 30 else { tally?("fin too low"); continue }
                    for fh in [0.6, 0.5, 0.7, 0.4] {
                        let yf = root + fh * (top - root)
                        for dia in CarbonSpar.strutDiameters {
                            var pair: [Strut] = []
                            for side in [1.0, -1.0] {
                                guard let a = flatSite(part: st.part, inst: st.inst, x: side * x, z: zs) else { tally?("no stab site"); break }
                                guard let b = webSite(z: zf, y: yf, side: side) else { tally?("no fin site"); break }
                                guard let s = strut("Fin strut", .fin, wing: a, body: b, dia: dia) else { tally?("pad does not fit"); break }
                                pair.append(s)
                            }
                            guard pair.count == 2 else { continue }
                            guard isClear(pair[0], others: existing + [pair[1]]), isClear(pair[1], others: existing + [pair[0]]) else { tally?("not clear"); continue }
                            let rep = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed, struts: combineBottomMounts(existing + pair), bucklingSafety: Self.planBuckling)
                            if !rep.strutsBuckle || alreadyBuckles { return pair }
                            tally?("buckles")
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
    func wingStruts(avoiding existing: [Strut], tally: ((String) -> Void)? = nil) -> [Strut] {
        let s = c.semiSpan
        var fallback: (score: Double, struts: [Strut])?
        let rootClear = max(c.kind.hasFuselage ? c.fuselagePlateWidth / 2 : 0, c.isDual ? c.dualMotorX + c.propRadius + 8 : 0) + 30
        // Spots on the wing underside: first right beside the wing ends of tail struts already placed under the wing
        // (both rods then share one printed anchor), then the usual grid (mid span, spar line first).
        var spots: [(x: Double, z: Double)] = []
        for st in existing where st.a.normal.y < 0 && st.a.surface.x > 0 {
            for dz in [-11.0, 11, -14, 14, -18, 18] { spots.append((st.a.surface.x, st.a.surface.z + dz)) }
        }
        for f in [0.55, 0.45, 0.65, 0.38, 0.72] {
            let x = f * s
            guard x > rootClear, x < s - 25, let ch = wingChord(atX: x) else { tally?("span station unusable (x \(Int(x)), root clear \(Int(rootClear)))"); continue }
            for q in [0.3, 0.38, 0.22, 0.46, 0.55, 0.15] { spots.append((x, ch.le + q * (ch.te - ch.le))) }
        }
        for (x, z) in spots {
            do {
                for dz in [0.0, -14, 14, 28, -28, 42, -42] {
                    let zb = z + dz
                    var fitted = false
                    for dia in CarbonSpar.strutDiameters {
                        // Wing struts always run UNDER the wing (wing underside → bottom edge of the fuselage / keel /
                        // pod): in tension under positive g, in compression only when flying inverted / negative g.
                        var lower: [Strut] = []
                        for side in [1.0, -1.0] {
                            guard let bottom = webEdge(z: zb, top: false) else { tally?("no fuselage / keel below the wing"); break }
                            guard bottom < -(t / 2 + 14) else { tally?("side face too shallow (\(Int(-bottom)) mm)"); break }
                            if let w = wingSite(x: side * x, z: z, top: false) {
                                for inset in [7.0, 11, 15] {
                                    if let b = webSite(z: zb, y: bottom + inset, side: side),
                                       let st = strut("Wing strut", .wing, wing: w, body: b, dia: dia) { lower.append(st); break }
                                }
                            }
                        }
                        var lowerOK = lower.count == 2 && lower.allSatisfy { isClear($0, others: existing) }
                        if lower.count < 2 { tally?("pad / site does not fit") }
                        else if !lowerOK, let t = tally { t(lower.compactMap { blocker($0, others: existing) }.first ?? "?") }
                        // Side face taken (battery travel, servos …) or too small: the bosses on a printed foot under
                        // the bottom edge – the rods then stay below the fuselage.
                        if !lowerOK {
                            var foot: [Strut] = []
                            for side in [1.0, -1.0] {
                                guard let w = wingSite(x: side * x, z: z, top: false), let b = footSite(z: zb, side: side, dia: dia),
                                      let st = strut("Wing strut", .wing, wing: w, body: b, dia: dia) else { break }
                                foot.append(st)
                            }
                            if foot.count == 2 && foot.allSatisfy({ isClear($0, others: existing) })
                                && combineBottomMounts(existing + foot).suffix(2).allSatisfy({ $0.b.saddle != nil }) {
                                lower = foot; lowerOK = true
                            } else if foot.count == 2, let t = tally {
                                t("foot: " + (foot.compactMap { blocker($0, others: existing) }.first ?? "saddle blocked"))
                            } else { tally?("foot: no site") }
                        }
                        var sets: [[Strut]] = []
                        if lowerOK { sets.append(lower) }
                        guard !sets.isEmpty else { break }   // a thicker rod will not fit where a thin one does not
                        fitted = true
                        for raw in sets {
                            // As built: the bottom ends may share a saddle (also with the tail struts already placed).
                            let all = combineBottomMounts(existing + raw)
                            let set = Array(all.suffix(raw.count))
                            let rep = StructureReport(c, totalMass: totalMass + set.reduce(0) { $0 + $1.rodMass + 0.3 }, stallSpeed: stallSpeed, struts: all, bucklingSafety: Self.planBuckling)
                            let pct = rep.wingDeflectionRatio * 100
                            if pct < StructureReport.wingWarnPct && !rep.strutsBuckle { return set }
                            tally?(rep.strutsBuckle ? "set buckles" : "set too soft (\(Int(pct.rounded())) %)")
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
    func tailStruts(tally: ((String) -> Void)? = nil) -> [Strut] {
        let s = c.semiSpan
        var fallback: (score: Double, struts: [Strut])?
        let rootClear = max(c.fuselagePlateWidth / 2, c.isDual ? c.dualMotorX + c.propRadius + 8 : 0) + 25
        let rc = c.rootChord
        // Boom stations aft of the wing (aft-most first), where the webs are deep enough for an anchor.
        let tailEnd = c.tailArm + c.hStabChord
        var upperZ: [Double] = [], lowerZ: [Double] = []
        var z = tailEnd
        while z > rc + 8 {
            // Upper ends may also sit further forward where the fuselage is still taller than the boom: there they
            // land above the elevator / rudder pushrods that run along the boom sides.
            if let top = webEdge(z: z, top: true), top < t / 2 + c.boomTopHeight + 16, top > t / 2 + 11 { upperZ.append(z) }
            if let bot = webEdge(z: z, top: false), bot < -(t / 2 + 11) { lowerZ.append(z) }
            z -= 8
        }
        func thin(_ zs: [Double]) -> [Double] { zs.count <= 14 ? zs : stride(from: 0, to: zs.count, by: max(1, zs.count / 14)).map { zs[$0] } }
        upperZ = thin(upperZ); lowerZ = thin(lowerZ)
        // Span stations: mid span first; then right next to the root clearance, where a rod clears full-span ailerons
        // (it crosses the hinge line low and is inboard of the aileron before it rises / drops further).
        for x in [0.4, 0.5, 0.32, 0.6, 0.25].map({ $0 * s }) + [rootClear + 2, rootClear + 10] {
            guard x > rootClear, x < s - 25, let ch = wingChord(atX: x) else { tally?("span station x \(Int(x)) unusable (root clear \(Int(rootClear)))"); continue }
            // Forward chord stations last: they give the rod room to drop clear of the aileron's travel behind the hinge.
            for q in [0.6, 0.52, 0.68, 0.44, 0.36, 0.3, 0.22, 0.15] {
                let zw = ch.le + q * (ch.te - ch.le)
                // A spot that blocks a thin rod also blocks a thicker one (bigger rod and boss): skip it then.
                var blockedSpots = Set<String>()
                for dia in CarbonSpar.strutDiameters {
                    func pick(_ zs: [Double], top: Bool, name: String, others: [Strut]) -> [Strut] {
                        for zt in zs {
                            guard let edge = webEdge(z: zt, top: top) else { tally?("no boom edge"); continue }
                            // Boom-end height: nearest the edge first, deeper ones below / above a pushrod along the
                            // boom. A mirrored left + right pair that is clear wins.
                            var fitted = false
                            for inset in [7.0, 9, 11, 13, 16, 20, 25] {
                                let spot = "\(top)-\(zt)-\(inset)"
                                if blockedSpots.contains(spot) { fitted = true; continue }
                                var pair: [Strut] = []
                                for side in [1.0, -1.0] {
                                    guard let w = wingSite(x: side * x, z: zw, top: top),
                                          let b = webSite(z: zt, y: top ? edge - inset : edge + inset, side: side),
                                          let st = strut(name, .tail, wing: w, body: b, dia: dia) else { break }
                                    pair.append(st)
                                }
                                guard pair.count == 2 else { continue }
                                fitted = true
                                if pair.allSatisfy({ isClear($0, others: others) }) { return pair }
                                if others.isEmpty { blockedSpots.insert(spot) }
                                if let t = tally { t("\(top ? "upper" : "lower"): " + (pair.compactMap { blocker($0, others: others) }.first ?? "?")) }
                            }
                            if !fitted { tally?("\(top ? "upper" : "lower"): pad / site does not fit") }
                        }
                        return []
                    }
                    // Sport Jet: tail struts only underneath (above the boom sits the prop slot).
                    let upper = c.kind.isJet ? [] : pick(upperZ, top: true, name: "Tail strut above", others: [])
                    let lower = pick(lowerZ, top: false, name: "Tail strut below", others: upper)
                    var sets: [[Strut]] = []
                    if lower.count == 2 { sets.append(lower) }
                    if upper.count == 2 { sets.append(upper) }
                    if upper.count == 2 && lower.count == 2 { sets.append(upper + lower) }
                    if upperZ.isEmpty { tally?("no upper boom stations") }
                    if lowerZ.isEmpty { tally?("no lower boom stations") }
                    guard !sets.isEmpty else { break }
                    for raw in sets {
                        // Judge the set as built: bottom ends that share a saddle are stiffer (and load the rods more).
                        let set = combineBottomMounts(raw)
                        let rep = StructureReport(c, totalMass: totalMass + set.reduce(0) { $0 + $1.rodMass + 0.3 }, stallSpeed: stallSpeed, struts: set, bucklingSafety: Self.planBuckling)
                        let tw = rep.tailTwistDeg ?? 0, bd = rep.tailBendDeg ?? 0
                        // 10 % margin: wing and fin struts added afterwards raise the weight (and load speed) a little.
                        if tw < 0.9 * StructureReport.twistWarnDeg && bd < 0.9 * StructureReport.bendWarnDeg && !rep.strutsBuckle { return set }
                        tally?(rep.strutsBuckle ? "set buckles" : "set too soft (twist \(String(format: "%.1f", tw))°, bend \(String(format: "%.2f", bd))°)")
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
