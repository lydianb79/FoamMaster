import Foundation
import AppKit
import MetalKit
import SwiftUI

/// `FoamMaster --selftest <outdir>`: builds every model type, prints the analysis and writes PDFs/STLs.
enum SelfTest {
    /// Carbon struts: soft builds (EPP 6 mm) with struts off / auto, every type with struts always.
    /// Independent control-surface check: every moving surface (ailerons, elevons, elevator, rudder) is swept in 1°
    /// steps through the type's max throw about its hinge, its outline (0.5 mm) and faces (1 mm grid) on both sides, plus its
    /// horn tip; the smallest gap to every strut rod, anchor pad and anchor boss is returned with the throw at which
    /// the surface would first touch (nil = free over the whole range).
    struct SweepResult { var surface: String; var strut: String; var gap: Double; var hitAt: Double?; var solid = "" }
    static func surfaceSweep(_ d: Design) -> [SweepResult] {
        let maxThrow = d.config.kind.maxSurfaceThrow
        guard !d.struts.isEmpty else { return [] }
        // Strut solids: rod cylinder, boss (capsule over the square section), pad box.
        func rodGap(_ p: SIMD3<Double>, _ s: Strut) -> Double { StrutPlanner.distance(p, segment: s.a.rodEnd, s.b.rodEnd) - s.diameter / 2 }
        func bossGap(_ p: SIMD3<Double>, _ e: StrutAnchor, _ towards: SIMD3<Double>, _ dia: Double) -> Double {
            let dir = simd_normalize(towards - e.rodEnd)
            return StrutPlanner.distance(p, segment: e.rodEnd, e.rodEnd + dir * StrutPlanner.bossLength) - StrutPlanner.bossSide(dia) / 2 * 2.squareRoot()
        }
        func padGap(_ p: SIMD3<Double>, _ e: StrutAnchor) -> Double {
            let side = simd_normalize(simd_cross(e.normal, e.along))
            let q = p - e.surface
            let x = abs(simd_dot(q, e.along)) - e.padSize.x / 2, y = abs(simd_dot(q, side)) - e.padSize.y / 2
            let zn = simd_dot(q, e.normal), z = zn < 0 ? -zn : max(0, zn - StrutPlanner.padThickness)
            return simd_length(SIMD3(max(x, 0), max(y, 0), z))
        }
        func gap(_ p: SIMD3<Double>, _ s: Strut) -> Double {
            min(rodGap(p, s), bossGap(p, s.a, s.b.rodEnd, s.diameter), bossGap(p, s.b, s.a.rodEnd, s.diameter), padGap(p, s.a), padGap(p, s.b))
        }
        var out: [SweepResult] = []
        for part in d.parts {
            for r in part.regions where r.isControl {
                guard let axis = SceneBuilder.hingeAxis(part, r.polygon) else { continue }
                var pts: [Vec2] = []
                for i in 0..<r.polygon.count {
                    let a = r.polygon[i], b = r.polygon[(i + 1) % r.polygon.count]
                    let n = max(1, Int(simd_distance(a, b) / 0.5))
                    for k in 0..<n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
                }
                let bb = Poly.bounds(r.polygon)
                var u = bb.min.x
                while u <= bb.max.x { var v = bb.min.y; while v <= bb.max.y { if Poly.contains(r.polygon, Vec2(u, v)) { pts.append(Vec2(u, v)) }; v += 1 }; u += 1 }
                for (ii, inst) in part.instances.enumerated() {
                    let a3 = inst.point(axis.0), b3 = inst.point(axis.1), ax = simd_normalize(b3 - a3)
                    let base = pts.flatMap { p in [-part.thickness / 2, part.thickness / 2].map { inst.point(p, offset: $0) } }
                    // Horn tips on this surface (the horn turns with it).
                    let mid = (a3 + b3) / 2
                    let horns = d.controls.filter { simd_distance($0.hornPosition, mid) < simd_distance(a3, b3) / 2 + 30 }
                        .map { [$0.hornPosition, $0.hornPosition - $0.hornAxis * 12] }.flatMap { $0 }
                    let surfName = part.instances.count > 1 ? "\(part.name) #\(ii + 1)" : part.name
                    // A point's arc stays within 2·r·sin(maxThrow/2) of its neutral position (r = distance to the hinge),
                    // so only points that could come within 20 mm of a strut are swept.
                    let reach = 2 * sin(maxThrow / 2 * .pi / 180)
                    let radius = { (p: SIMD3<Double>) in StrutPlanner.distance(p, segment: a3 - ax * 1e4, a3 + ax * 1e4) }
                    for s in d.struts {
                        let near = (base + horns).filter { gap($0, s) - reach * radius($0) < 20 }
                        var minGap = (base + horns).map { gap($0, s) }.min() ?? .greatestFiniteMagnitude
                        if near.isEmpty { out.append(SweepResult(surface: surfName, strut: s.label, gap: minGap, hitAt: nil)); continue }
                        var hit: Double?, solid = ""
                        // From neutral outwards in both directions, so hitAt is the first contact.
                        for sign in [1.0, -1.0] {
                            for deg in stride(from: 0.0, through: maxThrow, by: 1) {
                                let q = simd_quatd(angle: sign * deg * .pi / 180, axis: ax)
                                var g = Double.greatestFiniteMagnitude
                                for p in near { g = min(g, gap(q.act(p - a3) + a3, s)) }
                                minGap = min(minGap, g)
                                if g < 0 {
                                    hit = min(hit ?? .greatestFiniteMagnitude, deg)
                                    let ps = near.map { q.act($0 - a3) + a3 }
                                    let parts: [(String, Double)] = [("rod", ps.map { rodGap($0, s) }.min()!), ("wing boss", ps.map { bossGap($0, s.a, s.b.rodEnd, s.diameter) }.min()!),
                                        ("body boss", ps.map { bossGap($0, s.b, s.a.rodEnd, s.diameter) }.min()!), ("wing pad", ps.map { padGap($0, s.a) }.min()!), ("body pad", ps.map { padGap($0, s.b) }.min()!)]
                                    solid = parts.min { $0.1 < $1.1 }!.0
                                    break
                                }
                            }
                        }
                        out.append(SweepResult(surface: surfName, strut: s.label, gap: minGap, hitAt: hit, solid: solid))
                    }
                }
            }
        }
        return out
    }

