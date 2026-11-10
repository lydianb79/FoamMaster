import Foundation
import simd

/// Geometric check of the gap between each propeller and every foam part of the airframe.
///
/// The spinning prop is modelled as a cylinder around the motor axis: radius = prop radius, axial extent =
/// blade depth on the motor side and hub + spinner on the other side (see `AircraftConfig.propDepthIn/Out`).
/// Every foam part is sampled (both faces, its interior on a 3 mm grid and its edges every 1 mm) in a window
/// around the prop, and the smallest distance to the cylinder is reported. Holes (prop slot, servo cut-outs are
/// filled by servos and kept solid) are excluded.
struct PropClearance {
    var gap: Double            // smallest gap found (mm), 0 = touching / intersecting
    var part: String           // closest part

    static func evaluate(_ d: Design) -> PropClearance {
        let c = d.config
        let R = c.propRadius, plane = c.propPlaneZ
        // Direction from the prop towards its motor along z.
        let toMotor: Double = c.isPusher ? -1 : 1
        let dIn = c.propDepthIn, dOut = c.propDepthOut
        let reach = 25.0                               // only foam closer than this matters
        var best = PropClearance(gap: .greatestFiniteMagnitude, part: "")

        for mx in c.motorXs {
            func gap(_ p: SIMD3<Double>) -> Double {
                let r = simd_length(SIMD2(p.x - mx, p.y))
                let s = (p.z - plane) * toMotor          // > 0: on the motor side of the disc
                let axialOut = s >= 0 ? max(0, s - dIn) : max(0, -s - dOut)
                let radialOut = max(0, r - R)
                return (axialOut * axialOut + radialOut * radialOut).squareRoot()
            }
            // 3D window around the prop cylinder.
            let lo = SIMD3<Double>(mx - R - reach, -R - reach, plane - max(dIn, dOut) - reach)
            let hi = SIMD3<Double>(mx + R + reach, R + reach, plane + max(dIn, dOut) + reach)

            for part in d.parts {
                let holes = part.holes.filter { $0.kind != .servo }.map(\.polygon)
                let pb = Poly.bounds(part.outline)
                for inst in part.instances {
                    // Skip parts whose 3D box is nowhere near the prop.
                    var plo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), phi = -plo
                    for corner in [pb.min, Vec2(pb.max.x, pb.min.y), pb.max, Vec2(pb.min.x, pb.max.y)] {
                        for off in [-part.thickness / 2, part.thickness / 2] {
                            let q = inst.point(corner, offset: off); plo = simd_min(plo, q); phi = simd_max(phi, q)
                        }
                    }
                    if phi.x < lo.x || plo.x > hi.x || phi.y < lo.y || plo.y > hi.y || phi.z < lo.z || plo.z > hi.z { continue }
                    // Map the 3D window into the part's (u, v) plane to limit the sampling.
                    var umin = Double.greatestFiniteMagnitude, umax = -umin, vmin = umin, vmax = -umin
                    for k in 0..<8 {
                        let q = SIMD3<Double>(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z) - inst.origin
                        let u = simd_dot(q, inst.u), v = simd_dot(q, inst.v)
                        umin = min(umin, u); umax = max(umax, u); vmin = min(vmin, v); vmax = max(vmax, v)
                    }
                    umin = max(umin, pb.min.x); umax = min(umax, pb.max.x)
                    vmin = max(vmin, pb.min.y); vmax = min(vmax, pb.max.y)
                    guard umax >= umin, vmax >= vmin else { continue }
                    let half = part.thickness / 2
                    func test(_ p2: Vec2) {
                        for off in [-half, half] {
                            let g = gap(inst.point(p2, offset: off))
                            if g < best.gap { best = PropClearance(gap: g, part: part.name) }
                        }
                    }
                    // Interior grid (coarse – it only has to catch foam passing through the disc; the exact gap
                    // comes from the edges).
                    let step = 3.0
                    var u = umin
                    while u <= umax {
                        var v = vmin
                        while v <= vmax {
                            let p = Vec2(u, v)
                            if Poly.contains(part.outline, p) && !holes.contains(where: { Poly.contains($0, p) }) { test(p) }
                            v += step
                        }
                        u += step
                    }
                    // Edges of the outline and of the through-holes (e.g. the prop slot).
                    for loop in [part.outline] + holes {
                        for i in loop.indices {
                            let a = loop[i], b = loop[(i + 1) % loop.count]
                            let n = max(1, Int(simd_distance(a, b) / 1.0))
                            for k in 0...n {
                                let p = a + (b - a) * (Double(k) / Double(n))
                                if p.x >= umin - 1 && p.x <= umax + 1 && p.y >= vmin - 1 && p.y <= vmax + 1 { test(p) }
                            }
                        }
                    }
                }
            }
        }
        if best.gap == .greatestFiniteMagnitude { best.gap = 99 }
        return best
    }
}
