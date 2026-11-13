import Foundation
import simd

typealias Vec2 = SIMD2<Double>

/// 2D polygon helpers. All plan geometry is in millimetres.
enum Poly {
    static func signedArea(_ p: [Vec2]) -> Double {
        guard p.count > 2 else { return 0 }
        var a = 0.0
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return a / 2
    }

    static func area(_ p: [Vec2]) -> Double { abs(signedArea(p)) }

    /// Shrinks a convex polygon by `d` on every edge (used to show hinge/side gaps in 3D).
    static func inset(_ poly: [Vec2], by d: Double) -> [Vec2] {
        let p = ccw(poly)
        let n = p.count
        guard n >= 3 else { return poly }
        var lines: [(Vec2, Vec2)] = []
        for i in 0..<n {
            let a = p[i], b = p[(i + 1) % n]
            let len = simd_distance(a, b)
            guard len > 1e-9 else { continue }
            let dir = (b - a) / len
            lines.append((a + Vec2(-dir.y, dir.x) * d, dir))
        }
        var out: [Vec2] = []
        for i in 0..<lines.count {
            let (p1, d1) = lines[(i + lines.count - 1) % lines.count], (p2, d2) = lines[i]
            let den = cross(d1, d2)
            out.append(abs(den) < 1e-9 ? p2 : p1 + d1 * (cross(p2 - p1, d2) / den))
        }
        return out
    }

    /// Removes duplicate points and zero-width spikes (a vertex where the outline doubles back on itself).
    static func cleaned(_ poly: [Vec2], eps: Double = 1e-6) -> [Vec2] {
        var p = poly
        var changed = true
        while changed && p.count > 3 {
            changed = false
            for i in 0..<p.count {
                let a = p[(i + p.count - 1) % p.count], b = p[i], c = p[(i + 1) % p.count]
                let ab = b - a, bc = c - b
                let dup = simd_length(ab) < eps
                let spike = abs(cross(ab, bc)) < eps * 10 && simd_dot(ab, bc) < 0
                let straight = abs(cross(ab, bc)) < eps * 10 && simd_dot(ab, bc) > 0
                if dup || spike || straight { p.remove(at: i); changed = true; break }
            }
        }
        return p
    }

    static func centroid(_ p: [Vec2]) -> Vec2 {
        let a = signedArea(p)
        guard abs(a) > 1e-9 else { return p.reduce(.zero, +) / Double(max(p.count, 1)) }
        var c = Vec2.zero
        for i in 0..<p.count {
            let j = (i + 1) % p.count
            let cr = p[i].x * p[j].y - p[j].x * p[i].y
            c += (p[i] + p[j]) * cr
        }
        return c / (6 * a)
    }

