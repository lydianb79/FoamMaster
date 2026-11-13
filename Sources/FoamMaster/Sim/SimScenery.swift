import Foundation
import simd

/// The flying site of the simulator (metres, y up, the pilot at the origin looking along −z).
///
/// Ground: smooth-shaded terrain in three rings of detail (flat field, rolling hills further out), vertex-coloured
/// meadow and patchwork crops; the shader adds fine grass texture (`Uniforms.ground`). Near the pilot: grass tufts
/// and flowers, the striped mown strip, the pits (gazebo, chairs, car, table, flight boxes), a fence and a windsock.
/// Around: a pond with reeds, a gravel track with poplars to a farm, hedges between the fields, woods, single
/// trees with blob shadows, a second farm and a village with a church, ridges and two mountain ranges in the haze,
/// flat-bottomed clouds, circling birds (moving groups) and a sky dome with the sun.
///
/// The same layout also gives the solid obstacles (trees, bushes, buildings, poles) the flight model collides with.
enum SimScenery {
    typealias P = SIMD3<Double>
    typealias C = SIMD4<Float>

    static let horizon = C(0.75, 0.84, 0.93, 1)
    static let zenith = C(0.25, 0.47, 0.85, 1)
    static let sunDir = simd_normalize(P(0.8, 0.58, 0.05))      // from the right: shadows fall sideways, in view (not hidden behind what casts them)

    // MARK: Noise

