import Foundation
import simd

/// Simple triangle soup used for STL export and 3D previews.
struct Mesh3D {
    var triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []

    mutating func append(_ other: Mesh3D) { triangles += other.triangles }

    func transformed(_ f: (SIMD3<Double>) -> SIMD3<Double>) -> Mesh3D {
        Mesh3D(triangles: triangles.map { (f($0.0), f($0.1), f($0.2)) })
    }

    func translated(_ d: SIMD3<Double>) -> Mesh3D { transformed { $0 + d } }

    /// Rotation around an axis through the origin (radians).
    func rotated(_ angle: Double, axis: SIMD3<Double>) -> Mesh3D {
        let q = simd_quatd(angle: angle, axis: simd_normalize(axis))
        return transformed { q.act($0) }
    }

    /// Volume in mm³ (divergence theorem; mesh must be closed and outward-oriented).
    var volume: Double {
        abs(triangles.reduce(0) { $0 + simd_dot($1.0, simd_cross($1.1, $1.2)) / 6 })
    }

    /// Signed volume: negative when the triangles are wound inward.
    var signedVolume: Double { triangles.reduce(0) { $0 + simd_dot($1.0, simd_cross($1.1, $1.2)) / 6 } }
    /// Same mesh with the winding reversed (normals flipped).
    var flipped: Mesh3D { Mesh3D(triangles: triangles.map { ($0.0, $0.2, $0.1) }) }

    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in triangles { for p in [t.0, t.1, t.2] { lo = simd_min(lo, p); hi = simd_max(hi, p) } }
        return (lo, hi)
    }

    /// Extrudes a 2D polygon (with holes) in the XY plane from z0 to z1.
    static func extrude(_ outline: [Vec2], holes: [[Vec2]] = [], z0: Double, z1: Double) -> Mesh3D {
        var m = Mesh3D()
        let tri = Poly.triangulate(outer: outline, holes: holes)
        let pts = tri.points
        for i in stride(from: 0, to: tri.triangles.count, by: 3) {
            let a = pts[tri.triangles[i]], b = pts[tri.triangles[i + 1]], c = pts[tri.triangles[i + 2]]
            m.triangles.append(([a.x, a.y, z1], [b.x, b.y, z1], [c.x, c.y, z1]))
            m.triangles.append(([a.x, a.y, z0], [c.x, c.y, z0], [b.x, b.y, z0]))
        }
        func wall(_ loop: [Vec2]) {
            for i in 0..<loop.count {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                m.triangles.append(([a.x, a.y, z0], [b.x, b.y, z0], [b.x, b.y, z1]))
                m.triangles.append(([a.x, a.y, z0], [b.x, b.y, z1], [a.x, a.y, z1]))
            }
        }
        wall(Poly.ccw(outline))
        for h in holes { wall(Poly.cw(h)) }
        return m
    }

    static func box(min lo: SIMD3<Double>, max hi: SIMD3<Double>) -> Mesh3D {
        extrude(Poly.rect(minU: lo.x, maxU: hi.x, minV: lo.y, maxV: hi.y), z0: lo.z, z1: hi.z)
    }

    // MARK: STL

    func stlData(name: String) -> Data {
        var data = Data()
        var header = Array("FoamMaster \(name)".utf8.prefix(80))
        header += [UInt8](repeating: 0, count: 80 - header.count)
        data.append(contentsOf: header)
        var count = UInt32(triangles.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        func put(_ v: SIMD3<Double>) {
            for c in [Float(v.x), Float(v.y), Float(v.z)] {
                var bits = c.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        for t in triangles {
            let n = simd_cross(t.1 - t.0, t.2 - t.0)
            let len = simd_length(n)
            put(len > 0 ? n / len : .zero)
            put(t.0); put(t.1); put(t.2)
            data.append(contentsOf: [0, 0])
        }
        return data
    }
}