    static func bounds(_ p: [Vec2]) -> (min: Vec2, max: Vec2) {
        var lo = Vec2(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        return (lo, hi)
    }

    static func ccw(_ p: [Vec2]) -> [Vec2] { signedArea(p) < 0 ? p.reversed() : p }
    static func cw(_ p: [Vec2]) -> [Vec2] { signedArea(p) > 0 ? p.reversed() : p }

    static func circle(_ c: Vec2, _ r: Double, segments: Int = 24) -> [Vec2] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return c + Vec2(cos(a), sin(a)) * r
        }
    }

    /// Axis aligned rectangle (counter-clockwise), optionally rotated around its centre.
    static func rect(center c: Vec2, size s: Vec2, angle: Double = 0) -> [Vec2] {
        let h = s / 2
        let pts = [Vec2(-h.x, -h.y), Vec2(h.x, -h.y), Vec2(h.x, h.y), Vec2(-h.x, h.y)]
        let ca = cos(angle), sa = sin(angle)
        return pts.map { c + Vec2($0.x * ca - $0.y * sa, $0.x * sa + $0.y * ca) }
    }

    static func rect(minU: Double, maxU: Double, minV: Double, maxV: Double) -> [Vec2] {
        [Vec2(minU, minV), Vec2(maxU, minV), Vec2(maxU, maxV), Vec2(minU, maxV)]
    }

    static func contains(_ p: [Vec2], _ q: Vec2) -> Bool {
        var inside = false
        var j = p.count - 1
        for i in 0..<p.count {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y) {
                let x = (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x
                if q.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func containsAll(_ outer: [Vec2], _ inner: [Vec2]) -> Bool {
        inner.allSatisfy { contains(outer, $0) } && !polygonsCross(outer, inner)
    }

    /// Part of polygon `p` inside the convex polygon `window` (Sutherland–Hodgman).
    static func clip(_ p: [Vec2], to window: [Vec2]) -> [Vec2] {
        var out = p
        let w = ccw(window)
        for i in w.indices {
            let a = w[i], b = w[(i + 1) % w.count]
            func inside(_ q: Vec2) -> Bool { (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) >= -1e-9 }
            func cross(_ p0: Vec2, _ p1: Vec2) -> Vec2 {
                let d = p1 - p0, e = b - a
                let den = d.x * e.y - d.y * e.x
                guard abs(den) > 1e-12 else { return p1 }
                let t = ((a.x - p0.x) * e.y - (a.y - p0.y) * e.x) / den
                return p0 + d * t
            }
            let input = out
            out = []
            guard !input.isEmpty else { break }
            for j in input.indices {
                let cur = input[j], prev = input[(j + input.count - 1) % input.count]
                if inside(cur) {
                    if !inside(prev) { out.append(cross(prev, cur)) }
                    out.append(cur)
                } else if inside(prev) { out.append(cross(prev, cur)) }
            }
        }
        return out
    }

    static func overlaps(_ a: [Vec2], _ b: [Vec2]) -> Bool {
        polygonsCross(a, b) || a.contains { contains(b, $0) } || b.contains { contains(a, $0) }
    }

    static func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

    /// Proper segment intersection (touching endpoints are ignored).
    static func segmentsIntersect(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
        let d1 = cross(b - a, c - a), d2 = cross(b - a, d - a)
        let d3 = cross(d - c, a - c), d4 = cross(d - c, b - c)
        let e = 1e-9
        return ((d1 > e && d2 < -e) || (d1 < -e && d2 > e)) &&
               ((d3 > e && d4 < -e) || (d3 < -e && d4 > e))
    }

    static func polygonsCross(_ a: [Vec2], _ b: [Vec2]) -> Bool {
        for i in 0..<a.count {
            let a0 = a[i], a1 = a[(i + 1) % a.count]
            for j in 0..<b.count where segmentsIntersect(a0, a1, b[j], b[(j + 1) % b.count]) { return true }
        }
        return false
    }

    static func isSimple(_ p: [Vec2]) -> Bool {
        let n = p.count
        guard n > 3 else { return n == 3 && area(p) > 1e-6 }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                if segmentsIntersect(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    /// Cuts a small V alignment notch into the edge of `outline` closest to `point`.
    /// Rounds the corner of `poly` at `corner` (an existing vertex) with radius `r`: the vertex is replaced by an
    /// arc tangent to both edges. The radius is capped at 45 % of the shorter adjacent edge. Polygons sharing the
    /// corner with the same edge directions get identical arcs.
    static func fillet(_ poly: [Vec2], at corner: Vec2, radius r: Double, segments: Int = 10) -> [Vec2] {
        guard r > 0.2, let i = poly.firstIndex(where: { simd_distance($0, corner) < 1e-6 }) else { return poly }
        let n = poly.count
        let p1 = poly[i], p0 = poly[(i - 1 + n) % n], p2 = poly[(i + 1) % n]
        let l0 = simd_distance(p0, p1), l2 = simd_distance(p2, p1)
        guard l0 > 1e-6, l2 > 1e-6 else { return poly }
        let d0 = (p0 - p1) / l0, d2 = (p2 - p1) / l2
        let cosA = max(-0.999, min(0.999, simd_dot(d0, d2)))
        let half = acos(cosA) / 2
        guard half > 0.02, half < .pi / 2 - 0.02 else { return poly }
        var tdist = r / tan(half)
        tdist = min(tdist, 0.45 * min(l0, l2))
        let rEff = tdist * tan(half)
        let a = p1 + d0 * tdist, b = p1 + d2 * tdist
        let bis = simd_normalize(d0 + d2)
        let c = p1 + bis * (rEff / sin(half))
        let a0 = atan2(a.y - c.y, a.x - c.x)
        var a1 = atan2(b.y - c.y, b.x - c.x)
        var da = a1 - a0
        while da > .pi { da -= 2 * .pi }
        while da < -.pi { da += 2 * .pi }
        a1 = a0 + da
        let arc = (0...segments).map { k -> Vec2 in
            let t = a0 + (a1 - a0) * Double(k) / Double(segments)
            return c + Vec2(cos(t), sin(t)) * rEff
        }
        var out = poly
        out.replaceSubrange(i...i, with: arc)
        return out
    }
    /// Same radius cap `fillet` would apply at that corner (so several polygons can share one effective radius).
    static func filletLimit(_ poly: [Vec2], at corner: Vec2) -> Double {
        guard let i = poly.firstIndex(where: { simd_distance($0, corner) < 1e-6 }) else { return .greatestFiniteMagnitude }
        let n = poly.count
        let p1 = poly[i], p0 = poly[(i - 1 + n) % n], p2 = poly[(i + 1) % n]
        let l0 = simd_distance(p0, p1), l2 = simd_distance(p2, p1)
        let d0 = (p0 - p1) / max(l0, 1e-9), d2 = (p2 - p1) / max(l2, 1e-9)
        let half = acos(max(-0.999, min(0.999, simd_dot(d0, d2)))) / 2
        return 0.45 * min(l0, l2) * tan(half)
    }
    /// Rounds a corner shared by several polygons with one radius (capped so it fits every one of them).
    static func filletShared(_ polys: inout [[Vec2]], at corner: Vec2, radius r: Double) {
        guard r > 0.2 else { return }
        let limit = polys.map { filletLimit($0, at: corner) }.min() ?? 0
        let rr = min(r, limit)
        for k in polys.indices { polys[k] = fillet(polys[k], at: corner, radius: rr) }
    }

    static func insertNotch(_ outline: [Vec2], at point: Vec2, width: Double = 4, depth: Double = 2.5) -> [Vec2] {
        var poly = ccw(outline)
        var best = (i: 0, t: 0.0, d: Double.greatestFiniteMagnitude)
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ab = b - a
            let len2 = simd_length_squared(ab)
            guard len2 > 1e-9 else { continue }
            let t = max(0, min(1, simd_dot(point - a, ab) / len2))
            let d = simd_distance(a + ab * t, point)
            if d < best.d { best = (i, t, d) }
        }
        let a = poly[best.i], b = poly[(best.i + 1) % poly.count]
        let len = simd_distance(a, b)
        guard len > width * 2 else { return poly }
        let dir = (b - a) / len
        let inward = Vec2(-dir.y, dir.x)
        let along = max(width, min(len - width, best.t * len))
        let p = a + dir * along
        poly.insert(contentsOf: [p - dir * (width / 2), p + inward * depth, p + dir * (width / 2)], at: best.i + 1)
        return poly
    }

    /// Inserts a rectangular tab protruding outward from the edge closest to `point`.
    static func insertTab(_ outline: [Vec2], at point: Vec2, width: Double, height: Double) -> [Vec2] {
        var poly = ccw(outline)
        var best = (i: 0, t: 0.0, d: Double.greatestFiniteMagnitude)
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ab = b - a
            let len2 = simd_length_squared(ab)
            guard len2 > 1e-9 else { continue }
            let t = max(0, min(1, simd_dot(point - a, ab) / len2))
            let d = simd_distance(a + ab * t, point)
            if d < best.d { best = (i, t, d) }
        }
        let a = poly[best.i], b = poly[(best.i + 1) % poly.count]
        let len = simd_distance(a, b)
        guard len > width + 2 else { return poly }
        let dir = (b - a) / len
        let outward = Vec2(dir.y, -dir.x)
        let along = max(width / 2 + 1, min(len - width / 2 - 1, best.t * len))
        let p0 = a + dir * (along - width / 2), p1 = a + dir * (along + width / 2)
        poly.insert(contentsOf: [p0, p0 + outward * height, p1 + outward * height, p1], at: best.i + 1)
        return poly
    }

    // MARK: - Triangulation (ear clipping with hole bridging)

    /// Triangulates a polygon with holes. The result is verified against the topology
    /// (n + 2h − 2 triangles); on failure other bridge choices / hole orders are tried.
    static func triangulate(outer: [Vec2], holes: [[Vec2]] = []) -> (points: [Vec2], triangles: [Int]) {
        let hs = holes.filter { $0.count >= 3 }
        let expected = outer.count + hs.reduce(0) { $0 + $1.count } + 2 * hs.count - 2
        var best: (points: [Vec2], triangles: [Int])?
        for reverseOrder in [false, true] {
            for skip in 0..<4 {
                let r = triangulate(outer: outer, holes: hs, skip: skip, reverseOrder: reverseOrder)
                if r.triangles.count / 3 == expected { return r }
                if best == nil || r.triangles.count > best!.triangles.count { best = r }
            }
        }
        return best!
    }

    private static func triangulate(outer: [Vec2], holes: [[Vec2]], skip: Int, reverseOrder: Bool) -> (points: [Vec2], triangles: [Int]) {
        var poly = ccw(outer)
        var hs = holes.map { cw($0) }.filter { $0.count >= 3 }
            .sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        if reverseOrder { hs.reverse() }

        for (hi, hole) in hs.enumerated() {
            let mi = hole.indices.max { hole[$0].x < hole[$1].x }!
            let m = hole[mi]
            let remaining = Array(hs[(hi + 1)...])
            let candidates = poly.indices.sorted { simd_distance(poly[$0], m) < simd_distance(poly[$1], m) }
            var chosen = candidates.first!
            var valid = 0
            search: for vi in candidates {
                let v = poly[vi]
                for i in 0..<poly.count {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if a == v || b == v { continue }
                    if segmentsIntersect(m, v, a, b) { continue search }
                }
                for h in [hole] + remaining {
                    for i in 0..<h.count {
                        let a = h[i], b = h[(i + 1) % h.count]
                        if a == m || b == m { continue }
                        if segmentsIntersect(m, v, a, b) { continue search }
                    }
                }
                chosen = vi
                if valid >= skip { break }
                valid += 1
            }
            var rotated = Array(hole[mi...] + hole[..<mi])
            rotated.append(m)
            var merged = Array(poly[...chosen])
            merged.append(contentsOf: rotated)
            merged.append(poly[chosen])
            if chosen + 1 < poly.count { merged.append(contentsOf: poly[(chosen + 1)...]) }
            poly = merged
        }
        return (poly, earClip(poly))
    }

    private static func earClip(_ pts: [Vec2]) -> [Int] {
        var idx = Array(pts.indices)
        var tris: [Int] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < 10000 {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = pts[i0], b = pts[i1], c = pts[i2]
                if cross(b - a, c - b) <= 1e-10 { continue }
                var ear = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    let p = pts[j]
                    if p == a || p == b || p == c { continue }
                    if pointInTriangle(p, a, b, c) { ear = false; break }
                }
                if ear {
                    tris += [i0, i1, i2]
                    idx.remove(at: k)
                    clipped = true
                    break
                }
            }
            if !clipped {
                // Degenerate remainder: drop the flattest vertex to make progress.
                let k = idx.indices.min { k1, k2 in
                    func f(_ k: Int) -> Double {
                        let a = pts[idx[(k + idx.count - 1) % idx.count]], b = pts[idx[k]], c = pts[idx[(k + 1) % idx.count]]
                        return abs(cross(b - a, c - b))
                    }
                    return f(k1) < f(k2)
                }!
                idx.remove(at: k)
            }
        }
        if idx.count == 3, cross(pts[idx[1]] - pts[idx[0]], pts[idx[2]] - pts[idx[1]]) > 0 { tris += idx }
        return tris
    }

    private static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let e = 1e-9
        return cross(b - a, p - a) > e && cross(c - b, p - b) > e && cross(a - c, p - c) > e
    }
}