    static func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ seed &* 144665))
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h & 0xFFFFFF) / Double(0xFFFFFF)
    }
    static func noise(_ x: Double, _ y: Double, _ seed: Int = 0) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed), c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        let top = a + (b - a) * sx, bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }
    static func fbm(_ x: Double, _ y: Double, _ seed: Int = 0, octaves: Int = 4) -> Double {
        var s = 0.0, amp = 0.5, f = 1.0
        for o in 0..<octaves { s += amp * noise(x * f, y * f, seed + o * 17); amp *= 0.5; f *= 2.03 }
        return s
    }

    // MARK: Ground

    /// Terrain height: flat around the field (r < 220 m), rolling hills further out.
    static func height(_ x: Double, _ z: Double) -> Double {
        let r = (x * x + z * z).squareRoot()
        let ramp = min(max((r - 220) / 500, 0), 1)
        let hills = (fbm(x / 380, z / 380, 3) - 0.35) * 75
        return max(hills, -4) * ramp * ramp
    }

    /// Terrain cell size: 4 m around the field, 10 m to 720 m, 40 m beyond.
    static func cellSize(_ x: Double, _ z: Double) -> Double {
        let c = max(abs(x), abs(z))
        return c < 240 ? 4 : c < 720 ? 10 : 40
    }

    /// Height of the drawn terrain surface (the triangles, not the smooth function): what things stand on and
    /// what the model touches.
    static func surfaceHeight(_ x: Double, _ z: Double) -> Double {
        let cs = cellSize(x, z)
        let x0 = floor(x / cs) * cs, z0 = floor(z / cs) * cs
        let fx = (x - x0) / cs, fz = (z - z0) / cs
        let h00 = height(x0, z0), h11 = height(x0 + cs, z0 + cs)
        if fx >= fz {
            let h10 = height(x0 + cs, z0)
            return h00 + (h10 - h00) * fx + (h11 - h10) * fz
        }
        let h01 = height(x0, z0 + cs)
        return h00 + (h01 - h00) * fz + (h11 - h01) * fx
    }

    // Pond, front left of the pilot (about 90 m out).
    static let pondCenter = SIMD2<Double>(-66, -82)
    static func pondRadius(_ a: Double) -> Double { 24 * (1 + 0.22 * sin(3 * a + 1) + 0.1 * sin(5 * a + 2)) }
    /// 0 at the pond centre, 1 at the shore.
    static func pondDistance(_ x: Double, _ z: Double) -> Double {
        let dx = (x - pondCenter.x) / 1.35, dz = z - pondCenter.y
        return (dx * dx + dz * dz).squareRoot() / pondRadius(atan2(dz, dx))
    }
    static func isWater(_ x: Double, _ z: Double) -> Bool { pondDistance(x, z) < 1 }

    // Gravel track from the pits to the farm (behind left).
    static let trackPoints: [SIMD2<Double>] = [[-12, 12], [-26, 28], [-62, 55], [-120, 90], [-190, 140], [-262, 205], [-322, 248], [-350, 262]]
    static let track: [SIMD2<Double>] = {
        var out: [SIMD2<Double>] = []
        let p = trackPoints
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let n = max(Int(simd_length(p2 - p1) / 3), 2)
            for k in 0..<n {
                let t = Double(k) / Double(n), t2 = t * t, t3 = t2 * t
                let a = p1 * 2, b = (p2 - p0) * t
                let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
                out.append((a + b + c + d) * 0.5)
            }
        }
        out.append(p[p.count - 1])
        return out
    }()
    static func trackDistance(_ x: Double, _ z: Double) -> Double {
        let q = SIMD2(x, z)
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(track.count - 1) {
            let a = track[i], b = track[i + 1], ab = b - a
            let t = min(max(simd_dot(q - a, ab) / max(simd_dot(ab, ab), 1e-9), 0), 1)
            best = min(best, simd_length(q - (a + ab * t)))
        }
        return best
    }

    // Farms and the village (centres, for keeping trees out of the yards).
    static let farm = SIMD2<Double>(-360, 275)
    static let farm2 = SIMD2<Double>(440, -390)
    static let village = SIMD2<Double>(700, -1250)
    static let hamlet = SIMD2<Double>(-1150, -700)

    /// Grass / crop colour at a point.
    static func groundColor(_ x: Double, _ z: Double) -> SIMD3<Double> {
        let r = (x * x + z * z).squareRoot()
        let n = fbm(x / 35, z / 35, 1), n2 = noise(x / 7, z / 7, 9)
        var c = SIMD3<Double>(0.29, 0.49, 0.2) * (0.82 + 0.34 * n) + SIMD3(0.05, 0.035, -0.02) * (n2 - 0.5) * 2
        let dry = fbm(x / 90, z / 90, 5)
        if dry > 0.58 { c = c * (1 - (dry - 0.58) * 2.2) + SIMD3(0.55, 0.5, 0.24) * (dry - 0.58) * 2.2 }   // drier patches
        // Lush, darker ring round the pond, mud at the shore.
        let pd = pondDistance(x, z)
        if pd < 1.5 { c = c * 0.85 + SIMD3(0.02, 0.06, 0.0) }
        if pd < 1.12 { c = SIMD3(0.33, 0.29, 0.2) }
        // Worn grass around the pits.
        let pits = ((x + 7) * (x + 7) + (z - 5) * (z - 5)).squareRoot()
        if pits < 9 { c = c * 0.8 + SIMD3(0.4, 0.37, 0.22) * 0.2 }
        if r > 320 {
            // Fields: 140 × 120 m plots of wheat, ploughed earth, rapeseed, young crops or pasture.
            // Plots of 140 × 120 m, about half of them split in two (along x or z) – fields of different sizes.
            var px = Int(floor((x + 7) / 140)), pz = Int(floor((z - 11) / 120))
            let split = hash(px, pz, 23)
            if split < 0.25 { px = px * 2 + (((x + 7) / 70).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 0 : 1) + 1000 }
            else if split < 0.5 { pz = pz * 2 + (((z - 11) / 60).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 0 : 1) + 1000 }
            let k = hash(px, pz, 21)
            let crops: [(Double, SIMD3<Double>)] = [
                (0.13, [0.8, 0.69, 0.36]),     // ripe wheat
                (0.19, [0.86, 0.8, 0.55]),     // barley, stubble
                (0.27, [0.45, 0.33, 0.22]),    // ploughed
                (0.31, [0.33, 0.25, 0.17]),    // dark soil, freshly sown
                (0.37, [0.88, 0.8, 0.2]),      // rapeseed
                (0.47, [0.36, 0.55, 0.22]),    // young crops
                (0.52, [0.22, 0.42, 0.16]),    // maize
                (0.54, [0.86, 0.72, 0.15]),    // sunflowers
                (0.555, [0.55, 0.45, 0.72]),   // lavender
            ]
            if let crop = crops.first(where: { k < $0.0 })?.1 {
                // Rows along the plot, and every field a little different.
                let rows = 0.93 + 0.07 * sin((k > 0.3 ? x : z) * 0.9)
                let tint = 0.92 + 0.16 * hash(px, pz, 29)
                let t = min((r - 320) / 80, 1)
                c = c * (1 - t) + crop * (0.9 + 0.2 * n2) * rows * tint * t
            }
        }
        return c
    }

    /// Where trees and bushes may grow.
    static func free(_ x: Double, _ z: Double, margin: Double = 0) -> Bool {
        if abs(x) < 16 + margin, z > -100 - margin, z < 20 + margin { return false }       // strip and pilot area
        if x * x + z * z < (40 + margin) * (40 + margin) { return false }
        if pondDistance(x, z) < 1.25 + margin / 25 { return false }
        if trackDistance(x, z) < 6 + margin { return false }
        for c in [farm, farm2] where simd_length(SIMD2(x, z) - c) < 70 + margin { return false }
        if simd_length(SIMD2(x, z) - village) < 180 || simd_length(SIMD2(x, z) - hamlet) < 120 { return false }
        return true
    }

    // MARK: Layout (also the obstacles)

    enum TreeKind { case broadleaf, conifer, birch, poplar }
    struct Tree { var x, z, y, h: Double; var seed: Int; var kind: TreeKind }
    struct Obstacle { var x, z, r, top: Double; var name: String }

    struct Layout {
        var trees: [Tree] = []
        var bushes: [(x: Double, z: Double, r: Double)] = []
        var hedges: [(x: Double, z: Double, r: Double)] = []
        var obstacles: [Obstacle] = []
    }

    static let layout: Layout = {
        var L = Layout()
        var n = 0
        func addTree(_ x: Double, _ z: Double, kind: TreeKind? = nil, h: Double? = nil) {
            n += 1
            let r = hash(n, 1, 41)
            let k: TreeKind = kind ?? (r < 0.3 ? .conifer : r < 0.42 ? .birch : .broadleaf)
            let hh = h ?? (k == .birch ? 9 + hash(n, 2, 41) * 6 : 8 + hash(n, 2, 41) * 12)
            let y = surfaceHeight(x, z)
            L.trees.append(Tree(x: x, z: z, y: y, h: hh, seed: n, kind: k))
            let crown = k == .poplar ? hh * 0.13 : k == .conifer ? hh * 0.24 : hh * 0.3
            L.obstacles.append(Obstacle(x: x, z: z, r: crown * 0.85, top: y + hh, name: "a tree"))
        }
        // Tree lines along the field edges (with gaps).
        let lines: [(Double, Double, Double, Double)] = [(-260, -235, 240, -255), (225, -245, 262, 210), (-290, 170, -236, -225), (60, 250, 300, 230)]
        for (x0, z0, x1, z1) in lines {
            let len = ((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)).squareRoot()
            var d = 0.0, k = 0
            while d < len {
                k += 1
                if hash(k, Int(x0), 51) > 0.14 {
                    let t = d / len
                    let x = x0 + (x1 - x0) * t + (hash(k, 8, 51) - 0.5) * 6, z = z0 + (z1 - z0) * t + (hash(k, 9, 51) - 0.5) * 6
                    if free(x, z) { addTree(x, z) }
                }
                d += 6 + hash(k, 10, 51) * 7
            }
        }
        // Woods: clusters further out, mostly conifers on the hills.
        for w in 0..<12 {
            let a = hash(w, 1, 61) * 2 * .pi, r = 330 + hash(w, 2, 61) * 520
            let cx = cos(a) * r, cz = sin(a) * r
            let size = 40 + hash(w, 3, 61) * 40
            let coniferous = hash(w, 4, 61) < 0.5
            for t in 0..<44 {
                let ang = hash(t, w, 62) * 2 * .pi, rad = hash(t, w, 63).squareRoot() * size
                let x = cx + cos(ang) * rad, z = cz + sin(ang) * rad
                if free(x, z) { addTree(x, z, kind: coniferous ? (hash(t, w, 64) < 0.8 ? .conifer : .birch) : nil) }
            }
        }
        // Poplars along the track.
        var d = 0.0
        for i in 0..<(track.count - 1) {
            let a = track[i], b = track[i + 1]
            d += simd_length(b - a)
            if d > 18, simd_length(a) > 50 {
                d = 0
                let dir = simd_normalize(b - a), side = SIMD2(-dir.y, dir.x)
                for s in [-1.0, 1.0] where hash(i, Int(s), 65) > 0.25 {
                    let p = a + side * (6.5 * s)
                    addTree(p.x, p.y, kind: .poplar, h: 16 + hash(i, 3, 65) * 6)
                }
            }
        }
        // Single trees and bushes in the meadow, a few by the pond.
        for i in 0..<70 {
            let x = (hash(i, 1, 71) - 0.5) * 440, z = (hash(i, 2, 71) - 0.5) * 440
            guard free(x, z, margin: 4) else { continue }
            if hash(i, 3, 71) < 0.45 { addTree(x, z) }
            else {
                let r = 0.9 + hash(i, 4, 71) * 1.6
                L.bushes.append((x, z, r))
                L.obstacles.append(Obstacle(x: x, z: z, r: r, top: surfaceHeight(x, z) + r * 1.3, name: "a bush"))
            }
        }
        for i in 0..<6 {
            let a = Double(i) / 6 * 2 * .pi + 0.4
            let rr = pondRadius(a) * 1.6
            let x = pondCenter.x + cos(a) * rr * 1.35, z = pondCenter.y + sin(a) * rr
            if free(x, z, margin: 6) { addTree(x, z, kind: i % 2 == 0 ? .birch : .broadleaf) }
        }
        // Hedges along some field boundaries.
        for i in -6...6 { for j in -6...6 {
            let x0 = Double(i) * 140 - 7, z0 = Double(j) * 120 + 11
            for horizontal in [true, false] where hash(i, j * 2 + (horizontal ? 1 : 0), 73) < 0.35 {
                var t = 0.0
                let len = horizontal ? 140.0 : 120.0
                while t < len {
                    let x = horizontal ? x0 + t : x0, z = horizontal ? z0 : z0 + t
                    let r = (x * x + z * z).squareRoot()
                    if r > 330, r < 900, free(x, z) {
                        let rr = 1.4 + hash(Int(t), i * 13 + j, 74) * 0.8
                        L.hedges.append((x, z, rr))
                        L.obstacles.append(Obstacle(x: x, z: z, r: rr, top: surfaceHeight(x, z) + rr * 1.5, name: "a hedge"))
                    }
                    t += 2.6
                }
            }
        }}
        // Buildings and poles.
        L.obstacles.append(Obstacle(x: farm.x, z: farm.y, r: 32, top: surfaceHeight(farm.x, farm.y) + 13, name: "the farm"))
        L.obstacles.append(Obstacle(x: farm2.x, z: farm2.y, r: 26, top: surfaceHeight(farm2.x, farm2.y) + 11, name: "the farm"))
        L.obstacles.append(Obstacle(x: 12, z: -8, r: 0.35, top: 4.3, name: "the windsock"))
        L.obstacles.append(Obstacle(x: -9, z: 6, r: 2.2, top: 2.6, name: "the gazebo"))
        L.obstacles.append(Obstacle(x: -17, z: 10, r: 2.3, top: 1.5, name: "the car"))
        return L
    }()

    /// Obstacles bucketed in 25 m cells.
    private static let obstacleGrid: [Int: [Int]] = {
        var g: [Int: [Int]] = [:]
        for (i, o) in layout.obstacles.enumerated() {
            let lo = cellKey(o.x - o.r, o.z - o.r), hi = cellKey(o.x + o.r, o.z + o.r)
            for cx in lo.0...hi.0 { for cz in lo.1...hi.1 { g[cx &* 100_003 &+ cz, default: []].append(i) } }
        }
        return g
    }()
    private static func cellKey(_ x: Double, _ z: Double) -> (Int, Int) { (Int(floor(x / 25)), Int(floor(z / 25))) }

    /// What the model hits at this point, if anything.
    static func obstacle(at p: P) -> String? {
        let k = cellKey(p.x, p.z)
        guard let list = obstacleGrid[k.0 &* 100_003 &+ k.1] else { return nil }
        for i in list {
            let o = layout.obstacles[i]
            let dx = p.x - o.x, dz = p.z - o.z
            if dx * dx + dz * dz < o.r * o.r, p.y < o.top { return o.name }
        }
        return nil
    }

    // MARK: Geometry builder

    /// Vertex buffer builder: lit triangles with per-corner colours and optional normals, unlit lines;
    /// `tag` ≥ 2 puts triangles in a moving group.
    struct Geo {
        var v: [GPUVertex] = []
        var lines: [GPUVertex] = []
        var tag: Float = 1

        mutating func tri(_ a: P, _ b: P, _ c: P, _ ca: C, _ cb: C, _ cc: C, normals: (P, P, P)? = nil) {
            let cr = simd_cross(b - a, c - a), len = simd_length(cr)
            guard len > 1e-10 else { return }
            let fn = cr / len
            let ns = normals ?? (fn, fn, fn)
            func put(_ p: P, _ n: P, _ col: C) {
                v.append(GPUVertex(position: SIMD4(Float(p.x), Float(p.y), Float(p.z), 1), normal: SIMD4(Float(n.x), Float(n.y), Float(n.z), tag), color: col))
            }
            put(a, ns.0, ca); put(b, ns.1, cb); put(c, ns.2, cc)
        }
        mutating func tri(_ a: P, _ b: P, _ c: P, _ col: C) { tri(a, b, c, col, col, col) }
        mutating func quad(_ a: P, _ b: P, _ c: P, _ d: P, _ col: C) { tri(a, b, c, col); tri(a, c, d, col) }
        /// A mesh in one colour; `shade` darkens/brightens per corner (baked occlusion).
        mutating func mesh(_ m: Mesh3D, _ col: C, shade: ((P) -> Float)? = nil) {
            for t in m.triangles {
                if let shade { tri(t.0, t.1, t.2, scale(col, shade(t.0)), scale(col, shade(t.1)), scale(col, shade(t.2))) }
                else { tri(t.0, t.1, t.2, col) }
            }
        }
        mutating func line(_ a: P, _ b: P, _ col: C) {
            for p in [a, b] { lines.append(GPUVertex(position: SIMD4(Float(p.x), Float(p.y), Float(p.z), 1), normal: SIMD4(0, 0, 0, 0), color: col)) }
        }
        var scene: SceneData { var s = SceneData(); s.label = "Field"; s.triangles = v; s.lines = lines; return s }
    }

    static func scale(_ c: C, _ k: Float) -> C { C(c.x * k, c.y * k, c.z * k, c.w) }
    static func rgb(_ c: SIMD3<Double>, _ a: Float = 1) -> C { C(Float(c.x), Float(c.y), Float(c.z), a) }

    // MARK: Shapes

    static func ellipsoid(_ c: P, _ r: P, segments: Int = 8, rings: Int = 6) -> Mesh3D {
        var m = Mesh3D()
        func p(_ i: Int, _ j: Int) -> P {
            let th = Double(i) / Double(rings) * .pi, ph = Double(j) / Double(segments) * 2 * .pi
            return c + P(sin(th) * cos(ph), cos(th), sin(th) * sin(ph)) * r
        }
        for i in 0..<rings { for j in 0..<segments {
            m.triangles.append((p(i, j), p(i + 1, j + 1), p(i + 1, j)))
            m.triangles.append((p(i, j), p(i, j + 1), p(i + 1, j + 1)))
        } }
        return m
    }
    static func cone(_ base: P, radius r: Double, height h: Double, segments n: Int = 9) -> Mesh3D {
        var m = Mesh3D()
        let tip = base + [0, h, 0]
        for j in 0..<n {
            let a0 = Double(j) / Double(n) * 2 * .pi, a1 = Double(j + 1) / Double(n) * 2 * .pi
            let p0 = base + [cos(a0) * r, 0, sin(a0) * r], p1 = base + [cos(a1) * r, 0, sin(a1) * r]
            m.triangles.append((p0, tip, p1)); m.triangles.append((p0, p1, base))
        }
        return m
    }
    static func post(_ base: P, radius r: Double, height h: Double, segments: Int = 7) -> Mesh3D {
        SceneBuilder.cylinder(center: .zero, radius: r, length: h, segments: segments).rotated(-.pi / 2, axis: [1, 0, 0]).translated(base + [0, h / 2, 0])
    }
    /// Box of size (w, h, d) standing on `base`, turned by `yaw` about the vertical.
    static func block(_ base: P, _ w: Double, _ h: Double, _ d: Double, yaw: Double = 0) -> Mesh3D {
        Mesh3D.box(min: [-w / 2, 0, -d / 2], max: [w / 2, h, d / 2]).rotated(yaw, axis: [0, 1, 0]).translated(base)
    }

    /// A house: walls, a pitched roof (ridge along its width), a door and windows.
    static func house(_ g: inout Geo, at c: SIMD2<Double>, w: Double, d: Double, h: Double, roofH: Double, yaw: Double, wall: C, roof: C) {
        let y = surfaceHeight(c.x, c.y) - 0.6
        let base = P(c.x, y, c.y)
        g.mesh(block(base, w, h + 0.6, d, yaw: yaw), wall)
        func w2(_ x: Double, _ yy: Double, _ z: Double) -> P {
            base + P(x * cos(yaw) + z * sin(yaw), yy, -x * sin(yaw) + z * cos(yaw))
        }
        let top = h + 0.6, o = 0.5
        let a = w2(-w / 2 - o, top - 0.2, -d / 2 - o), b = w2(w / 2 + o, top - 0.2, -d / 2 - o)
        let cc = w2(w / 2 + o, top - 0.2, d / 2 + o), dd = w2(-w / 2 - o, top - 0.2, d / 2 + o)
        let r0 = w2(-w / 2 - o, top + roofH, 0), r1 = w2(w / 2 + o, top + roofH, 0)
        g.quad(a, b, r1, r0, roof)
        g.quad(dd, r0, r1, cc, scale(roof, 0.85))
        let gable0 = w2(-w / 2, top + roofH - 0.1, 0), gable1 = w2(w / 2, top + roofH - 0.1, 0)
        g.tri(w2(-w / 2, top, -d / 2), gable0, w2(-w / 2, top, d / 2), wall)
        g.tri(w2(w / 2, top, -d / 2), w2(w / 2, top, d / 2), gable1, wall)
        // Door and windows on the front (−z side), slightly proud of the wall.
        let win = C(0.2, 0.25, 0.32, 1), door = C(0.35, 0.22, 0.14, 1)
        let f = -d / 2 - 0.05
        g.quad(w2(-0.5, 0.6, f), w2(0.5, 0.6, f), w2(0.5, 2.7, f), w2(-0.5, 2.7, f), door)
        var x = -w / 2 + 1.6
        while x < w / 2 - 1.2 {
            if abs(x) > 1.3 {
                g.quad(w2(x - 0.55, 1.6, f), w2(x + 0.55, 1.6, f), w2(x + 0.55, 2.8, f), w2(x - 0.55, 2.8, f), win)
                if h > 5 { g.quad(w2(x - 0.55, 4.3, f), w2(x + 0.55, 4.3, f), w2(x + 0.55, 5.4, f), w2(x - 0.55, 5.4, f), win) }
            }
            x += 2.6
        }
    }

    // MARK: Build

    static func build() -> SceneData {
        var g = Geo()
        terrain(&g)
        pond(&g)
        trackAndYards(&g)
        strip(&g)
        grassAndFlowers(&g)
        trees(&g)
        farForests(&g)
        buildings(&g)
        pits(&g)
        ridgesAndMountains(&g)
        clouds(&g)
        birds(&g)
        var s = g.scene
        s.groups = birdGroups
        return s
    }

    /// Terrain in three rings of detail, smooth normals from the height gradient, colours per vertex.
    static func terrain(_ g: inout Geo) {
        func tier(extent: Double, cell: Double, hole: Double) {
            let n = Int(extent * 2 / cell)
            var hgt = [Double](repeating: 0, count: (n + 1) * (n + 1))
            var col = [C](repeating: .zero, count: (n + 1) * (n + 1))
            var nrm = [P](repeating: [0, 1, 0], count: (n + 1) * (n + 1))
            for i in 0...n { for j in 0...n {
                let x = -extent + Double(i) * cell, z = -extent + Double(j) * cell
                let k = i * (n + 1) + j
                let h = height(x, z)
                hgt[k] = h
                let e = cell
                let dx = height(x + e, z) - height(x - e, z), dz = height(x, z + e) - height(x, z - e)
                nrm[k] = simd_normalize(P(-dx / (2 * e), 1, -dz / (2 * e)))
                col[k] = rgb(groundColor(x, z))
            }}
            for i in 0..<n { for j in 0..<n {
                let x0 = -extent + Double(i) * cell, z0 = -extent + Double(j) * cell
                if hole > 0, max(abs(x0 + cell / 2), abs(z0 + cell / 2)) < hole { continue }
                let k00 = i * (n + 1) + j, k10 = (i + 1) * (n + 1) + j, k11 = (i + 1) * (n + 1) + j + 1, k01 = i * (n + 1) + j + 1
                let p00 = P(x0, hgt[k00], z0), p10 = P(x0 + cell, hgt[k10], z0)
                let p11 = P(x0 + cell, hgt[k11], z0 + cell), p01 = P(x0, hgt[k01], z0 + cell)
                g.tri(p00, p11, p10, col[k00], col[k11], col[k10], normals: (nrm[k00], nrm[k11], nrm[k10]))
                g.tri(p00, p01, p11, col[k00], col[k01], col[k11], normals: (nrm[k00], nrm[k01], nrm[k11]))
            }}
        }
        tier(extent: 240, cell: 4, hole: 0)
        tier(extent: 720, cell: 10, hole: 240)
        tier(extent: 3600, cell: 40, hole: 720)
        // Skirts: a short wall down from the outer edge of each finer ring – where it meets the coarser ring the two
        // surfaces never quite line up, and the gap would show the sky.
        for (extent, cell) in [(240.0, 4.0), (720.0, 10.0)] {
            let n = Int(extent * 2 / cell)
            for side in 0..<4 { for i in 0..<n {
                func edge(_ k: Int) -> P {
                    let t = -extent + Double(k) * cell
                    let (x, z): (Double, Double) = side == 0 ? (t, -extent) : side == 1 ? (extent, t) : side == 2 ? (t, extent) : (-extent, t)
                    return P(x, height(x, z), z)
                }
                let a = edge(i), b = edge(i + 1), down = P(0, -6, 0)
                let ca = rgb(groundColor(a.x, a.z) * 0.85), cb = rgb(groundColor(b.x, b.z) * 0.85)
                g.tri(a, b, b + down, ca, cb, cb, normals: (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0)))
                g.tri(a, b + down, a + down, ca, cb, ca, normals: (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0)))
            }}
        }
    }

    /// The pond: water reflecting the sky, a muddy shore, reeds with cattails, lily pads.
    static func pond(_ g: inout Geo) {
        let n = 64
        let centre = P(pondCenter.x, 0.05, pondCenter.y)
        let deep = C(0.17, 0.3, 0.38, 1), shallow = C(0.36, 0.5, 0.56, 1)
        let saveTag = g.tag
        g.tag = 0.75                          // water: ripples, reflection and glints in the simulator's shader
        defer { g.tag = saveTag }
        for i in 0..<n {
            let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
            func rim(_ a: Double, _ k: Double) -> P { P(pondCenter.x + cos(a) * pondRadius(a) * 1.35 * k, 0.05, pondCenter.y + sin(a) * pondRadius(a) * k) }
            let up = (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0))
            g.tri(centre, rim(a1, 0.7), rim(a0, 0.7), deep, deep, deep, normals: up)
            g.tri(rim(a0, 0.7), rim(a1, 0.7), rim(a1, 1.02), deep, deep, shallow, normals: up)
            g.tri(rim(a0, 0.7), rim(a1, 1.02), rim(a0, 1.02), deep, shallow, shallow, normals: up)
        }
        g.tag = saveTag
        // Reeds in clumps round the shore.
        for i in 0..<520 {
            let a = hash(i, 1, 101) * 2 * .pi
            guard noise(cos(a) * 3, sin(a) * 3, 102) > 0.45 else { continue }
            let k = 0.92 + hash(i, 2, 101) * 0.16
            let x = pondCenter.x + cos(a) * pondRadius(a) * 1.35 * k, z = pondCenter.y + sin(a) * pondRadius(a) * k
            let h = 1.0 + hash(i, 3, 101) * 1.0, lean = (hash(i, 4, 101) - 0.5) * 0.3
            let col = C(0.4 + Float(hash(i, 5, 101)) * 0.15, 0.48, 0.22, 1)
            let side = P(cos(a * 7), 0, sin(a * 7)) * 0.03
            g.tri(P(x, 0, z) - side, P(x, 0, z) + side, P(x + lean, h, z + lean * 0.5), col)
            if hash(i, 6, 101) < 0.3 {
                g.mesh(post(P(x + lean * 0.8, h * 0.75, z + lean * 0.4), radius: 0.035, height: 0.2, segments: 5), C(0.32, 0.2, 0.12, 1))
            }
        }
        // Lily pads.
        for i in 0..<30 {
            let a = hash(i, 1, 103) * 2 * .pi, k = 0.5 + hash(i, 2, 103) * 0.4
            let x = pondCenter.x + cos(a) * pondRadius(a) * 1.35 * k, z = pondCenter.y + sin(a) * pondRadius(a) * k
            let r = 0.3 + hash(i, 3, 103) * 0.25
            for j in 0..<7 {
                let b0 = Double(j) / 7 * 2 * .pi, b1 = Double(j + 1) / 7 * 2 * .pi
                g.tri(P(x, 0.07, z), P(x + cos(b1) * r, 0.07, z + sin(b1) * r), P(x + cos(b0) * r, 0.07, z + sin(b0) * r), C(0.22, 0.42, 0.18, 1))
            }
            if hash(i, 4, 103) < 0.3 { g.mesh(ellipsoid(P(x, 0.12, z), P(0.08, 0.06, 0.08), segments: 5, rings: 3), C(0.97, 0.9, 0.95, 1)) }
        }
    }

    /// The gravel track, fenced paddock and yard at the farm.
    static func trackAndYards(_ g: inout Geo) {
        let gravel = C(0.63, 0.57, 0.46, 1), verge = C(0.5, 0.5, 0.33, 1)
        for i in 0..<(track.count - 1) {
            let a = track[i], b = track[i + 1]
            let dir = simd_normalize(b - a), side = SIMD2(-dir.y, dir.x)
            func p(_ q: SIMD2<Double>, _ off: Double) -> P {
                let s = q + side * off
                let lift = cellSize(s.x, s.y) > 4 ? 0.12 : 0.03
                return P(s.x, surfaceHeight(s.x, s.y) + lift, s.y)
            }
            let shade = Float(0.93 + 0.1 * hash(i, 1, 111))
            g.quad(p(a, -1.8), p(b, -1.8), p(b, 1.8), p(a, 1.8), scale(gravel, shade))
            g.quad(p(a, -2.4), p(b, -2.4), p(b, -1.8), p(a, -1.8), verge)
            g.quad(p(a, 1.8), p(b, 1.8), p(b, 2.4), p(a, 2.4), verge)
            // Grass strip in the middle of the track.
            g.quad(p(a, -0.3), p(b, -0.3), p(b, 0.3), p(a, 0.3), C(0.42, 0.52, 0.27, 1))
        }
        // Paddock fence by the farm: posts and two rails.
        let wood = C(0.48, 0.37, 0.25, 1)
        let corners: [SIMD2<Double>] = [farm + [-20, -90], farm + [60, -90], farm + [60, -35], farm + [-20, -35]]
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let len = simd_length(b - a)
            let steps = Int(len / 3)
            for s in 0...steps {
                let q = a + (b - a) * (Double(s) / Double(steps))
                let y = surfaceHeight(q.x, q.y)
                g.mesh(block(P(q.x, y, q.y), 0.14, 1.3, 0.14), wood)
                if s < steps {
                    let q2 = a + (b - a) * (Double(s + 1) / Double(steps)), y2 = surfaceHeight(q2.x, q2.y)
                    for h in [0.6, 1.1] {
                        g.quad(P(q.x, y + h, q.y), P(q2.x, y2 + h, q2.y), P(q2.x, y2 + h + 0.12, q2.y), P(q.x, y + h + 0.12, q.y), scale(wood, 1.1))
                    }
                }
            }
        }
        // Cows in the paddock.
        for i in 0..<5 {
            let q = farm + [-10 + hash(i, 1, 121) * 60, -82 + hash(i, 2, 121) * 40]
            let y = surfaceHeight(q.x, q.y), yaw = hash(i, 3, 121) * 2 * .pi
            let hide = hash(i, 4, 121) < 0.5 ? C(0.15, 0.12, 0.1, 1) : C(0.55, 0.36, 0.22, 1)
            g.mesh(block(P(q.x, y + 0.75, q.y), 0.75, 0.8, 1.9, yaw: yaw), hide)
            g.mesh(block(P(q.x + sin(yaw) * 1.15, y + 1.0, q.y + cos(yaw) * 1.15), 0.4, 0.45, 0.55, yaw: yaw), hide)
            for (lx, lz) in [(-0.25, -0.7), (0.25, -0.7), (-0.25, 0.7), (0.25, 0.7)] {
                let o = P(lx * cos(yaw) + lz * sin(yaw), 0, -lx * sin(yaw) + lz * cos(yaw))
                g.mesh(block(P(q.x, y, q.y) + o, 0.14, 0.78, 0.14, yaw: yaw), scale(hide, 0.8))
            }
        }
    }

    /// Mown strip: alternating stripes, a darker border, distance cones, a flight-line rope.
    static func strip(_ g: inout Geo) {
        let light = C(0.5, 0.7, 0.33, 1), dark = C(0.4, 0.6, 0.27, 1)
        var k = 0
        let up = (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0))
        for x in stride(from: -10.5, to: 10.5, by: 2.1) {
            let c = k % 2 == 0 ? light : dark
            let a = P(x, 0.012, -95), b = P(x + 2.1, 0.012, -95), cc = P(x + 2.1, 0.012, 14), d = P(x, 0.012, 14)
            g.tri(a, cc, b, c, c, c, normals: up); g.tri(a, d, cc, c, c, c, normals: up)
            k += 1
        }
        // Centre line of slightly longer grass, markers at the ends.
        for z in [-25.0, -50.0, -75.0, -95.0] {
            for x in [-11.0, 11.0] { g.mesh(cone(P(x, 0, z), radius: 0.18, height: 0.42, segments: 8), C(1, 0.45, 0.08, 1)) }
        }
    }

    /// Grass tufts and wild flowers near the pilot; flowers further out as dots.
    static func grassAndFlowers(_ g: inout Geo) {
        let up = (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0))
        func onStrip(_ x: Double, _ z: Double) -> Bool { abs(x) < 10.5 && z > -95 && z < 14 }
        func blade(_ x: Double, _ y: Double, _ z: Double, h: Double, width: Double, dir: Double, lean: P, base: C) {
            let tip = C(min(base.x * 1.15 + 0.06, 1), min(base.y * 1.18 + 0.06, 1), base.z * 1.05, 1)
            let side = P(cos(dir), 0, sin(dir)) * (width / 2)
            g.tri(P(x, y, z) - side, P(x, y, z) + side, P(x, y + h, z) + lean, scale(base, 0.72), scale(base, 0.72), tip, normals: up)
        }
        // Meadow: tufts of 3–5 blades, denser close to the pilot, out to 120 m. Lush and tall in patches, short and
        // dry where people walk (round the pits, along the track).
        for i in 0..<70000 {
            let a = hash(i, 1, 131) * 2 * .pi, r = 2 + pow(hash(i, 2, 131), 0.75) * 118
            let x = cos(a) * r, z = sin(a) * r
            if onStrip(x, z) || pondDistance(x, z) < 1.1 { continue }
            let track = trackDistance(x, z)
            if track < 2.5 { continue }
            let lush = fbm(x / 9, z / 9, 132)
            let worn = min(1, track / 8) * min(1, hypot(x + 9, z - 6) / 12)
            let h0 = (0.1 + 0.32 * lush * lush + hash(i, 3, 131) * 0.12) * (0.45 + 0.55 * worn)
            let base = rgb(groundColor(x, z) * (0.92 + 0.16 * hash(i, 6, 131)))
            let blades = 3 + Int(hash(i, 7, 131) * 3)
            for k in 0..<blades {
                let ox = (hash(i, 10 + k, 131) - 0.5) * 0.12, oz = (hash(i, 20 + k, 131) - 0.5) * 0.12
                let h = h0 * (0.7 + 0.5 * hash(i, 30 + k, 131))
                let lean = P(hash(i, 40 + k, 131) - 0.5, 0, hash(i, 50 + k, 131) - 0.5) * h * 0.7
                blade(x + ox, 0, z + oz, h: h, width: 0.035 + 0.02 * hash(i, 60 + k, 131), dir: a * 13 + Double(k), lean: lean, base: base)
            }
        }
        // The mown strip: short cut grass in the stripe colours.
        for i in 0..<45000 {
            let x = (hash(i, 1, 141) - 0.5) * 21, z = -95 + hash(i, 2, 141) * 109
            let stripe = Int(floor((x + 10.5) / 2.1)) % 2 == 0
            let base = stripe ? C(0.5, 0.7, 0.33, 1) : C(0.4, 0.6, 0.27, 1)
            let h = 0.035 + hash(i, 3, 141) * 0.035
            blade(x, 0.012, z, h: h, width: 0.03, dir: hash(i, 4, 141) * 6.3, lean: P(hash(i, 5, 141) - 0.5, 0, hash(i, 6, 141) - 0.5) * h * 0.5,
                  base: scale(base, Float(0.92 + 0.16 * hash(i, 7, 141))))
        }
        // Further out (120–300 m): wider clumps – thin blades would only flicker at that distance.
        for i in 0..<26000 {
            let a = hash(i, 1, 151) * 2 * .pi, r = 120 + hash(i, 2, 151) * 180
            let x = cos(a) * r, z = sin(a) * r
            if pondDistance(x, z) < 1.1 || trackDistance(x, z) < 3 || !free(x, z, margin: -30) && hypot(x, z) < 40 { continue }
            let lush = fbm(x / 12, z / 12, 152)
            let h = 0.25 + 0.4 * lush * lush
            let base = rgb(groundColor(x, z) * (0.88 + 0.2 * hash(i, 3, 151)))
            let y = surfaceHeight(x, z)
            for k in 0..<2 {
                blade(x, y, z, h: h, width: 0.35 + 0.25 * hash(i, 4 + k, 151), dir: a + Double(k) * 1.6, lean: P(0.1, 0, 0.05) * h, base: base)
            }
        }
        let colors: [C] = [[0.97, 0.97, 0.92, 1], [0.98, 0.85, 0.15, 1], [0.66, 0.42, 0.9, 1], [0.95, 0.32, 0.28, 1], [0.35, 0.5, 0.95, 1]]
        for i in 0..<9000 {
            let x = (hash(i, 1, 31) - 0.5) * 420, z = (hash(i, 2, 31) - 0.5) * 420
            if abs(x) < 11, z > -96, z < 15 { continue }
            if fbm(x / 22, z / 22, 7) < 0.47 || pondDistance(x, z) < 1.15 || trackDistance(x, z) < 2.5 { continue }
            let near = (x * x + z * z) < 70 * 70
            let stem = near ? 0.2 + hash(i, 5, 31) * 0.2 : 0.06
            let y = surfaceHeight(x, z) + stem, r = (near ? 0.05 : 0.09) + hash(i, 3, 31) * 0.05
            let c = colors[Int(hash(i, 4, 31) * Double(colors.count)) % colors.count]
            if near { g.tri(P(x - 0.01, y - stem, z), P(x + 0.01, y - stem, z), P(x, y, z), C(0.3, 0.5, 0.2, 1), C(0.3, 0.5, 0.2, 1), C(0.3, 0.5, 0.2, 1), normals: up) }
            g.tri(P(x - r, y, z - r * 0.6), P(x + r, y, z - r * 0.6), P(x, y, z + r * 1.1), c, c, c, normals: up)
        }
    }

    /// All trees and bushes of the layout, with blob shadows under them.
    static func trees(_ g: inout Geo) {
        let up = (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0))
        // (soft discs under trees – only where the sun shadow map does not reach, beyond the field)
        func shadow(_ x: Double, _ z: Double, _ r: Double) {
            guard max(abs(x - 0), abs(z + 60)) > 300 else { return }
            // Offset away from the sun, a soft dark disc just above the ground.
            let cx = x - sunDir.x * r * 0.6, cz = z - sunDir.z * r * 0.6
            let inner = C(0.06, 0.12, 0.04, 0.42), outer = C(0.06, 0.12, 0.04, 0)
            let y = surfaceHeight(cx, cz) + (cellSize(cx, cz) > 4 ? 0.15 : 0.03)
            for j in 0..<10 {
                let a0 = Double(j) / 10 * 2 * .pi, a1 = Double(j + 1) / 10 * 2 * .pi
                g.tri(P(cx, y, cz), P(cx + cos(a1) * r, y, cz + sin(a1) * r * 0.85), P(cx + cos(a0) * r, y, cz + sin(a0) * r * 0.85), inner, outer, outer, normals: up)
            }
        }
        for t in layout.trees {
            let x = t.x, z = t.z, y = t.y - 0.2, h = t.h, s = t.seed
            let v = Float(hash(s, 7, 41))
            switch t.kind {
            case .conifer:
                shadow(x, z, h * 0.28)
                g.mesh(post(P(x, y, z), radius: 0.22, height: h * 0.3), C(0.33, 0.24, 0.17, 1))
                let col = C(0.1 + v * 0.05, 0.26 + v * 0.09, 0.15, 1)
                for k in 0..<4 {
                    let f = Double(k) / 4
                    let base = P(x, y + h * (0.15 + 0.22 * f), z)
                    g.mesh(cone(base, radius: h * (0.27 - 0.06 * f), height: h * (0.42 - 0.04 * f), segments: 9), col) { p in
                        Float(0.7 + 0.45 * min(max((p.y - base.y) / (h * 0.4), 0), 1))
                    }
                }
            case .poplar:
                shadow(x, z, h * 0.14)
                g.mesh(post(P(x, y, z), radius: 0.25, height: h * 0.2), C(0.38, 0.3, 0.22, 1))
                let col = C(0.24 + v * 0.06, 0.42 + v * 0.08, 0.17, 1)
                let c = P(x, y + h * 0.55, z)
                g.mesh(ellipsoid(c, P(h * 0.12, h * 0.46, h * 0.12), segments: 8, rings: 7), col) { p in Float(0.75 + 0.35 * (p.y - c.y + h * 0.46) / (h * 0.92)) }
            case .birch:
                shadow(x, z, h * 0.22)
                g.mesh(post(P(x, y, z), radius: 0.16, height: h * 0.7), C(0.88, 0.87, 0.82, 1))
                for k in 0..<3 {
                    let ox = (hash(s, 10 + k, 41) - 0.5) * h * 0.25, oz = (hash(s, 20 + k, 41) - 0.5) * h * 0.25
                    let c = P(x + ox, y + h * (0.6 + 0.12 * Double(k)), z + oz), rr = h * 0.16
                    g.mesh(ellipsoid(c, P(rr, rr * 1.2, rr), segments: 7, rings: 5), C(0.42 + v * 0.08, 0.58, 0.24, 1)) { p in Float(0.75 + 0.3 * (p.y - c.y + rr) / (2 * rr)) }
                }
            case .broadleaf:
                shadow(x, z, h * 0.32)
                g.mesh(post(P(x, y, z), radius: 0.3 + h * 0.012, height: h * 0.5), C(0.36, 0.26, 0.18, 1))
                let col = C(0.2 + v * 0.1, 0.38 + v * 0.14, 0.15 + v * 0.04, 1)
                for k in 0..<5 {
                    let ox = (hash(s, 10 + k, 41) - 0.5) * h * 0.38, oz = (hash(s, 20 + k, 41) - 0.5) * h * 0.38
                    let oy = h * (0.5 + hash(s, 30 + k, 41) * 0.3), rr = h * (0.18 + hash(s, 40 + k, 41) * 0.1)
                    let c = P(x + ox, y + oy, z + oz)
                    let top = y + h
                    g.mesh(ellipsoid(c, P(rr, rr * 0.85, rr), segments: 8, rings: 5), col) { p in
                        Float(0.62 + 0.5 * min(max((p.y - (y + h * 0.35)) / (top - y - h * 0.35), 0), 1))
                    }
                }
            }
        }
        for b in layout.bushes + layout.hedges {
            shadow(b.x, b.z, b.r * 1.2)
            let y = surfaceHeight(b.x, b.z)
            let v = Float(hash(Int(b.x * 7), Int(b.z * 7), 141))
            let c = P(b.x, y + b.r * 0.55, b.z)
            g.mesh(ellipsoid(c, P(b.r * 1.25, b.r * 0.8, b.r), segments: 7, rings: 4), C(0.18 + v * 0.06, 0.34 + v * 0.1, 0.14, 1)) { p in
                Float(0.65 + 0.45 * (p.y - y) / (b.r * 1.35))
            }
        }
    }

    /// Dense woods on the distant hills, drawn cheaply: each tree a low-poly cone (conifer) or a faceted ball on a
    /// stub (broadleaf), a few dozen triangles – thousands of them cost less than a hundred near trees.
    static func farForests(_ g: inout Geo) {
        for w in 0..<22 {
            let a = hash(w, 1, 201) * 2 * .pi, r = 800 + hash(w, 2, 201) * 1800
            let cx = cos(a) * r, cz = sin(a) * r
            let centre = SIMD2(cx, cz)
            if simd_length(centre - village) < 400 || simd_length(centre - hamlet) < 300 || simd_length(centre - farm) < 200 || simd_length(centre - farm2) < 200 { continue }
            let size = 90 + hash(w, 3, 201) * 160
            let conifer = hash(w, 4, 201)
            let count = Int(size * size / 260)
            for t in 0..<count {
                let ang = hash(t, w, 202) * 2 * .pi, rad = hash(t, w, 203).squareRoot() * size
                // an irregular edge
                if rad > size * (0.75 + 0.25 * noise(cos(ang) * 2 + Double(w), sin(ang) * 2, 204)) { continue }
                let x = cx + cos(ang) * rad * 1.3, z = cz + sin(ang) * rad
                let y = surfaceHeight(x, z) - 0.5, h = 10 + hash(t, w, 205) * 10
                let v = Float(hash(t, w, 206))
                if hash(t, w, 207) < conifer {
                    g.mesh(cone(P(x, y, z), radius: h * 0.26, height: h, segments: 5), C(0.1 + v * 0.05, 0.25 + v * 0.08, 0.14, 1))
                } else {
                    g.mesh(ellipsoid(P(x, y + h * 0.62, z), P(h * 0.32, h * 0.3, h * 0.32), segments: 5, rings: 3), C(0.19 + v * 0.08, 0.36 + v * 0.1, 0.15, 1))
                    g.mesh(post(P(x, y, z), radius: 0.4, height: h * 0.35, segments: 4), C(0.32, 0.24, 0.17, 1))
                }
            }
        }
    }

    /// A hamlet: houses round a crossing of two lanes, varied walls, roofs and sizes, chimneys, garden hedges, trees.
    static func settlement(_ g: inout Geo, at centre: SIMD2<Double>, houses: Int, seed: Int, church: Bool) {
        let walls: [C] = [C(0.92, 0.9, 0.84, 1), C(0.9, 0.84, 0.7, 1), C(0.86, 0.76, 0.62, 1), C(0.8, 0.82, 0.78, 1), C(0.78, 0.66, 0.52, 1), C(0.94, 0.88, 0.78, 1)]
        let roofs: [C] = [C(0.66, 0.24, 0.17, 1), C(0.58, 0.2, 0.14, 1), C(0.42, 0.28, 0.2, 1), C(0.34, 0.34, 0.38, 1), C(0.72, 0.36, 0.22, 1)]
        let lane = hash(seed, 9, 211) * .pi                          // direction of the main lane
        let dir = SIMD2(cos(lane), sin(lane)), across = SIMD2(-dir.y, dir.x)
        // the lanes (gravel strips)
        for (d, len) in [(dir, 150.0), (across, 90.0)] {
            var t = -len
            while t < len {
                let a = centre + d * t, b = centre + d * (t + 6), sideV = SIMD2(-d.y, d.x) * 2.6
                func p(_ q: SIMD2<Double>) -> P { P(q.x, surfaceHeight(q.x, q.y) + 0.15, q.y) }
                g.quad(p(a - sideV), p(b - sideV), p(b + sideV), p(a + sideV), C(0.6, 0.56, 0.48, 1))
                t += 6
            }
        }
        for i in 0..<houses {
            let onMain = i % 3 != 2
            let d = onMain ? dir : across, n = SIMD2(-d.y, d.x)
            let along = (hash(i, seed, 212) - 0.5) * (onMain ? 280 : 160)
            let side: Double = hash(i, seed, 213) < 0.5 ? 1 : -1
            let q = centre + d * along + n * side * (12 + hash(i, seed, 214) * 10)
            if simd_length(q - centre) < 14 { continue }
            let w = 8 + hash(i, seed, 215) * 7, dd = 7 + hash(i, seed, 216) * 4, h = 5 + hash(i, seed, 217) * 3.5
            let yaw = atan2(d.x, d.y) + (side > 0 ? 0 : .pi) + (hash(i, seed, 218) - 0.5) * 0.15
            house(&g, at: q, w: w, d: dd, h: h, roofH: 3 + hash(i, seed, 219) * 2.5, yaw: yaw,
                  wall: walls[Int(hash(i, seed, 220) * Double(walls.count)) % walls.count], roof: roofs[Int(hash(i, seed, 221) * Double(roofs.count)) % roofs.count])
            // chimney
            let y0 = surfaceHeight(q.x, q.y)
            let off = P(cos(-yaw) * w * 0.25, 0, sin(-yaw) * w * 0.25)
            g.mesh(block(P(q.x, y0, q.y) + off, 0.8, h + 0.6 + 3.2, 0.8, yaw: yaw), C(0.5, 0.36, 0.3, 1))
            // garden hedge behind the house, a tree in some gardens
            let back = q + n * side * (dd / 2 + 6)
            for k in -3...3 {
                let hp = back + d * (Double(k) * 2.2)
                g.mesh(ellipsoid(P(hp.x, surfaceHeight(hp.x, hp.y) + 0.6, hp.y), P(1.3, 0.9, 1.2), segments: 5, rings: 3), C(0.2, 0.36, 0.15, 1))
            }
            if hash(i, seed, 222) < 0.5 {
                let tp = back + n * side * 5 + d * ((hash(i, seed, 223) - 0.5) * 8)
                let ty = surfaceHeight(tp.x, tp.y), th = 7 + hash(i, seed, 224) * 6
                g.mesh(post(P(tp.x, ty, tp.y), radius: 0.3, height: th * 0.45, segments: 5), C(0.36, 0.26, 0.18, 1))
                g.mesh(ellipsoid(P(tp.x, ty + th * 0.68, tp.y), P(th * 0.3, th * 0.27, th * 0.3), segments: 6, rings: 4), C(0.22 + Float(hash(i, seed, 225)) * 0.08, 0.42, 0.17, 1))
            }
        }
        if church {
            let ch = centre + across * 22 + dir * 10
            let yaw = atan2(dir.x, dir.y)
            house(&g, at: ch, w: 12, d: 24, h: 10, roofH: 6, yaw: yaw + .pi / 2, wall: walls[0], roof: C(0.36, 0.36, 0.4, 1))
            let tower = ch + dir * 16
            let ty = surfaceHeight(tower.x, tower.y) - 0.5
            g.mesh(block(P(tower.x, ty, tower.y), 5, 24, 5, yaw: yaw), walls[0])
            g.mesh(cone(P(tower.x, ty + 24, tower.y), radius: 3.6, height: 14, segments: 8), C(0.3, 0.42, 0.36, 1))
        }
    }

    /// The farm (house, barn, silo), a second farm, the village with its church.
    static func buildings(_ g: inout Geo) {
        let white = C(0.92, 0.9, 0.84, 1), cream = C(0.9, 0.84, 0.7, 1), red = C(0.66, 0.24, 0.17, 1), brown = C(0.42, 0.28, 0.2, 1)
        house(&g, at: farm, w: 12, d: 9, h: 6, roofH: 4, yaw: 0.6, wall: white, roof: red)
        house(&g, at: farm + [26, 14], w: 22, d: 13, h: 6.5, roofH: 5, yaw: 0.6, wall: C(0.55, 0.32, 0.22, 1), roof: C(0.3, 0.3, 0.32, 1))
        let silo = farm + [8, 34]
        let sy = surfaceHeight(silo.x, silo.y) - 0.5
        g.mesh(post(P(silo.x, sy, silo.y), radius: 3, height: 13, segments: 14), C(0.78, 0.8, 0.82, 1))
        g.mesh(ellipsoid(P(silo.x, sy + 13, silo.y), P(3, 1.8, 3), segments: 14, rings: 6), C(0.55, 0.58, 0.62, 1))
        // Hay bales.
        for i in 0..<8 {
            let q = farm + [-30 + Double(i % 4) * 3.2, 30 + Double(i / 4) * 3.2]
            let y = surfaceHeight(q.x, q.y)
            g.mesh(SceneBuilder.cylinder(center: .zero, radius: 0.75, length: 1.2, segments: 12).translated(P(q.x, y + 0.75, q.y)), C(0.85, 0.74, 0.42, 1))
        }
        house(&g, at: farm2, w: 11, d: 9, h: 6, roofH: 3.6, yaw: -0.3, wall: cream, roof: brown)
        house(&g, at: farm2 + [18, -16], w: 18, d: 11, h: 6, roofH: 4.5, yaw: -0.3, wall: C(0.6, 0.45, 0.3, 1), roof: C(0.33, 0.33, 0.35, 1))
        // The village (with its church) and a hamlet.
        settlement(&g, at: village, houses: 40, seed: 1, church: true)
        settlement(&g, at: hamlet, houses: 14, seed: 2, church: false)
    }

    /// The pits behind the flight line: a gazebo, folding chairs, a table, flight boxes, a car, the fence, a windsock.
    static func pits(_ g: inout Geo) {
        let wood = C(0.55, 0.42, 0.28, 1), metal = C(0.32, 0.32, 0.34, 1)
        for x in stride(from: -14.0, through: 14.0, by: 3.5) { g.mesh(post(P(x, 0, 4), radius: 0.05, height: 1.0), wood) }
        g.mesh(.box(min: [-14, 0.85, 3.98], max: [14, 0.88, 4.02]), C(0.95, 0.85, 0.2, 1))
        // Gazebo: four legs, a pyramid roof in two colours, a valance.
        let gc = P(-9, 0, 6), s = 1.5
        for (dx, dz) in [(-s, -s), (s, -s), (s, s), (-s, s)] { g.mesh(post(gc + P(dx, 0, dz), radius: 0.035, height: 2.1), C(0.85, 0.85, 0.87, 1)) }
        let apex = gc + P(0, 2.75, 0)
        let corners = [gc + P(-s - 0.1, 2.1, -s - 0.1), gc + P(s + 0.1, 2.1, -s - 0.1), gc + P(s + 0.1, 2.1, s + 0.1), gc + P(-s - 0.1, 2.1, s + 0.1)]
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            g.tri(a, apex, b, k % 2 == 0 ? C(0.15, 0.35, 0.75, 1) : C(0.95, 0.95, 0.95, 1))
            g.quad(a, b, b - P(0, 0.25, 0), a - P(0, 0.25, 0), C(0.15, 0.35, 0.75, 1))
        }
        // Table under the gazebo, flight boxes, chairs.
        g.mesh(.box(min: [-10, 0.72, 5.5], max: [-8, 0.76, 6.4]), C(0.92, 0.92, 0.9, 1))
        for (dx, dz) in [(-9.9, 5.6), (-8.1, 5.6), (-9.9, 6.3), (-8.1, 6.3)] { g.mesh(post(P(dx, 0, dz), radius: 0.02, height: 0.72, segments: 5), metal) }
        g.mesh(.box(min: [-9.7, 0.76, 5.7], max: [-9.1, 1.0, 6.0]), C(0.85, 0.3, 0.15, 1))
        g.mesh(.box(min: [-8.8, 0.76, 5.7], max: [-8.4, 0.92, 6.2]), C(0.2, 0.2, 0.22, 1))
        for (cx, cz, yaw) in [(-10.6, 7.0, 0.4), (-7.4, 7.2, -0.5), (-4.5, 3.0, 0.1)] {
            let c = P(cx, 0, cz)
            g.mesh(block(c + P(0, 0.42, 0), 0.5, 0.05, 0.45, yaw: yaw), C(0.2, 0.45, 0.25, 1))
            g.mesh(block(c + P(sin(yaw) * 0.23, 0.45, cos(yaw) * 0.23), 0.5, 0.5, 0.04, yaw: yaw), C(0.2, 0.45, 0.25, 1))
            for (lx, lz) in [(-0.22, -0.2), (0.22, -0.2), (-0.22, 0.2), (0.22, 0.2)] {
                g.mesh(post(c + P(lx * cos(yaw) + lz * sin(yaw), 0, -lx * sin(yaw) + lz * cos(yaw)), radius: 0.015, height: 0.42, segments: 4), metal)
            }
        }
        // A car parked behind the pits.
        let car = P(-17, 0, 10), yaw = 0.25
        g.mesh(block(car + P(0, 0.3, 0), 1.8, 0.65, 4.3, yaw: yaw), C(0.2, 0.32, 0.55, 1))
        g.mesh(block(car + P(sin(yaw) * 0.3, 0.95, cos(yaw) * 0.3), 1.6, 0.55, 2.3, yaw: yaw), C(0.25, 0.3, 0.38, 1))
        for (lx, lz) in [(-0.9, -1.4), (0.9, -1.4), (-0.9, 1.4), (0.9, 1.4)] {
            let o = P(lx * cos(yaw) + lz * sin(yaw), 0.33, -lx * sin(yaw) + lz * cos(yaw))
            g.mesh(SceneBuilder.cylinder(center: .zero, radius: 0.33, length: 0.22, segments: 10).rotated(.pi / 2, axis: [0, 1, 0]).rotated(yaw, axis: [0, 1, 0]).translated(car + o), C(0.1, 0.1, 0.1, 1))
        }
        // Windsock on a pole, pointing downwind (a breeze from the right).
        g.mesh(post(P(12, 0, -8), radius: 0.04, height: 4.2), C(0.8, 0.8, 0.82, 1))
        for k in 0..<4 {
            let r0 = 0.28 - Double(k) * 0.05, x0 = 12 - Double(k) * 0.35
            g.mesh(SceneBuilder.cylinder(center: .zero, radius: r0, length: 0.35, segments: 10).rotated(.pi / 2, axis: [0, 1, 0]).translated([x0 - 0.18, 4.05 - Double(k) * 0.05, -8]),
                   k % 2 == 0 ? C(1, 0.4, 0.05, 1) : C(0.97, 0.97, 0.97, 1))
        }
    }

    /// Wooded ridges at ~1.7 km, a mountain range at ~3 km with snow caps, a paler range behind at ~4.6 km.
    static func ridgesAndMountains(_ g: inout Geo) {
        func ring(r: Double, depth: Double, n: Int, color: C, snowAbove: Double?, peak: (Double) -> Double) {
            for i in 0..<n {
                let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
                let p0 = peak(a0), p1 = peak(a1)
                let b0 = P(cos(a0) * r, -12, sin(a0) * r), b1 = P(cos(a1) * r, -12, sin(a1) * r)
                let t0 = P(cos(a0) * (r + depth), p0, sin(a0) * (r + depth)), t1 = P(cos(a1) * (r + depth), p1, sin(a1) * (r + depth))
                let shade = Float(0.88 + 0.22 * hash(i, Int(r), 83))
                let lo = scale(color, shade * 0.8), hi = scale(color, shade * 1.08)
                g.tri(b0, t0, b1, lo, hi, lo)
                g.tri(b1, t0, t1, lo, hi, hi)
                if let snow = snowAbove, max(p0, p1) > snow {
                    func down(_ t: P, _ b: P, _ h: Double) -> P { t + (b - t) * (min(max((h - snow) / max(h + 12, 1), 0), 0.6) * 0.6) }
                    let c = C(0.95, 0.96, 0.99, 1)
                    // Lifted off the slope (towards the pilot and up), so it never shares the slope's plane.
                    func lift(_ q: P) -> P { let k = r * 0.004; return q - simd_normalize(P(q.x, 0, q.z)) * k + P(0, k * 0.5, 0) }
                    let d0 = lift(down(t0, b0, p0)), d1 = lift(down(t1, b1, p1))
                    let t0 = lift(t0), t1 = lift(t1)
                    g.tri(d0, t0, d1, scale(c, 0.9), c, scale(c, 0.9))
                    g.tri(d1, t0, t1, scale(c, 0.9), c, c)
                }
            }
        }
        ring(r: 1700, depth: 120, n: 200, color: C(0.19, 0.31, 0.19, 1), snowAbove: nil) { a in
            40 + fbm(a * 5, 2.3, 87) * 160 + noise(a * 40, 0.3, 88) * 18
        }
        ring(r: 3000, depth: 220, n: 360, color: C(0.33, 0.39, 0.48, 1), snowAbove: 420) { a in
            let big = fbm(a * 4, 0.7, 81, octaves: 3)
            let ridge = 1 - abs(noise(a * 22, 1.1, 82) * 2 - 1)
            return 80 + big * big * 760 + ridge * 130 * big
        }
        ring(r: 4600, depth: 300, n: 300, color: C(0.5, 0.56, 0.66, 1), snowAbove: 650) { a in
            let big = fbm(a * 3 + 5, 0.2, 91, octaves: 3)
            let ridge = 1 - abs(noise(a * 18, 2.1, 92) * 2 - 1)
            return 200 + big * big * 1100 + ridge * 160 * big
        }
    }

    /// Fair-weather cumulus at 300–550 m: puffs with flat, slightly grey bases, baked (unlit) shading.
    static func clouds(_ g: inout Geo) {
        let saveTag = g.tag
        g.tag = 0
        for k in 0..<48 {
            let x = (hash(k, 1, 91) - 0.5) * 4400, z = (hash(k, 2, 91) - 0.5) * 4400, base = 300 + hash(k, 3, 91) * 250
            let size = 45 + hash(k, 4, 91) * 95
            for p in 0..<9 {
                let ox = (hash(k, 10 + p, 91) - 0.5) * size * 1.8, oz = (hash(k, 20 + p, 91) - 0.5) * size * 1.1
                let central = 1 - min(abs(ox) / (size * 0.9), 1)
                let r = size * (0.35 + hash(k, 40 + p, 91) * 0.3) * (0.6 + 0.4 * central)
                let c = P(x + ox, base + r * 0.25 + central * size * 0.2, z + oz)
                // Flat base, a little different for every puff (coplanar bases of overlapping puffs flicker).
                let pBase = base + Double(p) * 0.9
                let m = ellipsoid(c, P(r, r * 0.62, r * 0.85), segments: 10, rings: 6).transformed { q in P(q.x, max(q.y, pBase), q.z) }
                for t in m.triangles {
                    func col(_ q: P) -> C {
                        let rad = simd_normalize(q - c)
                        let sun = Float(max(simd_dot(rad, sunDir), 0)), up = Float(rad.y)
                        let flatBase = q.y < pBase + 0.5
                        var k = 0.8 + 0.13 * up + 0.12 * sun
                        if flatBase { k = 0.74 }
                        let blue: Float = flatBase ? 0.04 : 0
                        return C(min(k, 1), min(k + blue * 0.3, 1), min(k + blue, 1), 1)
                    }
                    g.tri(t.0, t.1, t.2, col(t.0), col(t.1), col(t.2), normals: (P(0, 1, 0), P(0, 1, 0), P(0, 1, 0)))
                }
            }
        }
        g.tag = saveTag
    }

    /// Birds circling in three flocks: moving groups turned about a vertical axis (angle = time × rate).
    static let birdFlocks: [(center: P, radius: Double, count: Int, rate: Float, size: Double)] = [
        ([70, 48, -170], 28, 6, 0.32, 0.9),
        ([-160, 75, -40], 40, 4, -0.22, 1.1),
        ([20, 140, -320], 55, 1, 0.12, 1.8),     // a buzzard, high up
    ]
    static var birdGroups: [SceneData.Group] {
        birdFlocks.map { f in SceneData.Group(kind: .prop, center: SIMD3<Float>(f.center), axis: [0, 1, 0], sense: f.rate) }
    }
    static func birds(_ g: inout Geo) {
        let saveTag = g.tag
        for (k, f) in birdFlocks.enumerated() {
            g.tag = Float(2 + k)
            for i in 0..<f.count {
                let a = Double(i) / Double(f.count) * 2 * .pi + hash(i, k, 171)
                let rr = f.radius * (0.8 + hash(i, k, 172) * 0.4)
                let p = f.center + P(cos(a) * rr, (hash(i, k, 173) - 0.5) * 8, sin(a) * rr)
                // Flying along the circle (the direction the group turns), wings in a shallow V.
                var fwd = simd_normalize(P(p.z - f.center.z, 0, -(p.x - f.center.x)))
                if f.rate < 0 { fwd = -fwd }
                let right = simd_normalize(simd_cross(fwd, P(0, 1, 0)))
                let s = f.size
                let nose = p + fwd * 0.3 * s, tail = p - fwd * 0.25 * s
                let tipL = p - right * s + P(0, 0.18 * s, 0) - fwd * 0.15 * s, tipR = p + right * s + P(0, 0.18 * s, 0) - fwd * 0.15 * s
                let col = C(0.12, 0.11, 0.12, 1)
                g.tri(nose, tail, tipL, col); g.tri(nose, tipR, tail, col)
            }
        }
        g.tag = saveTag
    }

    /// Sky dome around the eye: horizon haze up to deep blue, a glow round the sun and the sun's disc.
    static func sky() -> SceneData {
        var g = Geo()
        g.tag = 0
        let rings = 18, segs = 48, R = 6000.0
        func dir(_ i: Int, _ j: Int) -> P {
            let t = Double(i) / Double(rings)
            let el = -0.2 + (t * t * 0.6 + t * 0.4) * (.pi / 2 + 0.2), az = Double(j) / Double(segs) * 2 * .pi
            return P(cos(el) * cos(az), sin(el), cos(el) * sin(az))
        }
        func col(_ d: P) -> C {
            let t = Float(min(max(d.y, 0), 1))
            let k = pow(t, 0.5)
            var c = horizon * (1 - k) + zenith * k
            let sun = Float(max(simd_dot(d, sunDir), 0))
            c += C(1, 0.9, 0.7, 0) * (pow(sun, 48) * 0.6 + pow(sun, 6) * 0.14)
            if d.y < 0 { c = horizon * 0.97 }
            c.w = 1
            return c
        }
        for i in 0..<rings { for j in 0..<segs {
            let a = dir(i, j), b = dir(i, j + 1), c = dir(i + 1, j + 1), d = dir(i + 1, j)
            g.tri(a * R, b * R, c * R, col(a), col(b), col(c))
            g.tri(a * R, c * R, d * R, col(a), col(c), col(d))
        }}
        // Sun disc.
        let sc = sunDir * (R * 0.98)
        let u = simd_normalize(simd_cross(sunDir, P(0, 1, 0))), v = simd_cross(u, sunDir)
        let rad = R * 0.012
        for j in 0..<24 {
            let a0 = Double(j) / 24 * 2 * .pi, a1 = Double(j + 1) / 24 * 2 * .pi
            g.tri(sc, sc + (u * cos(a0) + v * sin(a0)) * rad, sc + (u * cos(a1) + v * sin(a1)) * rad, C(1, 1, 0.94, 1), C(1, 0.97, 0.86, 1), C(1, 0.97, 0.86, 1))
        }
        var s = g.scene
        s.label = "Sky"
        return s
    }
}