    /// Why a configuration gets no tail struts: the user's Park Trainer and close variants, with a rejection tally.
    /// Why a configuration gets no tail struts, and how long the build takes: the Park Trainer with one central
    /// aileron servo (full-span ailerons, pushrods along both boom sides) and close variants.
    /// Horn clearance: every moving surface swept through its full throw (1° steps) against the printed horns of
    /// the OTHER surfaces – each horn placed as in the 3D view and itself swung with its own surface (every 5°).
    /// Returns the smallest gap per (surface, horn) and the surface angle of the first contact.
    struct HornGap { var surface: String; var horn: String; var gap: Double; var hitAt: Double? }
    static func hornClearance(_ d: Design) -> [HornGap] {
        let c = d.config, t = c.material.thickness, T = c.kind.maxSurfaceThrow
        // Moving surfaces: sample points (outline every 0.5 mm, faces on a 1 mm grid) and hinge axis, per instance.
        struct Surf { var name: String; var pts: [SIMD3<Double>]; var a: SIMD3<Double>; var ax: SIMD3<Double>; var mid: SIMD3<Double>; var b: SIMD3<Double> = .zero }
        var surfs: [Surf] = []
        for part in d.parts {
            for r in part.regions where r.isControl {
                guard let axis = SceneBuilder.hingeAxis(part, r.polygon) else { continue }
                var flat: [Vec2] = []
                for i in r.polygon.indices {
                    let p0 = r.polygon[i], p1 = r.polygon[(i + 1) % r.polygon.count]
                    let n = max(1, Int(simd_distance(p0, p1) / 0.5))
                    for k in 0..<n { flat.append(p0 + (p1 - p0) * (Double(k) / Double(n))) }
                }
                let bb = Poly.bounds(r.polygon)
                var u = bb.min.x
                while u <= bb.max.x { var v = bb.min.y; while v <= bb.max.y { if Poly.contains(r.polygon, Vec2(u, v)) { flat.append(Vec2(u, v)) }; v += 1 }; u += 1 }
                for (ii, inst) in part.instances.enumerated() {
                    let a3 = inst.point(axis.0), b3 = inst.point(axis.1)
                    surfs.append(Surf(name: part.instances.count > 1 ? "\(part.name) #\(ii + 1)" : part.name,
                                      pts: flat.flatMap { p in [-part.thickness / 2, part.thickness / 2].map { inst.point(p, offset: $0) } },
                                      a: a3, ax: simd_normalize(b3 - a3), mid: (a3 + b3) / 2, b: b3))
                }
            }
        }
        // Horns: same mesh and placement as the 3D view, sampled on their triangles; each belongs to the surface whose
        // hinge passes closest to it.
        var out: [HornGap] = []
        for ctrl in d.controls {
            let a = simd_normalize(ctrl.hornAxis)
            let ex = SIMD3<Double>(0, 0, 1), ey = simd_cross(a, ex)
            let origin = ctrl.hornPosition - a * 9 + [0, 0, 4]
            let mesh = PrintedParts.controlHorn(foam: t).transformed { p in origin + ex * p.x + ey * p.y + a * p.z }
            var hp: [SIMD3<Double>] = []
            for tri in mesh.triangles {
                for i in 0...4 { for j in 0...(4 - i) {
                    let u = Double(i) / 4, v = Double(j) / 4
                    hp.append(tri.0 + (tri.1 - tri.0) * u + (tri.2 - tri.0) * v)
                } }
            }
            // Own surface: the hinge SEGMENT nearest the horn (aileron hinges of both sides lie on one line).
            func segDist(_ p: SIMD3<Double>, _ s: Surf) -> Double { StrutPlanner.distance(p, segment: s.a, s.b) }
            guard let own = surfs.min(by: { segDist(ctrl.hornPosition, $0) < segDist(ctrl.hornPosition, $1) }) else { continue }
            for s in surfs where simd_distance(s.mid, own.mid) > 1 {
                var minGap = Double.greatestFiniteMagnitude, hit: Double?
                // Cylindrical coordinates about this surface's hinge: a point keeps its axial position and radius while
                // the surface turns, so only points whose (axial, radius) lie within the horn's range can ever reach it.
                func cyl(_ p: SIMD3<Double>) -> (s: Double, r: Double) {
                    let q = p - s.a, ax = simd_dot(q, s.ax); return (ax, simd_length(q - s.ax * ax))
                }
                let hornsAt = stride(from: -T, through: T, by: 5).map { eAng -> [SIMD3<Double>] in
                    let qe = simd_quatd(angle: eAng * .pi / 180, axis: own.ax); return hp.map { qe.act($0 - own.a) + own.a } }
                let hc = hornsAt.flatMap { $0 }.map(cyl)
                guard let s0 = hc.map(\.s).min(), let s1 = hc.map(\.s).max(), let r0 = hc.map(\.r).min(), let r1 = hc.map(\.r).max() else { continue }
                let reach = 6.0
                let near = s.pts.filter { let k = cyl($0); return k.s > s0 - reach && k.s < s1 + reach && k.r > r0 - reach && k.r < r1 + reach }
                if near.isEmpty { out.append(HornGap(surface: s.name, horn: ctrl.name + " horn", gap: reach, hitAt: nil)); continue }
                // Horn samples in 3 mm cells per horn angle: each turned surface point looks at its 27 neighbour cells
                // only (gaps beyond ~3 mm are reported as 3 mm).
                let cell = 3.0
                func key(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>((p / cell).rounded(.down)) }
                let grids = hornsAt.map { horn -> [SIMD3<Int32>: [SIMD3<Double>]] in
                    var g: [SIMD3<Int32>: [SIMD3<Double>]] = [:]; for h in horn { g[key(h), default: []].append(h) }; return g }
                minGap = cell
                for grid in grids {
                    for sign in [1.0, -1.0] {
                        for deg in stride(from: 0.0, through: T, by: 1) {
                            let q = simd_quatd(angle: sign * deg * .pi / 180, axis: s.ax)
                            var g = cell
                            for p in near {
                                let w = q.act(p - s.a) + s.a, k = key(w)
                                for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
                                    for h in grid[k &+ SIMD3(dx, dy, dz)] ?? [] { g = min(g, simd_distance(w, h)) }
                                } } }
                            }
                            minGap = min(minGap, g)
                            if g < 0.3 { hit = min(hit ?? 999, sign * deg); break }
                        }
                    }
                }
                out.append(HornGap(surface: s.name, horn: ctrl.name + " horn", gap: minGap, hitAt: hit))
            }
        }
        return out
    }

    /// Elevator against the fin / rudder above it: elevator points (outline 0.5 mm, faces 1 mm) swung through the full
    /// throw (+5°) in 1° steps must stay out of the upper web (fixed fin + rudder) wherever the rudder can swing over
    /// them. Returns the deepest intrusion (mm, 0 = clear) and the elevator angle where it starts.
    nonisolated(unsafe) static var lastIntrusion = ""
    static func elevatorUnderFin(_ d: Design) -> (depth: Double, at: Double?) {
        let c = d.config
        guard c.hasRudder, !c.kind.isTwinBoom else { return (0, nil) }
        let T = c.kind.maxSurfaceThrow + StrutPlanner.throwMargin
        // Upper web carrying the rudder (vertical instance), and the elevator region (horizontal part).
        guard let webIdx = d.parts.firstIndex(where: { p in p.regions.contains { $0.isControl } && p.instances.allSatisfy { abs($0.normal.x) > 0.9 } }) else { return (0, nil) }
        let web = d.parts[webIdx], wi = web.instances[0]
        let tw = web.thickness * Double(web.instances.count)
        guard let rud = web.regions.first(where: \.isControl) else { return (0, nil) }
        let rudB = Poly.bounds(rud.polygon)
        let reach = (rudB.max.x - rudB.min.x) * sin(T * .pi / 180) + tw / 2
        var deepest = 0.0, at: Double?
        for part in d.parts where part.instances.allSatisfy({ abs($0.normal.y) > 0.9 }) {
            for r in part.regions where r.isControl {
                guard let axis = SceneBuilder.hingeAxis(part, r.polygon) else { continue }
                var flat: [Vec2] = []
                for i in r.polygon.indices {
                    let p0 = r.polygon[i], p1 = r.polygon[(i + 1) % r.polygon.count]
                    let n = max(1, Int(simd_distance(p0, p1) / 0.5)); for k in 0..<n { flat.append(p0 + (p1 - p0) * (Double(k) / Double(n))) }
                }
                let bb = Poly.bounds(r.polygon); var u = bb.min.x
                while u <= bb.max.x { var v = bb.min.y; while v <= bb.max.y { if Poly.contains(r.polygon, Vec2(u, v)) { flat.append(Vec2(u, v)) }; v += 1 }; u += 1 }
                for inst in part.instances {
                    // Tape hinge on top: the elevator turns about its top-surface line.
                    let up = inst.normal.y > 0 ? inst.normal : -inst.normal
                    let a3 = inst.point(axis.0) + up * part.thickness / 2, ax = simd_normalize(inst.point(axis.1) - inst.point(axis.0))
                    let pts = flat.flatMap { p in [-part.thickness / 2, part.thickness / 2].map { inst.point(p, offset: $0) } }.filter { abs($0.x) < reach }
                    guard !pts.isEmpty else { continue }
                    for sign in [1.0, -1.0] {
                        for deg in stride(from: 0.0, through: T, by: 1) {
                            let q = simd_quatd(angle: sign * deg * .pi / 180, axis: ax)
                            var depth = 0.0
                            for p in pts {
                                let w = q.act(p - a3) + a3
                                let pp = Vec2((w.z - wi.origin.z) / wi.u.z, (w.y - wi.origin.y) / wi.v.y)
                                guard Poly.contains(web.outline, pp) else { continue }
                                // Depth: distance into the web outline (vertical, from its bottom edge).
                                var dy = 0.0
                                while dy < 30 && Poly.contains(web.outline, pp - Vec2(0, dy)) { dy += 0.25 }
                                if dy > depth { lastIntrusion = String(format: "pt rest (x %.1f, y %.2f, dz %.2f) → web (u−uH… %.2f, v %.2f) at %.0f°", p.x, p.y, p.z - a3.z, w.z - a3.z, pp.y, sign * deg) }
                                depth = max(depth, dy)
                            }
                            if depth > 0.25 { if at == nil || abs(sign * deg) < abs(at!) { at = sign * deg }; deepest = max(deepest, depth) }
                        }
                    }
                }
            }
        }
        return (deepest, at)
    }

    @MainActor static func hornCheck() {
        var total = 0, bad: [String] = [], closest: [String: Double] = [:]
        for kind in AircraftKind.allCases {
            var configs: [AircraftConfig] = [kind.defaults]
            for m in FoamMaterial.allCases { var c = kind.defaults; c.material = m; configs.append(c) }
            for _ in 0..<10 { configs.append(AircraftConfig.random(kind: kind)) }
            for c0 in configs {
                let c = Project.balanced(c0)
                let d = DesignBuilder.build(c)
                total += 1
                let ef = elevatorUnderFin(d)
                if ef.depth > 0.25 { bad.append("\(kind.rawValue) \(c.material.rawValue): elevator into fin / rudder \(String(format: "%.1f", ef.depth)) mm from \(Int(ef.at ?? 0))° [\(lastIntrusion)]") }
                for g in hornClearance(d) {
                    closest[kind.rawValue] = min(closest[kind.rawValue] ?? 999, g.gap)
                    if g.hitAt != nil || g.gap < 1 {
                        bad.append("\(kind.rawValue) \(c.material.rawValue) span \(Int(c.wingspan)) fin chord \(Int(c.vStabChord)) stab chord \(Int(c.hStabChord)): \(g.surface) vs \(g.horn) gap \(String(format: "%.1f", g.gap)) mm\(g.hitAt.map { " – HIT at \(Int($0))°" } ?? "")")
                    }
                }
            }
        }
        for kind in AircraftKind.allCases {
            let d = DesignBuilder.build(Project.balanced(kind.defaults))
            let slots = d.parts.flatMap { p in p.holes.filter { $0.note == "pushrod" }.map { _ in p.name } }
            let under = d.parts.contains { $0.holes.contains { $0.note == "horn under" } }
            print("  \(kind.title): elevator horn \(under ? "under" : "on top"), pushrod slots: \(slots.isEmpty ? "none" : slots.joined(separator: ", "))")
        }
        print("horn check: \(total) builds, \(bad.count) collisions / < 1 mm")
        var pairs: [String: Int] = [:]
        for b in bad { if let r = b.range(of: ": ") { let rest = b[r.upperBound...]; pairs[b.split(separator: " ")[0] + " " + String(rest.prefix { $0 != "g" || !rest.contains(" gap") }).components(separatedBy: " gap")[0], default: 0] += 1 } }
        for (k, v) in pairs.sorted(by: { $0.value > $1.value }) { print("  \(v)× \(k)") }
        for (k, v) in closest.sorted(by: { $0.key < $1.key }) { print("  closest \(k): \(String(format: "%.1f", v)) mm") }
        for b in bad { print("  · " + b) }
    }

    /// Scan: random variants of every type in every foam (struts on Auto). Lists builds that still fail a
    /// stiffness check (wing / fuselage twist / boom bending), with what blocked the strut candidates.
    @MainActor static func strutScan(count: Int = 12) {
        var failing = 0, total = 0, strutted = 0
        var reasons: [String: Int] = [:]
        var examples: [String] = []
        let stiffness: Set<String> = ["Wing far too flexible", "Fuselage twists too much", "Tail boom bends too much"]
        for kind in AircraftKind.allCases {
            for m in FoamMaterial.allCases {
                for _ in 0..<count {
                    var c = AircraftConfig.random(kind: kind)
                    c.material = m; c.struts = .auto
                    c = Project.balanced(c)
                    let d = DesignBuilder.build(c), a = Analysis(design: d)
                    total += 1
                    if !d.struts.isEmpty { strutted += 1 }
                    let errs = a.checks.filter { $0.severity == .error && stiffness.contains($0.title) }.map(\.title)
                    guard !errs.isEmpty else { continue }
                    failing += 1
                    var why: [String: Int] = [:]
                    var off = c; off.struts = .off
                    let p = StrutPlanner(design: DesignBuilder.build(off), totalMass: a.totalMass, stallSpeed: a.stallSpeed)
                    if errs.contains(where: { $0 != "Wing far too flexible" }) { _ = p.tailStruts(tally: { why["tail: " + $0, default: 0] += 1 }) }
                    if errs.contains("Wing far too flexible") { _ = p.wingStruts(avoiding: [], tally: { why["wing: " + $0, default: 0] += 1 }) }
                    let top = why.max { $0.value < $1.value }?.key ?? (kind.isTwinBoom ? "twin boom (no tail struts)" : "no candidates tried")
                    reasons["\(kind.rawValue) \(errs.map { $0.split(separator: " ").first! }.joined(separator: "+")) – \(top)", default: 0] += 1
                    if examples.count < 30 {
                        examples.append("\(kind.rawValue) \(m.rawValue) span \(Int(c.wingspan)) fus \(c.fuselageType.name) ail \(c.hasAilerons ? c.aileronServos : 0) rudder \(c.hasRudder) dual \(c.isDual): \(errs.joined(separator: ", ")); struts \(d.struts.count); top blocker: \(top)")
                    }
                }
            }
        }
        print("scan: \(total) builds, \(strutted) with struts, \(failing) still fail a stiffness check")
        for (k, v) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(v)× \(k)") }
        for e in examples { print("  · " + e) }
    }

    @MainActor static func strutDiagnosis() {
        for m in [FoamMaterial.depron3, .depron5, .epp3, .epp5] {
            for ail in [1, 2] {
                var c = AircraftKind.trainer.defaults
                c.material = m; c.motor = .m1103; c.battery = .s1_300; c.aileronServos = ail; c.struts = .auto
                c = Project.balanced(c)
                let t0 = Date()
                let d = DesignBuilder.build(c)
                let ms = Date().timeIntervalSince(t0) * 1000
                let a = Analysis(design: d)
                let loads = Analysis.massAndStall(d)
                let rep = StructureReport(c, totalMass: loads.mass, stallSpeed: loads.stall)
                var why: [String: Int] = [:]
                let p = StrutPlanner(design: DesignBuilder.build({ var k = c; k.struts = .off; return k }()), totalMass: loads.mass, stallSpeed: loads.stall)
                let tail = p.tailStruts(tally: { why[$0, default: 0] += 1 })
                print("== trainer \(m.displayName) ail servos \(ail): build \(Int(ms)) ms, struts \(d.struts.count), twist bare \(String(format: "%.1f", rep.tailTwistDeg ?? 0))° → \(String(format: "%.1f", a.structure?.tailTwistDeg ?? 0))°, feasible \(a.feasible), tail candidates found \(tail.count)")
                for (k, v) in why.sorted(by: { $0.value > $1.value }).prefix(4) { print("     \(v)× \(k)") }
            }
        }
    }

    @MainActor static func strutReport(_ dir: URL) {
        for kind in AircraftKind.allCases {
            for (mode, m) in [(StrutMode.off, FoamMaterial.epp6), (.auto, .epp6), (.always, kind.recommended.material)] {
                var c = kind.recommended; c.material = m; c.struts = mode
                c = Project.balanced(FixFinder.evaluate(c).config)
                let d = DesignBuilder.build(c); let a = Analysis(design: d)
                let st = a.structure!
                // Independent re-check of every rod: clear of everything (planner rules) and inside the airframe.
                let planner = StrutPlanner(design: d, totalMass: a.totalMass, stallSpeed: a.stallSpeed)
                let clear = d.struts.allSatisfy { s in planner.isClear(s, others: d.struts.filter { $0.label != s.label }) }
                let sym = d.struts.filter { $0.label.hasSuffix("R") }.allSatisfy { r in
                    d.struts.contains { l in l.label == String(r.label.dropLast()) + "L" && abs(l.a.rodEnd.x + r.a.rodEnd.x) < 0.01 && abs(l.length - r.length) < 0.01 } }
                print("   struts \(kind.title) \(m.displayName) \(mode.name): \(d.struts.count) (\(d.struts.map { "\($0.label) Ø\(String(format: "%.1f", $0.diameter)) \(Int($0.length)) mm \(Int(($0.a.elevation * 180 / .pi).rounded()))°/\(Int(($0.b.elevation * 180 / .pi).rounded()))°" }.joined(separator: ", "))), "
                      + "wing \(String(format: "%.1f", st.wingDeflectionRatio * 100)) %, twist \(st.tailTwistDeg.map { String(format: "%.1f", $0) } ?? "–")°, bend \(st.tailBendDeg.map { String(format: "%.2f", $0) } ?? "–")°, fin \(st.finFlexBareDeg.map { String(format: "%.1f", $0) } ?? "–")→\(st.finFlexDeg.map { String(format: "%.2f", $0) } ?? "–")°, "
                      + "saddles \(d.struts.filter { $0.b.saddle != nil }.count / 2) (feet \(d.struts.filter { $0.b.footDepth > 0 }.count / 2)), wing below \(d.struts.filter { $0.group == .wing }.allSatisfy { $0.b.rodEnd.y < $0.a.rodEnd.y }), tail below \(d.struts.filter { $0.group == .tail }.allSatisfy { $0.b.rodEnd.y < 0 }), doubles \(d.struts.filter { $0.a.shared != nil }.count / 2), max force \(String(format: "%.2f", st.maxStrutForce)) N, buckle \(st.strutsBuckle), clear \(clear), symmetric \(sym), prop gap \(String(format: "%.1f", a.propGap)) mm, AUW \(Int(a.totalMass)) g, feasible \(a.feasible)"
                      + a.checks.filter { $0.severity == .error }.map { " [\($0.title)]" }.joined())
                let sw = surfaceSweep(d)
                // Fin struts against the tail surfaces (elevator and rudder) in particular.
                let finLabels = Set(d.struts.filter { $0.group == .fin }.map(\.label))
                if !finLabels.isEmpty {
                    let fs = sw.filter { finLabels.contains($0.strut) }
                    let bySurface = Dictionary(grouping: fs, by: \.surface).map { k, v in "\(k) \(String(format: "%.1f", v.map(\.gap).min()!)) mm" }.sorted()
                    // Pushrods (servo arm tip → horn) and horns against the fin rods: closest approach, sampled every 0.5 mm.
                    var rodGap = Double.greatestFiniteMagnitude
                    for s in d.struts where s.group == .fin {
                        for ctrl in d.controls {
                            let a0 = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
                            for (p0, p1) in [(a0, ctrl.hornPosition), (ctrl.hornPosition, ctrl.hornPosition - ctrl.hornAxis * 12)] {
                                let n = max(1, Int(simd_distance(p0, p1) / 0.5))
                                for k in 0...n {
                                    let p = p0 + (p1 - p0) * (Double(k) / Double(n))
                                    rodGap = min(rodGap, StrutPlanner.distance(p, segment: s.a.rodEnd, s.b.rodEnd) - s.diameter / 2 - 0.5)
                                }
                            }
                        }
                    }
                    print("      fin struts vs tail surfaces: \(bySurface.joined(separator: ", "))\(fs.contains { $0.hitAt != nil } ? " CONTACT" : ", all free"); pushrods/horns \(String(format: "%.1f", rodGap)) mm")
                } else if (kind.hasTail || kind.isNutBall) && !kind.isTwinBoom && !d.struts.isEmpty {
                    print("      fin struts: NONE FITTED \(d.strutNotes.joined()) bat \(String(format: "%.0f", a.requiredBatteryPosition)) limits \(String(format: "%.0f…%.0f", a.batteryLimits.lowerBound, a.batteryLimits.upperBound)) cg \(String(format: "%.1f…%.1f", a.cgRange.lowerBound, a.cgRange.upperBound))")
                    let loads = Analysis.massAndStall(d)
                    let fin = StrutPlanner.plan(d, totalMass: loads.mass, stallSpeed: loads.stall).filter { $0.group == .fin }
                    let anchors = fin.reduce(0.0) { m, s in m + [s.a, s.b].reduce(0.0) { $0 + PrintedParts.strutAnchor(dia: s.diameter, elevation: $1.elevation).volume * 1.24e-3 * 0.85 } }
                    print("        would be \(fin.count) rods \(String(format: "%.2f", fin.reduce(0) { $0 + $1.rodMass })) g + anchors \(String(format: "%.2f", anchors)) g at z \(fin.first.map { String(format: "%.0f", $0.b.rodEnd.z) } ?? "–")")
                }
                if let w = sw.min(by: { $0.gap < $1.gap }) {
                    let hits = sw.filter { $0.hitAt != nil }
                    print("      surface sweep ±\(Int(c.kind.maxSurfaceThrow))°: closest \(w.surface) ↔ \(w.strut) \(String(format: "%.1f", w.gap)) mm"
                          + (hits.isEmpty ? ", all free" : ", CONTACT: " + hits.map { "\($0.surface)↔\($0.strut) \($0.solid) at \(Int($0.hitAt!))°" }.joined(separator: ", ")))
                }
                if mode != .off && !d.struts.isEmpty && (kind == .trainer || kind == .jet || kind == .nutBall || kind == .flyingWing || kind == .aerobat) {
                    let tag = "struts_\(kind.rawValue)_\(mode.rawValue)"
                    try? PlanPDF.render(d, a).write(to: dir.appendingPathComponent("\(tag).pdf"))
                    for part in PrintedParts.generate(d) where part.fileName.hasPrefix("strut_") {
                        try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("\(tag)_\(part.fileName).stl"))
                    }
                    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                    if let r = Renderer(view: view) {
                        r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                        if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("\(tag)_3d.png")) }
                        // From below and behind, where most struts are.
                        r.pitch = -0.35; r.yaw = 2.3
                        if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("\(tag)_3d_below.png")) }
                        // Close-up of the first saddle from below and the side, and the saddle alone as printed.
                        if let sd = d.struts.compactMap({ $0.b.saddle }).first {
                            r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                            r.target = SIMD3<Float>(Float(sd.center.x), Float(sd.center.y), Float(sd.center.z))
                            r.zoom = 0.12; r.pitch = -0.45; r.yaw = 0.9
                            if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("\(tag)_3d_saddle.png")) }
                            if let part = PrintedParts.generate(d).first(where: { $0.fileName.hasPrefix("strut_saddle") }) {
                                var sc = SceneData()
                                sc.addMesh(part.mesh, color: Palette.printed)
                                r.setScene(sc, resetCamera: true)
                                r.pitch = 0.5; r.yaw = 0.6
                                if let img = r.snapshot(width: 800, height: 600) { savePNG(img, dir.appendingPathComponent("\(tag)_saddle_part.png")) }
                            }
                        }
                        // Tail close-up from behind and to the side (fin struts), like a photo of the real model.
                        if let fin = d.struts.first(where: { $0.group == .fin }) {
                            r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                            r.target = SIMD3<Float>(0, Float(fin.b.rodEnd.y) * 0.5, Float(fin.b.rodEnd.z))
                            r.zoom = 0.3; r.pitch = 0.18; r.yaw = 0.55
                            if let img = r.snapshot(width: 1000, height: 640) { savePNG(img, dir.appendingPathComponent("\(tag)_3d_tail.png")) }
                        }
                    }
                }
            }
        }
        // Default designs (as opened in the editor) in EPP 6 mm on Auto and Depron on Always: fin struts fitted?
        for kind in AircraftKind.allCases where (kind.hasTail || kind.isNutBall) && !kind.isTwinBoom {
            for (mode, m) in [(StrutMode.auto, FoamMaterial.epp6), (.always, kind.defaults.material)] {
                var c = kind.defaults; c.material = m; c.struts = mode
                c = Project.balanced(c)
                let d = DesignBuilder.build(c), a = Analysis(design: d)
                let fin = d.struts.filter { $0.group == .fin }
                print("   defaults fin \(kind.title) \(m.displayName) \(mode.name): \(d.struts.count) struts, \(d.struts.map { "\($0.label) Ø\(String(format: "%.1f", $0.diameter)) \(Int($0.length)) \(Int(($0.a.elevation * 180 / .pi).rounded()))°/\(Int(($0.b.elevation * 180 / .pi).rounded()))°" }.joined(separator: " ")) bend \(a.structure?.tailBendDeg.map { String(format: "%.2f", $0) } ?? "–") twist \(a.structure?.tailTwistDeg.map { String(format: "%.2f", $0) } ?? "–"), fin struts \(fin.count)\(fin.first.map { " Ø\(String(format: "%.1f", $0.diameter)) \(Int($0.length)) mm" } ?? ""), fin tilt \(a.structure?.finFlexBareDeg.map { String(format: "%.1f", $0) } ?? "–")→\(a.structure?.finFlexDeg.map { String(format: "%.2f", $0) } ?? "–")°, feasible \(a.feasible), score \(a.score)\(d.strutNotes.isEmpty ? "" : " [fin left out: CG]")" + a.checks.filter { $0.severity >= .warning }.map { " {\($0.title): \($0.detail)}" }.joined())
            }
        }
        // Why fin struts are missing where struts are fitted: rejection tally over every foam.
        for kind in AircraftKind.allCases where (kind.hasTail || kind.isNutBall) && !kind.isTwinBoom {
            for m in FoamMaterial.allCases {
                var c = kind.defaults; c.material = m; c.struts = .always
                c = Project.balanced(c)
                let d = DesignBuilder.build(c)
                guard !d.struts.isEmpty, !d.struts.contains(where: { $0.group == .fin }) else { continue }
                let loads = Analysis.massAndStall(d)
                var why: [String: Int] = [:]
                _ = StrutPlanner(design: d, totalMass: loads.mass, stallSpeed: loads.stall)
                    .finStruts(avoiding: d.struts, tally: { why[$0, default: 0] += 1 })
                print("   no fin struts \(kind.title) \(m.displayName): \(d.strutNotes.isEmpty ? "" : "[CG] ")\(why.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            }
        }
        // Propeller pitch: every prop (tractor or pusher, either hand) must throw air aft = thrust forward (−z).
        // Rotation sense: CCW about +z for the plain blade, CW for the mirrored one. Along the rotation the blade must
        // move towards −z (its trailing side lies aft): covariance of z with the angle in the rotation sense < 0.
        for (outward, mirrored, what) in [(-1.0, false, "tractor"), (-1.0, true, "tractor mirrored"), (1.0, true, "pusher"), (1.0, false, "pusher mirrored")] {
            let m = SceneBuilder.propeller(radius: 50, blades: 1, z: 0, hub: 4, outward: outward, mirrored: mirrored)
            let sense = mirrored ? -1.0 : 1.0
            var pts: [(ang: Double, z: Double)] = []
            for t in m.triangles { for p in [t.0, t.1, t.2] where simd_length(SIMD2(p.x, p.y)) > 20 {
                pts.append((atan2(p.y, p.x) * sense, p.z))
            } }
            // Angles of one blade stay within ±π/2 of its mean direction: unwrap around the mean.
            let mean = atan2(pts.map { sin($0.ang) }.reduce(0, +), pts.map { cos($0.ang) }.reduce(0, +))
            let un = pts.map { (ang: remainder($0.ang - mean, 2 * .pi), z: $0.z) }
            let ma = un.map(\.ang).reduce(0, +) / Double(un.count), mz = un.map(\.z).reduce(0, +) / Double(un.count)
            let cov = un.reduce(0) { $0 + ($1.ang - ma) * ($1.z - mz) }
            print("   prop pitch \(what): \(cov < 0 ? "forward thrust OK" : "THRUST BACKWARDS")")
        }
        // Warnings cleared on request: stiffness warnings on Auto, then the matching strut group switched On.
        let warnGroups: [(String, WritableKeyPath<AircraftConfig, StrutMode>)] = [("Wing flexes noticeably", \.wingStruts),
            ("Fuselage is soft in torsion", \.tailStruts), ("Tail boom flexes", \.tailStruts)]
        for kind in AircraftKind.allCases {
            for m in [kind.defaults.material, FoamMaterial.epp6, .depron3] {
                var c = kind.defaults; c.material = m; c.struts = .auto
                c = Project.balanced(c)
                let a = Analysis(design: DesignBuilder.build(c))
                let warns = a.checks.filter { $0.severity == .warning && warnGroups.map(\.0).contains($0.title) }.map(\.title)
                guard !warns.isEmpty else { continue }
                var on = c
                for (title, kp) in warnGroups where warns.contains(title) { on[keyPath: kp] = .always }
                on = Project.balanced(on)
                let d2 = DesignBuilder.build(on), a2 = Analysis(design: d2)
                let left = a2.checks.filter { $0.severity >= .warning && warnGroups.map(\.0).contains($0.title) }.map(\.title)
                print("   on request \(kind.title) \(m.displayName): \(warns.joined(separator: ", ")) → struts \(d2.struts.count), \(left.isEmpty ? "cleared" : "still: " + left.joined(separator: ", ")), score \(a.score) → \(a2.score), feasible \(a2.feasible)")
            }
        }
        // Random variants with struts (always mode, so every type gets some): no surface may touch a strut.
        var n = 0, minGap = Double.greatestFiniteMagnitude, hits: [String] = [], finN = 0, finMissing: [String] = []
        for i in 0..<48 {
            let kind = AircraftKind.allCases[i % AircraftKind.allCases.count]
            var c = AircraftConfig.random(kind: kind); c.struts = i % 2 == 0 ? .always : .auto
            let d = DesignBuilder.build(c)
            guard !d.struts.isEmpty else { continue }
            n += 1
            if d.struts.contains(where: { $0.group == .fin }) { finN += 1 }
            else if kind.hasTail || kind.isNutBall, !kind.isTwinBoom { finMissing.append(kind.rawValue + (d.strutNotes.isEmpty ? " (NO REASON)" : " (CG)")) }
            let sw = surfaceSweep(d)
            minGap = min(minGap, sw.map(\.gap).min() ?? minGap)
            for h in sw where h.hitAt != nil { hits.append("\(kind.rawValue) \(h.surface)↔\(h.strut) \(h.solid) at \(Int(h.hitAt!))°") }
        }
        print("   random fin struts: \(finN) of \(n) strutted variants braced, missing on \(finMissing.isEmpty ? "none" : finMissing.joined(separator: ", "))")
        print("   random surface sweep (type max throw): \(n) variants with struts, closest \(String(format: "%.1f", minGap)) mm, contacts \(hits.isEmpty ? "none" : hits.joined(separator: "; "))")
    }

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
        do {
            let t0 = Date()
            for kind in AircraftKind.allCases {
                let c = kind.recommended
                let a = Analysis(design: DesignBuilder.build(c))
                print("   recommended \(kind.title): \(c.motor.rawValue) + \(c.battery.name), AUW \(Int(a.totalMass)) g, \(String(format: "%.1f", a.wingLoading)) g/dm², T/W \(String(format: "%.2f", a.thrustToWeight)), \(Int(a.flightTime)) min, score \(a.score)")
            }
            print("   recommended set: \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        }
        // Servo placement report (recommended variants): servo ahead of the hinge, pushrod, balance.
        for kind in AircraftKind.allCases {
            for one in [false, true] where !one || kind.allowsSingleAileronServo {
                var c = kind.recommended; if one { c.aileronServos = 1; c = FixFinder.evaluate(c).config }
                let d = DesignBuilder.build(c); let a = Analysis(design: d)
                let wingCtrl = d.controls.filter { $0.name.contains("aileron") || $0.name.contains("elevon") }
                let gaps = wingCtrl.map { $0.hingeMid.z - $0.servoPosition.z }   // rough: hinge mid vs servo centre
                let rods = d.controls.map { simd_distance($0.armPosition == .zero ? $0.servoPosition : $0.armPosition, $0.hornPosition) }
                // Gap between each servo cutout and the spar groove in the same part (plan coordinates).
                var sparGaps: [String] = []
                for part in d.parts {
                    let rods: [(Vec2, Vec2, Double)] = part.features.compactMap { if case let .rod(a, b, dd) = $0 { return (a, b, dd) }; return nil }
                    for h in part.holes where h.kind == .servo {
                        // Closest corner: spar position at both spanwise edges of the cutout.
                        let bb = Poly.bounds(h.polygon), cy = (bb.min.y + bb.max.y) / 2
                        for (ra, rb, dd) in rods where cy >= min(ra.y, rb.y) - 1 && cy <= max(ra.y, rb.y) + 1 && abs(rb.y - ra.y) > 1e-6 {
                            let su = [bb.min.y, bb.max.y].map { y in ra.x + (rb.x - ra.x) * (y - ra.y) / (rb.y - ra.y) }.max()!
                            sparGaps.append(String(format: "%@ %.1f", h.note, bb.min.x - PrintedParts.servoFrameFlange - (su + dd / 2)))
                        }
                    }
                }
                if !sparGaps.isEmpty { print("   spar→servo frame \(kind.title)\(one ? " 1-servo" : ""): " + sparGaps.joined(separator: ", ") + " mm") }
                print("   servos \(kind.title)\(one ? " 1-servo" : ""): servo z \(wingCtrl.first.map { String(format: "%.0f", $0.servoPosition.z) } ?? "-"), hinge−servo \(gaps.first.map { String(format: "%.0f", $0) } ?? "-") mm, pushrods \(String(format: "%.0f", rods.reduce(0, +))) mm, battery \(Int(c.batteryPosition)) (\(c.battery.name)), CG \(String(format: "%.1f", a.cg.z)) / target \(String(format: "%.1f", a.recommendedCG)), AUW \(String(format: "%.1f", a.totalMass)) g, score \(a.score)" + d.geometryIssues.map { " [\($0)]" }.joined())
            }
        }
        // Spar display check: dual trainer from above and below.
        do {
            var c = AircraftKind.trainer.recommended; c.motorLayout = .dualTractor
            let d = DesignBuilder.build(c); let a = Analysis(design: d)
            for (tag, yaw, pitch) in [("top", Float(0.5), Float(0.9)), ("bottom", Float(2.4), Float(-0.7))] {
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), device: MTLCreateSystemDefaultDevice())
                if let r = Renderer(view: view) {
                    r.setScene(SceneBuilder.aircraft(d, a, deflection: 0, showCG: false), resetCamera: true)
                    r.yaw = yaw; r.pitch = pitch; r.zoom = 0.7
                    if let img = r.snapshot(width: 1100, height: 760) { savePNG(img, dir.appendingPathComponent("spar_\(tag).png")) }
                }
            }
            for p in d.parts { for f in p.features { if case let .rod(a0, b0, dia) = f { print("   rod on \(p.name): \(a0) → \(b0) Ø\(dia), instances \(p.instances.count)") } } }
        }
        // Single vs dual tractor: what the auto power system picks and the weights.
        for kind in AircraftKind.allCases where kind.allowsDualMotors {
            let single = kind.recommended
            var dual = single; dual.motorLayout = .dualTractor
            let aS = Analysis(design: DesignBuilder.build(single))
            let aD0 = Analysis(design: DesignBuilder.build(FixFinder.evaluate(dual).config))
            let r = PowerOptimizer.best(for: dual)
            print("   1→2 \(kind.title): single \(single.motor.rawValue)+\(single.battery.rawValue) \(String(format: "%.1f", aS.totalMass)) g T/W \(String(format: "%.2f", aS.thrustToWeight)) | dual same power \(String(format: "%.1f", aD0.totalMass)) g T/W \(String(format: "%.2f", aD0.thrustToWeight)) | dual re-optimised \(r.map { "\($0.config.motor.rawValue)+\($0.config.battery.rawValue) \(String(format: "%.1f", $0.analysis.totalMass)) g T/W \(String(format: "%.2f", $0.analysis.thrustToWeight))" } ?? "none")")
        }
        // 8 mm foam: every type builds, and the printed parts get the 8 mm versions.
        for kind in AircraftKind.allCases {
            for m in [FoamMaterial.depron8, .epp8, .epp6, .epp10] {
                var c = kind.recommended; c.material = m
                let r = PowerOptimizer.best(for: c)
                let cc = r?.config ?? FixFinder.evaluate(c).config
                let d = DesignBuilder.build(cc); let a = Analysis(design: d)
                print("   8mm \(kind.title) \(m.displayName): \(cc.motor.rawValue)+\(cc.battery.rawValue), spar \(cc.sparSpec.name), AUW \(Int(a.totalMass)) g, score \(a.score), feasible \(a.feasible)" + a.checks.filter { $0.severity == .error }.map { " [\($0.title)]" }.joined())
                if m == .depron8 {
                    for part in PrintedParts.generate(d) {
                        try? part.mesh.stlData(name: part.name).write(to: dir.appendingPathComponent("8mm_\(kind.rawValue)_\(part.fileName).stl"))
                    }
                }
            }
        }
        strutReport(dir)
        // Struts versus random variants: how many more builds become feasible.
        do {
            var off = 0, auto = 0, withStruts = 0, sweepMin = Double.greatestFiniteMagnitude, sweepHits: [String] = []
            for i in 0..<60 {
                let kind = AircraftKind.allCases[i % AircraftKind.allCases.count]
                var c = AircraftConfig.random(kind: kind)
                c.struts = .off
                if Analysis(design: DesignBuilder.build(c)).feasible { off += 1 }
                c.struts = .auto
                let d = DesignBuilder.build(c)
                if Analysis(design: d).feasible { auto += 1 }
                if !d.struts.isEmpty {
                    withStruts += 1
                    let sw = surfaceSweep(d)
                    sweepMin = min(sweepMin, sw.map(\.gap).min() ?? .greatestFiniteMagnitude)
                    for h in sw where h.hitAt != nil { sweepHits.append("\(kind.rawValue) \(h.surface)↔\(h.strut) \(h.solid) at \(Int(h.hitAt!))°") }
                }
            }
            print("   random struts: feasible \(off)/60 without struts, \(auto)/60 with auto struts (\(withStruts) got struts), surface sweep closest \(String(format: "%.1f", sweepMin)) mm, contacts \(sweepHits.isEmpty ? "none" : sweepHits.joined(separator: "; "))")
        }
        // Randomizer: rounded edges appear on tailed types and the variants still build.
        do {
            var rounded = 0, total = 0, feasible = 0, simple = true
            for _ in 0..<40 {
                let kind = AircraftKind.allCases.filter(\.hasTail).randomElement()!
                let c = AircraftConfig.random(kind: kind)
                total += 1
                if c.wingTipRounding > 0 || c.finTopRounding > 0 || c.stabTipRounding > 0 { rounded += 1 }
                let d = DesignBuilder.build(c)
                // Variants already flagged with a geometry issue (e.g. fin reaching the wing) are infeasible anyway.
                if d.geometryIssues.isEmpty && d.parts.contains(where: { !Poly.isSimple($0.outline) }) { simple = false }
                if Analysis(design: d).feasible { feasible += 1 }
            }
            print("   random rounding: \(rounded)/\(total) variants rounded, raw feasible \(feasible)/\(total), outlines without geometry issues simple \(simple)")
        }
        let project = Project()
        project.start(.flyingWing)
        snapshotView(GalleryContent().environmentObject(project), size: CGSize(width: 1300, height: 820), to: dir.appendingPathComponent("ui_gallery.png"))
        for theme in ThemePalette.all {
            Theme.override = theme.name
            snapshotView(GalleryContent().environmentObject(project), size: CGSize(width: 1300, height: 820), to: dir.appendingPathComponent("theme_\(theme.name).png"))
        }
        Theme.override = nil
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
            c.tailWinglets = kind.offersWinglets; c.wingletHeight = kind.isNutBall ? 50 : 45
            c = Project.balanced(c)
            let d = DesignBuilder.build(c)
            let a = Analysis(design: d)
            print("   wl \(kind.title): AUW \(Int(a.totalMass)) g, winglets \(d.parts.contains { $0.role == .winglet }), ESCs \(d.components.filter { $0.name.hasPrefix("ESC") }.count), feasible \(a.feasible)")
            for ch in a.checks where ch.severity >= .warning { print("      [\(ch.severity)] \(ch.title): \(ch.detail)") }
            if kind == .nutBall {
                // Top winglets: every tab must sit in a disc slot on the fixed part, clear of the spar groove.
                let st = c.nutBallWinglet
                let disc = d.parts.first { $0.role == .wing }!, wl = d.parts.first { $0.role == .winglet }!
                let tabUs = wl.outline.filter { $0.y < -0.1 }.map(\.x)
                let slots = disc.holes.filter { $0.kind == .slot && abs(abs(Poly.centroid($0.polygon).y) - st.v) < 1 }
                let inSlots = !tabUs.isEmpty && tabUs.allSatisfy { u in slots.contains { let b = Poly.bounds($0.polygon); return st.u0 + u >= b.min.x - 0.01 && st.u0 + u <= b.max.x + 0.01 } }
                let fixed = disc.regions.first { !$0.isControl }!.polygon
                let onFixed = slots.allSatisfy { $0.polygon.allSatisfy { Poly.contains(fixed, $0) } }
                let sparU = c.rootChord * 0.3, half = c.sparSpec.widthMM / 2 + 2
                let clearSpar = slots.allSatisfy { let b = Poly.bounds($0.polygon); return b.max.x < sparU - half || b.min.x > sparU + half }
                print("   nutball winglets: station ±\(Int(st.v)) mm, base \(Int(st.u0))–\(Int(st.u0 + st.chord)) mm (hinge \(Int(c.rootChord * (1 - c.controlChordPct)))), \(slots.count) slots, tabs in slots \(inSlots), slots on fixed disc \(onFixed), clear of spar \(clearSpar), instances \(wl.instances.count)")
                try? PlanPDF.render(d, a).write(to: dir.appendingPathComponent("wl_nutBall.pdf"))
            }
            if kind == .trainer || kind == .jet || kind == .nutBall {
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
                                              ("horn", PrintedParts.controlHorn(foam: 6).transformed { SIMD3<Double>($0.x, $0.z, $0.y) }.flipped, SIMD3<Float>(0, 3, 0), Float(14))] {
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
        // Horn slots must sit 6 mm behind their hinge (the horn's hole is 6 mm ahead of the slot centre).
        for kind in AircraftKind.allCases {
            for one in [false, true] where !one || kind.allowsSingleAileronServo {
                var c = kind.defaults; if one { c.aileronServos = 1 }
                let d = DesignBuilder.build(c)
                var offsets: [Double] = []
                for part in d.parts {
                    let hinges: [(Vec2, Vec2)] = part.features.compactMap { if case let .hinge(a, b) = $0 { return (a, b) }; return nil }
                    for h in part.holes where h.kind == .hornSlot {
                        let cpt = Poly.centroid(h.polygon)
                        // hinge u at the slot's station (v), from the hinge segment covering it
                        let cands = hinges.compactMap { (a, b) -> Double? in
                            let lo = min(a.y, b.y) - 0.5, hi = max(a.y, b.y) + 0.5
                            guard cpt.y >= lo && cpt.y <= hi, abs(b.y - a.y) > 1e-6 else { return nil }
                            return a.x + (b.x - a.x) * (cpt.y - a.y) / (b.y - a.y)
                        }
                        if let u = cands.min(by: { abs(cpt.x - $0 - 6) < abs(cpt.x - $1 - 6) }) { offsets.append(cpt.x - u) }
                    }
                }
                print("   horns \(kind.title)\(one ? " 1-servo" : ""): \(offsets.count) slots, slot − hinge = " + offsets.map { String(format: "%.2f", $0) }.joined(separator: ", "))
            }
        }
        for kind in AircraftKind.allCases {
            let c = kind.defaults
            let a = Analysis(design: DesignBuilder.build(Project.balanced(c)))
            print("   spar \(kind.title): \(c.sparSpec.name) (\(c.material.displayName)), length \(Int(c.sparLength)) mm, \(String(format: "%.1f", c.sparLength / 1000 * c.sparSpec.gramsPerMeter)) g, tip deflection \(String(format: "%.1f", (a.structure?.wingDeflectionRatio ?? 0) * 100)) %, battery \(Project.balanced(c).battery.name)")
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
