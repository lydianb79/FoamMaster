import Foundation
import simd

/// Particle effects of the simulator: foam bits and dust when the model crashes (leaves too when it hits a tree), grass
/// flying on a landing, a splash in the pond, an optional smoke trail. Simulated on the CPU (a few thousand at most),
/// drawn as small camera-facing quads, unlit, fading out.
final class SimEffects {
    struct Particle {
        var p: SIMD3<Float>, v: SIMD3<Float>
        var age: Float = 0, life: Float
        var size: Float, grow: Float = 0          // m, m/s
        var color: SIMD4<Float>
        var gravity: Float = 9.81, drag: Float = 0.5
        var settles = true                         // stops on the ground (bits); puffs pass through it
    }
    private(set) var particles: [Particle] = []
    private var smokeTimer: Float = 0
    static let maxParticles = 4000

    private func rnd(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b) }
    private func add(_ p: Particle) { if particles.count < Self.maxParticles { particles.append(p) } }

    /// Foam bits flying apart (the model's colours), a puff of dust; leaves when it went into a tree.
    func crash(at p: SIMD3<Float>, speed: Float, tree: Bool) {
        let foam: [SIMD4<Float>] = [[0.95, 0.95, 0.93, 1], [0.92, 0.92, 0.9, 1], [1, 0.5, 0.12, 1], [0.25, 0.25, 0.28, 1]]
        let k = min(max(speed / 8, 0.6), 1.6)
        for _ in 0..<45 {
            let dir = simd_normalize(SIMD3<Float>(rnd(-1, 1), rnd(0.3, 1.4), rnd(-1, 1)))
            add(Particle(p: p, v: dir * rnd(1.5, 5) * k, life: rnd(2.5, 4), size: rnd(0.02, 0.07), color: foam.randomElement()!, drag: 0.8))
        }
        for _ in 0..<(tree ? 6 : 16) {
            add(Particle(p: p + [rnd(-0.2, 0.2), 0, rnd(-0.2, 0.2)], v: [rnd(-0.8, 0.8), rnd(0.3, 1.2), rnd(-0.8, 0.8)], life: rnd(1.2, 2.2),
                         size: rnd(0.15, 0.3), grow: rnd(0.4, 0.9), color: [0.55, 0.47, 0.34, 0.45], gravity: -0.2, drag: 1.5, settles: false))
        }
        if tree {
            for _ in 0..<40 {
                add(Particle(p: p + [rnd(-0.6, 0.6), rnd(-0.4, 0.6), rnd(-0.6, 0.6)], v: [rnd(-1.5, 1.5), rnd(-0.5, 1.5), rnd(-1.5, 1.5)], life: rnd(3, 5),
                             size: rnd(0.04, 0.08), color: [0.22 + rnd(0, 0.15), 0.42 + rnd(0, 0.15), 0.15, 1], gravity: 2.5, drag: 2.5))
            }
        }
    }

    /// A touch-down on the grass: grass bits and a little dust.
    func landing(at p: SIMD3<Float>, speed: Float) {
        let n = Int(min(max(speed * 3, 8), 30))
        for _ in 0..<n {
            add(Particle(p: p + [rnd(-0.2, 0.2), 0.02, rnd(-0.2, 0.2)], v: [rnd(-1, 1), rnd(0.5, 2), rnd(-1, 1)] * 0.8, life: rnd(1, 2),
                         size: rnd(0.02, 0.045), color: [0.3 + rnd(0, 0.1), 0.52 + rnd(0, 0.1), 0.22, 1], drag: 1.5))
        }
        for _ in 0..<5 {
            add(Particle(p: p, v: [rnd(-0.4, 0.4), rnd(0.1, 0.4), rnd(-0.4, 0.4)], life: rnd(0.8, 1.4), size: 0.12, grow: 0.5,
                         color: [0.6, 0.55, 0.42, 0.3], gravity: 0, drag: 1.5, settles: false))
        }
    }

    /// Into the pond: a crown of drops and spray.
    func splash(at p: SIMD3<Float>, speed: Float) {
        let k = min(max(speed / 6, 0.7), 1.5)
        for _ in 0..<70 {
            let a = rnd(0, 2 * .pi), out = rnd(0.5, 2.2)
            add(Particle(p: [p.x, 0.06, p.z], v: [cos(a) * out, rnd(1.5, 4.5) * k, sin(a) * out], life: rnd(0.8, 1.5),
                         size: rnd(0.025, 0.06), color: [0.85, 0.92, 1, 0.85], drag: 0.3))
        }
        for _ in 0..<10 {
            add(Particle(p: [p.x, 0.15, p.z], v: [rnd(-0.6, 0.6), rnd(0.6, 1.5), rnd(-0.6, 0.6)], life: rnd(0.6, 1.1), size: 0.15, grow: 0.8,
                         color: [0.92, 0.96, 1, 0.4], gravity: 1, drag: 2, settles: false))
        }
    }

    /// Smoke trail: white puffs from the tail while it flies, growing and fading, drifting a little up.
    func smoke(from p: SIMD3<Float>, dt: Float) {
        smokeTimer += dt
        while smokeTimer > 0.025 {
            smokeTimer -= 0.025
            add(Particle(p: p, v: [rnd(-0.15, 0.15), rnd(0.05, 0.25), rnd(-0.15, 0.15)], life: 4.5, size: 0.12, grow: 0.35,
                         color: [0.96, 0.96, 0.96, 0.55], gravity: -0.05, drag: 0.8, settles: false))
        }
    }

    func update(_ dt: Float) {
        guard dt > 0 else { return }
        var i = 0
        while i < particles.count {
            var q = particles[i]
            q.age += dt
            if q.age > q.life { particles.swapAt(i, particles.count - 1); particles.removeLast(); continue }
            q.v.y -= q.gravity * dt
            q.v *= max(0, 1 - q.drag * dt)
            q.p += q.v * dt
            q.size += q.grow * dt
            if q.settles {
                let ground = Float(SimScenery.surfaceHeight(Double(q.p.x), Double(q.p.z))) + 0.01
                if q.p.y < ground {
                    q.p.y = ground
                    if SimScenery.isWater(Double(q.p.x), Double(q.p.z)) { q.age = q.life } else { q.v = .zero; q.gravity = 0 }
                }
            }
            particles[i] = q
            i += 1
        }
    }

    func clear() { particles.removeAll(); smokeTimer = 0 }

    /// Camera-facing quads (two triangles each), unlit, fading over the last third of their life.
    func vertices(right: SIMD3<Float>, up: SIMD3<Float>) -> [GPUVertex] {
        var out: [GPUVertex] = []
        out.reserveCapacity(particles.count * 30)
        for q in particles {
            let fade = min(1, 3 * (1 - q.age / q.life))
            var c = q.color; c.w *= fade
            let r = right * q.size, u = up * q.size
            if q.settles {
                // bits: small quads
                let a = q.p - r - u, b = q.p + r - u, cc = q.p + r + u, d = q.p - r + u
                for v in [a, b, cc, a, cc, d] { out.append(GPUVertex(position: SIMD4(v, 1), normal: SIMD4(0, 1, 0, 0), color: c)) }
            } else {
                // puffs (dust, spray, smoke): soft discs – full colour in the middle, fading to nothing at the edge
                var edge = c; edge.w = 0
                for k in 0..<10 {
                    let a0 = Float(k) / 10 * 2 * .pi, a1 = Float(k + 1) / 10 * 2 * .pi
                    let p0 = q.p + r * cos(a0) + u * sin(a0), p1 = q.p + r * cos(a1) + u * sin(a1)
                    out.append(GPUVertex(position: SIMD4(q.p, 1), normal: SIMD4(0, 1, 0, 0), color: c))
                    out.append(GPUVertex(position: SIMD4(p0, 1), normal: SIMD4(0, 1, 0, 0), color: edge))
                    out.append(GPUVertex(position: SIMD4(p1, 1), normal: SIMD4(0, 1, 0, 0), color: edge))
                }
            }
        }
        return out
    }
}
