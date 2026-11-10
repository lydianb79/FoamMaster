import Foundation

/// Straight-tapered, swept lifting panel described in plan coordinates
/// (u = chordwise aft, v = spanwise).
struct TaperedPanel {
    var rootLE: Double = 0
    var rootChord: Double
    var tipChord: Double
    var sweep: Double
    var semiSpan: Double

    func le(_ v: Double) -> Double { rootLE + sweep * abs(v) / semiSpan }
    func chord(_ v: Double) -> Double { rootChord + (tipChord - rootChord) * abs(v) / semiSpan }
    func te(_ v: Double) -> Double { le(v) + chord(v) }
    func at(_ u: Double, _ v: Double) -> Vec2 { Vec2(u, v) }

    struct Output {
        var outline: [Vec2]
        var main: [Vec2]
        var controls: [[Vec2]]
        var features: [Feature]
    }

    /// Builds the panel with control surfaces cut out of the trailing edge.
    /// - Parameters:
    ///   - full: true = both halves as one piece (v from -s to s), false = right half only (v from 0 to s).
    ///   - surfaces: spanwise ranges (positive v) of control surfaces.
    ///   - fraction: control surface chord as fraction of local chord.
    func build(full: Bool, surfaces: [ClosedRange<Double>], fraction: Double) -> Output {
        let s = semiSpan
        func h(_ v: Double) -> Double { te(v) - fraction * chord(v) }

        var chain: [Vec2] = [Vec2(te(0), 0)]
        var features: [Feature] = []
        var controls: [[Vec2]] = []
        for r in surfaces.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let a = r.lowerBound, b = r.upperBound
            chain += [Vec2(te(a), a), Vec2(h(a), a), Vec2(h(b), b), Vec2(te(b), b)]
            controls.append([Vec2(h(a), a), Vec2(te(a), a), Vec2(te(b), b), Vec2(h(b), b)])
            features += [.hinge(Vec2(h(a), a), Vec2(h(b), b)),
                         .cut(Vec2(h(a), a), Vec2(te(a), a)),
                         .cut(Vec2(h(b), b), Vec2(te(b), b))]
        }
        chain.append(Vec2(te(s), s))
        let plainChain = [Vec2(te(0), 0), Vec2(te(s), s)]

        func mirror(_ p: Vec2) -> Vec2 { Vec2(p.x, -p.y) }

        func assemble(_ ch: [Vec2]) -> [Vec2] {
            if full {
                let left = ch.reversed().map(mirror)
                return [Vec2(le(0), 0), Vec2(le(s), -s)] + left + ch.dropFirst() + [Vec2(le(s), s)]
            } else {
                return [Vec2(le(0), 0)] + ch + [Vec2(le(s), s)]
            }
        }

        let outline = assemble(plainChain)
        let main = assemble(chain)
        if full {
            let mirroredControls = controls.map { Array($0.map(mirror).reversed()) }
            controls += mirroredControls
            features += features.map { f in
                if case let .hinge(a, b) = f { return .hinge(mirror(a), mirror(b)) }
                if case let .cut(a, b) = f { return .cut(mirror(a), mirror(b)) }
                return f
            }
        }
        return Output(outline: outline, main: main, controls: controls, features: features)
    }

    /// Panel whose control surface spans the whole trailing edge in one piece (stabiliser + elevator).
    func buildFullSpanSurface(fraction: Double) -> Output {
        let s = semiSpan
        func h(_ v: Double) -> Double { te(v) - fraction * chord(v) }
        let outline = [Vec2(le(0), 0), Vec2(le(s), -s), Vec2(te(s), -s), Vec2(te(0), 0), Vec2(te(s), s), Vec2(le(s), s)]
        let main = [Vec2(le(0), 0), Vec2(le(s), -s), Vec2(h(s), -s), Vec2(h(0), 0), Vec2(h(s), s), Vec2(le(s), s)]
        let control = [Vec2(h(0), 0), Vec2(h(s), -s), Vec2(te(s), -s), Vec2(te(0), 0), Vec2(te(s), s), Vec2(h(s), s)]
        let features: [Feature] = [.hinge(Vec2(h(s), -s), Vec2(h(0), 0)), .hinge(Vec2(h(0), 0), Vec2(h(s), s))]
        return Output(outline: outline, main: main, controls: [control], features: features)
    }
}
