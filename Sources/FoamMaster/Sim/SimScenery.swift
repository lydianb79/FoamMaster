import Foundation
import simd

/// The flying site of the simulator (metres, y up, the pilot at the origin looking along −z): rolling terrain with
/// noise-coloured grass and patchwork fields, a mown strip with stripes, flowers, tree lines and woods, bushes, hills
/// and a mountain ring in the haze, clouds, the flight line (fence, table, windsock) – plus a separate sky dome.
enum SimScenery {
    static let horizon = SIMD4<Float>(0.74, 0.83, 0.93, 1)
    static let zenith = SIMD4<Float>(0.28, 0.5, 0.86, 1)
    static let sunDir = simd_normalize(SIMD3<Double>(0.35, 0.75, 0.3))

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
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }
    static func fbm(_ x: Double, _ y: Double, _ seed: Int = 0, octaves: Int = 4) -> Double {
        var s = 0.0, amp = 0.5, f = 1.0
        for o in 0..<octaves { s += amp * noise(x * f, y * f, seed + o * 17); amp *= 0.5; f *= 2.03 }
        return s
    }

    /// Ground height: flat around the field (r < 220 m), rolling hills further out.
    static func height(_ x: Double, _ z: Double) -> Double {
        let r = (x * x + z * z).squareRoot()
        let ramp = min(max((r - 220) / 500, 0), 1)
        let hills = (fbm(x / 380, z / 380, 3) - 0.35) * 70
        return max(hills, -4) * ramp * ramp
    }

    /// Grass colour at a point: patchy meadow, patchwork crops further out.
    static func groundColor(_ x: Double, _ z: Double) -> SIMD4<Float> {
        let r = (x * x + z * z).squareRoot()
        let n = fbm(x / 35, z / 35, 1), n2 = noise(x / 6, z / 6, 9)
        var c = SIMD3<Double>(0.30, 0.50, 0.21) * (0.85 + 0.3 * n) + SIMD3(0.04, 0.03, -0.02) * n2
        if fbm(x / 90, z / 90, 5) > 0.62 { c = c * 0.85 + SIMD3(0.12, 0.10, 0.02) }        // drier patches
        if r > 320 {
            // Fields: 140 m plots of wheat, ploughed earth, rapeseed, pasture.
            let px = Int(floor((x + 7) / 140)), pz = Int(floor((z - 11) / 120))
            let k = hash(px, pz, 21)
            let crop: SIMD3<Double>? = k < 0.18 ? [0.78, 0.68, 0.36] : k < 0.3 ? [0.46, 0.34, 0.22] : k < 0.38 ? [0.86, 0.80, 0.22] : k < 0.5 ? [0.38, 0.56, 0.24] : nil
            if let crop {
                let t = min((r - 320) / 80, 1)
                c = c * (1 - t) + (crop * (0.9 + 0.2 * n2)) * t
            }
        }
        return SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
    }

    // MARK: Building blocks

    static func ellipsoid(_ c: SIMD3<Double>, _ r: SIMD3<Double>, segments: Int = 8, rings: Int = 6) -> Mesh3D {
        var m = Mesh3D()
        func p(_ i: Int, _ j: Int) -> SIMD3<Double> {
            let th = Double(i) / Double(rings) * .pi, ph = Double(j) / Double(segments) * 2 * .pi
            return c + SIMD3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph)) * r
        }
        for i in 0..<rings { for j in 0..<segments {
            m.triangles.append((p(i, j), p(i + 1, j + 1), p(i + 1, j)))
            m.triangles.append((p(i, j), p(i, j + 1), p(i + 1, j + 1)))
        } }
        return m
    }
    static func cone(_ base: SIMD3<Double>, radius r: Double, height h: Double, segments n: Int = 9) -> Mesh3D {
        var m = Mesh3D()
        let tip = base + [0, h, 0]
        for j in 0..<n {
            let a0 = Double(j) / Double(n) * 2 * .pi, a1 = Double(j + 1) / Double(n) * 2 * .pi
            let p0 = base + [cos(a0) * r, 0, sin(a0) * r], p1 = base + [cos(a1) * r, 0, sin(a1) * r]
            m.triangles.append((p0, tip, p1)); m.triangles.append((p0, p1, base))
        }
        return m
    }
    static func post(_ base: SIMD3<Double>, radius r: Double, height h: Double) -> Mesh3D {
        SceneBuilder.cylinder(center: .zero, radius: r, length: h, segments: 7).rotated(-.pi / 2, axis: [1, 0, 0]).translated(base + [0, h / 2, 0])
    }

    // MARK: Site

    static func build() -> SceneData {
        var s = SceneData()
        s.label = "Field"
        terrain(&s)
        strip(&s)
        flowers(&s)
        trees(&s)
        hillsAndMountains(&s)
        clouds(&s)
        flightLine(&s)
        return s
    }

    /// Terrain mesh: fine near the field, coarser further out, vertex colours from the grass / field noise.
    static func terrain(_ s: inout SceneData) {
        func grid(_ extent: Double, _ cell: Double, hole: Double) {
            let n = Int(extent * 2 / cell)
            for i in 0..<n { for j in 0..<n {
                let x0 = -extent + Double(i) * cell, z0 = -extent + Double(j) * cell, x1 = x0 + cell, z1 = z0 + cell
                if hole > 0, max(abs(x0 + cell / 2), abs(z0 + cell / 2)) < hole { continue }
                let p = [SIMD3(x0, height(x0, z0), z0), SIMD3(x1, height(x1, z0), z0), SIMD3(x1, height(x1, z1), z1), SIMD3(x0, height(x0, z1), z1)]
                let col = groundColor(x0 + cell / 2, z0 + cell / 2)
                // per-triangle colour (flat shading of the patches)
                s.addTriangle(p[0], p[2], p[1], color: col)
                s.addTriangle(p[0], p[3], p[2], color: groundColor(x0 + cell * 0.3, z0 + cell * 0.7))
            }}
        }
        grid(240, 4, hole: 0)
        grid(3200, 40, hole: 240)
    }

    /// Mown strip with alternating stripes and a darker border, distance cones.
    static func strip(_ s: inout SceneData) {
        let light = SIMD4<Float>(0.47, 0.68, 0.32, 1), dark = SIMD4<Float>(0.39, 0.6, 0.27, 1)
        var k = 0
        for x in stride(from: -9.0, to: 9.0, by: 2.25) {
            s.addMesh(.box(min: [x, 0.002, -90], max: [x + 2.25, 0.006, 12]), color: k % 2 == 0 ? light : dark)
            k += 1
        }
        for z in [-25.0, -50.0, -75.0] {
            for x in [-9.6, 9.6] { s.addMesh(cone([x, 0, z], radius: 0.18, height: 0.42, segments: 8), color: SIMD4(1, 0.45, 0.08, 1)) }
        }
    }

    /// Wild flowers scattered over the meadow (tiny coloured dots), denser along the field edges.
    static func flowers(_ s: inout SceneData) {
        let colors: [SIMD4<Float>] = [[0.96, 0.96, 0.9, 1], [0.98, 0.86, 0.2, 1], [0.7, 0.45, 0.9, 1], [0.95, 0.35, 0.3, 1]]
        for i in 0..<5000 {
            let x = (hash(i, 1, 31) - 0.5) * 360, z = (hash(i, 2, 31) - 0.5) * 360
            if abs(x) < 10, z > -92, z < 14 { continue }
            if fbm(x / 25, z / 25, 7) < 0.45 { continue }
            let y = height(x, z) + 0.06, r = 0.07 + hash(i, 3, 31) * 0.06
            let c = colors[Int(hash(i, 4, 31) * Double(colors.count)) % colors.count]
            s.addTriangle([x - r, y, z], [x + r, y, z], [x, y, z + r * 1.7], color: c)
        }
    }

    static func tree(_ s: inout SceneData, at x: Double, _ z: Double, seed: Int) {
        let y = height(x, z)
        let h = 8 + hash(seed, 1, 41) * 12
        let conifer = hash(seed, 2, 41) < 0.35
        let trunk = SIMD4<Float>(0.36, 0.26, 0.18, 1)
        if conifer {
            s.addMesh(post([x, y, z], radius: 0.25, height: h * 0.3), color: trunk)
            let g = SIMD4<Float>(0.12, 0.28 + Float(hash(seed, 3, 41)) * 0.08, 0.16, 1)
            for k in 0..<3 {
                let t = Double(k) / 3
                s.addMesh(cone([x, y + h * (0.18 + 0.27 * t), z], radius: h * (0.26 - 0.07 * t), height: h * 0.45, segments: 8), color: g)
            }
        } else {
            s.addMesh(post([x, y, z], radius: 0.35, height: h * 0.45), color: trunk)
            let g = SIMD4<Float>(0.2 + Float(hash(seed, 4, 41)) * 0.1, 0.4 + Float(hash(seed, 5, 41)) * 0.12, 0.17, 1)
            for k in 0..<4 {
                let ox = (hash(seed, 10 + k, 41) - 0.5) * h * 0.35, oz = (hash(seed, 20 + k, 41) - 0.5) * h * 0.35
                let oy = h * (0.55 + hash(seed, 30 + k, 41) * 0.25), rr = h * (0.2 + hash(seed, 40 + k, 41) * 0.1)
                s.addMesh(ellipsoid([x + ox, y + oy, z + oz], [rr, rr * 0.85, rr], segments: 7, rings: 5), color: g * Float(0.88 + 0.12 * Double(k % 2)))
            }
        }
    }

    /// Woods and tree lines around the field, single trees and bushes in the meadow.
    static func trees(_ s: inout SceneData) {
        var n = 0
        // Tree lines along field edges (with gaps).
        for (x0, z0, x1, z1) in [(-260.0, -230.0, 240.0, -250.0), (220.0, -240.0, 260.0, 210.0), (-280.0, 180.0, -230.0, -220.0)] {
            let len = ((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)).squareRoot()
            var d = 0.0
            while d < len {
                n += 1
                if hash(n, 7, 51) > 0.15 {
                    let t = d / len
                    tree(&s, at: x0 + (x1 - x0) * t + (hash(n, 8, 51) - 0.5) * 6, z0 + (z1 - z0) * t + (hash(n, 9, 51) - 0.5) * 6, seed: n)
                }
                d += 7 + hash(n, 10, 51) * 7
            }
        }
        // Woods: clusters further out.
        for w in 0..<9 {
            let a = hash(w, 1, 61) * 2 * .pi, r = 330 + hash(w, 2, 61) * 450
            let cx = cos(a) * r, cz = sin(a) * r
            for t in 0..<34 {
                n += 1
                let ang = hash(n, 3, 61) * 2 * .pi, rad = (hash(n, 4, 61)).squareRoot() * 55
                tree(&s, at: cx + cos(ang) * rad, cz + sin(ang) * rad, seed: n * 3 + t)
            }
        }
        // Single trees and bushes in the meadow (not on the strip or near the pilot).
        for i in 0..<40 {
            n += 1
            let x = (hash(i, 1, 71) - 0.5) * 380, z = (hash(i, 2, 71) - 0.5) * 380
            if (x * x + z * z).squareRoot() < 60 { continue }
            if hash(i, 3, 71) < 0.5 { tree(&s, at: x, z, seed: n) }
            else {
                let y = height(x, z), r = 1 + hash(i, 4, 71) * 1.6
                s.addMesh(ellipsoid([x, y + r * 0.5, z], [r * 1.3, r * 0.75, r], segments: 7, rings: 4), color: SIMD4(0.2, 0.38, 0.16, 1))
            }
        }
    }

    /// Two rings on the horizon: wooded ridges at ~1.8 km and a jagged mountain range at ~3 km with snow caps.
    static func hillsAndMountains(_ s: inout SceneData) {
        func ring(r: Double, depth: Double, n: Int, color: SIMD4<Float>, snowAbove: Double?, peak: (Double) -> Double) {
            for i in 0..<n {
                let a0 = Double(i) / Double(n) * 2 * .pi, a1 = Double(i + 1) / Double(n) * 2 * .pi
                let p0 = peak(a0), p1 = peak(a1)
                let b0 = SIMD3(cos(a0) * r, -10, sin(a0) * r), b1 = SIMD3(cos(a1) * r, -10, sin(a1) * r)
                let t0 = SIMD3(cos(a0) * (r + depth), p0, sin(a0) * (r + depth)), t1 = SIMD3(cos(a1) * (r + depth), p1, sin(a1) * (r + depth))
                // Lit slopes: alternate faces a little to break up the wall.
                let shade = Float(0.9 + 0.2 * hash(i, Int(r), 83))
                s.addTriangle(b0, t0, b1, color: color * shade + SIMD4(0, 0, 0, 1 - shade))
                s.addTriangle(b1, t0, t1, color: color * shade + SIMD4(0, 0, 0, 1 - shade))
                if let snow = snowAbove, max(p0, p1) > snow {
                    // Snow cap: the top band of the slope.
                    func down(_ t: SIMD3<Double>, _ b: SIMD3<Double>, _ h: Double) -> SIMD3<Double> {
                        let k = min(max((h - snow) / max(h + 10, 1), 0), 0.6) * 0.55
                        return t + (b - t) * k
                    }
                    let c = SIMD4<Float>(0.95, 0.96, 0.99, 1)
                    let d0 = down(t0, b0, p0), d1 = down(t1, b1, p1)
                    s.addTriangle(d0, t0, d1, color: c)
                    s.addTriangle(d1, t0, t1, color: c)
                }
            }
        }
        ring(r: 1700, depth: 120, n: 180, color: SIMD4(0.2, 0.33, 0.2, 1), snowAbove: nil) { a in
            40 + fbm(a * 5, 2.3, 87) * 150 + noise(a * 40, 0.3, 88) * 18
        }
        ring(r: 3000, depth: 200, n: 320, color: SIMD4(0.33, 0.39, 0.48, 1), snowAbove: 420) { a in
            let big = fbm(a * 4, 0.7, 81, octaves: 3)
            let ridge = 1 - abs(noise(a * 22, 1.1, 82) * 2 - 1)        // sharp crests
            return 80 + big * big * 700 + ridge * 120 * big
        }
    }

    /// Fair-weather cumulus: clusters of flattened puffs at 300–500 m.
    static func clouds(_ s: inout SceneData) {
        for k in 0..<36 {
            let x = (hash(k, 1, 91) - 0.5) * 3400, z = (hash(k, 2, 91) - 0.5) * 3400, y = 300 + hash(k, 3, 91) * 220
            let size = 50 + hash(k, 4, 91) * 80
            for p in 0..<6 {
                let ox = (hash(k, 10 + p, 91) - 0.5) * size * 1.6, oz = (hash(k, 20 + p, 91) - 0.5) * size, oy = hash(k, 30 + p, 91) * size * 0.25
                let r = size * (0.45 + hash(k, 40 + p, 91) * 0.35)
                let start = s.triangles.count
                let c = SIMD3<Double>(x + ox, y + oy, z + oz)
                s.addMesh(ellipsoid(c, [r, r * 0.45, r * 0.8], segments: 9, rings: 5), color: SIMD4(1, 1, 1, 0.94))
                for v in start..<s.triangles.count {
                    let pv = s.triangles[v].position
                    let radial = simd_normalize(SIMD3<Float>(pv.x, pv.y, pv.z) - SIMD3<Float>(c))
                    // Baked, unlit shading: bright tops and sun side, soft blue-grey bellies.
                    let sun = max(simd_dot(radial, SIMD3<Float>(sunDir)), 0), up = radial.y
                    let k = 0.8 + 0.12 * up + 0.12 * sun
                    let col = SIMD3<Float>(k, k, k) * SIMD3<Float>(1, 1, 1) + SIMD3<Float>(-0.04, -0.02, 0.03) * max(-up, 0)
                    s.triangles[v].color = SIMD4(simd_min(col, SIMD3(repeating: 1)), 0.95)
                    s.triangles[v].normal = SIMD4(0, 1, 0, 0)
                }
            }
        }
    }

    /// Flight line: fence posts with a rope behind the pilot, a table with an umbrella, a windsock.
    static func flightLine(_ s: inout SceneData) {
        let wood = SIMD4<Float>(0.55, 0.42, 0.28, 1)
        for x in stride(from: -14.0, through: 14.0, by: 3.5) {
            s.addMesh(post([x, 0, 4], radius: 0.05, height: 1.0), color: wood)
        }
        s.addMesh(.box(min: [-14, 0.85, 3.98], max: [14, 0.88, 4.02]), color: SIMD4(0.95, 0.85, 0.2, 1))
        // Table and umbrella.
        s.addMesh(.box(min: [-6.6, 0.72, 1.4], max: [-5.0, 0.76, 2.4]), color: SIMD4(0.9, 0.9, 0.88, 1))
        for (dx, dz) in [(-6.5, 1.5), (-5.1, 1.5), (-6.5, 2.3), (-5.1, 2.3)] { s.addMesh(post([dx, 0, dz], radius: 0.025, height: 0.72), color: SIMD4(0.3, 0.3, 0.32, 1)) }
        s.addMesh(post([-5.8, 0, 1.9], radius: 0.025, height: 2.2), color: SIMD4(0.85, 0.85, 0.85, 1))
        s.addMesh(cone([-5.8, 1.85, 1.9], radius: 1.3, height: 0.45, segments: 10), color: SIMD4(0.9, 0.25, 0.2, 1))
        // Windsock on a pole, pointing downwind (the breeze comes from the right).
        s.addMesh(post([12, 0, -8], radius: 0.04, height: 4.2), color: SIMD4(0.8, 0.8, 0.82, 1))
        for k in 0..<4 {
            let r0 = 0.28 - Double(k) * 0.05, x0 = 12 - Double(k) * 0.35
            s.addMesh(SceneBuilder.cylinder(center: .zero, radius: r0, length: 0.35, segments: 10).rotated(.pi / 2, axis: [0, 1, 0]).translated([x0 - 0.18, 4.05, -8]),
                      color: k % 2 == 0 ? SIMD4(1, 0.4, 0.05, 1) : SIMD4(0.97, 0.97, 0.97, 1))
        }
    }

    /// Sky dome around the eye: horizon haze up to deep blue, a warm glow around the sun.
    static func sky() -> SceneData {
        var s = SceneData()
        s.label = "Sky"
        let rings = 14, segs = 36, R = 6000.0
        func dir(_ i: Int, _ j: Int) -> SIMD3<Double> {
            let el = -0.15 + Double(i) / Double(rings) * (.pi / 2 + 0.15), az = Double(j) / Double(segs) * 2 * .pi
            return SIMD3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
        }
        func col(_ d: SIMD3<Double>) -> SIMD4<Float> {
            let t = Float(min(max(d.y, 0), 1))
            var c = horizon * (1 - pow(t, 0.55)) + zenith * pow(t, 0.55)
            let sun = Float(max(simd_dot(d, sunDir), 0))
            c += SIMD4(1, 0.92, 0.75, 0) * (pow(sun, 64) * 0.9 + pow(sun, 6) * 0.12)
            c.w = 1
            return c
        }
        for i in 0..<rings { for j in 0..<segs {
            let a = dir(i, j), b = dir(i, j + 1), c = dir(i + 1, j + 1), d = dir(i + 1, j)
            s.addTriangleColors(a * R, b * R, c * R, col(a), col(b), col(c))
            s.addTriangleColors(a * R, c * R, d * R, col(a), col(c), col(d))
        }}
        return s
    }
}

extension SceneData {
    /// Unlit triangle with a colour per corner (sky dome).
    mutating func addTriangleColors(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ ca: SIMD4<Float>, _ cb: SIMD4<Float>, _ cc: SIMD4<Float>) {
        for (p, col) in [(a, ca), (b, cb), (c, cc)] {
            triangles.append(GPUVertex(position: SIMD4(Float(p.x), Float(p.y), Float(p.z), 1), normal: SIMD4(0, 1, 0, 0), color: col))
        }
        triLabels.append(0); triLabels.append(0); triLabels.append(0)
    }
}
