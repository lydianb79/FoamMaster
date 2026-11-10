import Foundation
import AppKit
import simd

/// Packs all parts at 1:1 scale onto a virtual sheet that is then tiled onto A4 pages.
struct PlanLayout {
    struct Placed {
        var part: Part
        var origin: Vec2
        var rotated: Bool
        var size: Vec2
        var bmin: Vec2
        var bmax: Vec2

        /// Part plan coordinate → sheet coordinate (mm, y down).
        func map(_ p: Vec2) -> Vec2 {
            rotated ? origin + Vec2(p.y - bmin.y, p.x - bmin.x)
                    : origin + Vec2(p.x - bmin.x, bmax.y - p.y)
        }
    }

    static let page = Vec2(210, 297)
    static let margin = Vec2(10, 10)
    static let tile = Vec2(190, 277)
    static let gap = 14.0
    static let labelSpace = 11.0

    var placed: [Placed]
    var columns: Int
    var rows: Int
    var sheet: Vec2 { Vec2(Double(columns) * Self.tile.x, Double(rows) * Self.tile.y) }

    /// Skyline bottom-left packing. Tries 1–4 page columns, several sort orders and both
    /// orientations per part; keeps the layout with the fewest printed pages, then the
    /// fewest parts split across page borders.
    static func make(_ parts: [Part]) -> PlanLayout {
        struct Item { var part: Part; var bmin: Vec2; var bmax: Vec2; var size: Vec2 }
        let items = parts.map { p -> Item in
            let b = Poly.bounds(p.outline)
            return Item(part: p, bmin: b.min, bmax: b.max, size: b.max - b.min)
        }
        let orders: [(Item, Item) -> Bool] = [
            { $0.size.y > $1.size.y }, { max($0.size.x, $0.size.y) > max($1.size.x, $1.size.y) },
            { $0.size.x * $0.size.y > $1.size.x * $1.size.y }, { $0.size.x > $1.size.x }
        ]
        var best: (layout: PlanLayout, score: Double)?
        for cols in 1...4 {
            let width = Double(cols) * tile.x
            for order in orders {
                guard let placed = pack(items.sorted(by: order).map { ($0.part, $0.bmin, $0.bmax, $0.size) }, width: width) else { continue }
                let height = placed.map { $0.origin.y + $0.size.y }.max() ?? 0
                let layout = PlanLayout(placed: placed, columns: cols, rows: max(1, Int(ceil((height + 2) / tile.y))))
                let splits = placed.reduce(0) { $0 + layout.tilesTouched(by: $1) - 1 }
                let score = Double(layout.usedTiles.count) * 1000 + Double(splits) * 25 + height / 100
                if best == nil || score < best!.score { best = (layout, score) }
            }
        }
        return best!.layout
    }

    private static func pack(_ items: [(Part, Vec2, Vec2, Vec2)], width: Double) -> [Placed]? {
        // Skyline segments: (x, y, w)
        var sky: [(x: Double, y: Double, w: Double)] = [(0, 0, width)]
        var out: [Placed] = []
        let margin = 4.0
        for (part, bmin, bmax, sz) in items {
            var bestPos: (x: Double, y: Double, top: Double, rot: Bool)?
            for rot in [false, true] {
                let w = (rot ? sz.y : sz.x) + gap, h = (rot ? sz.x : sz.y) + gap + labelSpace
                guard w + margin <= width + gap else { continue }
                for seg in sky {
                    let x = max(seg.x, margin)
                    guard x + w <= width + gap - 0.01 else { continue }
                    let y = sky.filter { $0.x < x + w && $0.x + $0.w > x }.map(\.y).max() ?? 0
                    let top = y + h
                    if bestPos == nil || top < bestPos!.top - 0.01 || (abs(top - bestPos!.top) < 0.01 && x < bestPos!.x) {
                        bestPos = (x, y, top, rot)
                    }
                }
            }
            guard let pos = bestPos else { return nil }
            let size = pos.rot ? Vec2(sz.y, sz.x) : sz
            out.append(Placed(part: part, origin: Vec2(pos.x, pos.y + margin + labelSpace), rotated: pos.rot, size: size, bmin: bmin, bmax: bmax))
            // Update skyline with the new block.
            let w = size.x + gap, nx = pos.x, ny = pos.top
            var next: [(x: Double, y: Double, w: Double)] = []
            for seg in sky {
                let a = seg.x, b = seg.x + seg.w
                if b <= nx || a >= nx + w { next.append(seg); continue }
                if a < nx { next.append((a, seg.y, nx - a)) }
                if b > nx + w { next.append((nx + w, seg.y, b - nx - w)) }
            }
            next.append((nx, ny, w))
            sky = next.sorted { $0.x < $1.x }
        }
        return out
    }

    func tilesTouched(by p: Placed) -> Int {
        let a = p.origin - Vec2(0, Self.labelSpace), b = p.origin + p.size
        let c0 = Int(floor(a.x / Self.tile.x)), c1 = Int(floor((b.x - 0.01) / Self.tile.x))
        let r0 = Int(floor(a.y / Self.tile.y)), r1 = Int(floor((b.y - 0.01) / Self.tile.y))
        return (c1 - c0 + 1) * (r1 - r0 + 1)
    }

    /// Tiles that actually contain geometry.
    var usedTiles: [(row: Int, col: Int)] {
        var res: [(Int, Int)] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let lo = Vec2(Double(c) * Self.tile.x, Double(r) * Self.tile.y), hi = lo + Self.tile
                let hit = placed.contains { p in
                    let a = p.origin - Vec2(0, Self.labelSpace), b = p.origin + p.size
                    return a.x < hi.x && b.x > lo.x && a.y < hi.y && b.y > lo.y
                }
                if hit { res.append((r, c)) }
            }
        }
        return res
    }

    static func tileName(row: Int, col: Int) -> String { "\(Character(UnicodeScalar(65 + col)!))\(row + 1)" }
}

/// Draws plan parts into a y-down CGContext whose unit is 1 mm.
enum PlanDrawer {
    static let ink = NSColor(calibratedWhite: 0.05, alpha: 1)
    static let hingeColor = NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.9, alpha: 1)
    static let hornColor = NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.05, alpha: 1)
    static let sparColor = NSColor(calibratedRed: 0.1, green: 0.6, blue: 0.25, alpha: 1)
    static let servoColor = NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.3, alpha: 1)
    static let cgColor = NSColor(calibratedRed: 0.9, green: 0.15, blue: 0.5, alpha: 1)

    static func path(_ pts: [Vec2], _ map: (Vec2) -> Vec2) -> CGPath {
        let path = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let q = map(p)
            if i == 0 { path.move(to: CGPoint(x: q.x, y: q.y)) } else { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
        }
        path.closeSubpath()
        return path
    }

    static func text(_ s: String, at p: Vec2, size: CGFloat, color: NSColor = ink, weight: NSFont.Weight = .regular, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        let w = str.size().width
        str.draw(at: NSPoint(x: centered ? p.x - w / 2 : p.x, y: p.y))
    }

    static func line(_ ctx: CGContext, _ a: Vec2, _ b: Vec2, color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.move(to: CGPoint(x: a.x, y: a.y)); ctx.addLine(to: CGPoint(x: b.x, y: b.y))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func draw(_ pl: PlanLayout.Placed, in ctx: CGContext, cgZ: Double?, dark: Bool = false) {
        let part = pl.part
        let map = pl.map
        let inkC = dark ? NSColor.white : ink

        // Title
        let qty = part.mirroredPair ? "cut 2× (1 mirrored)" : (part.quantity > 1 ? "cut \(part.quantity)×" : "cut 1×")
        text("\(part.name.uppercased())  ·  \(qty)  ·  \(part.material.displayName)", at: pl.origin - Vec2(0, 7.5), size: 4.2, color: inkC, weight: .semibold)

        // Outline
        let outline = path(part.outline, map)
        ctx.addPath(outline)
        ctx.setFillColor((dark ? NSColor(calibratedRed: 0.4, green: 0.7, blue: 1, alpha: 0.14) : NSColor(calibratedRed: 0.86, green: 0.93, blue: 1, alpha: 1)).cgColor)
        ctx.fillPath()

        // Holes
        for h in part.holes {
            let p = path(h.polygon, map)
            ctx.addPath(p)
            switch h.kind {
            case .servo: ctx.setFillColor(servoColor.withAlphaComponent(0.35).cgColor)
            case .hornSlot: ctx.setFillColor(inkC.cgColor)
            case .slot: ctx.setFillColor(NSColor.gray.withAlphaComponent(0.55).cgColor)
            case .drill: ctx.setFillColor(inkC.cgColor)
            }
            ctx.fillPath()
            ctx.addPath(p); ctx.setStrokeColor(inkC.cgColor); ctx.setLineWidth(0.25); ctx.strokePath()
            if h.kind == .servo {
                let c = map(Poly.centroid(h.polygon))
                text("SERVO", at: c - Vec2(0, 1.4), size: 2.4, color: inkC, weight: .bold, centered: true)
            }
            if h.kind == .hornSlot {
                // Horn position: flange footprint (from 0.5 mm behind the hinge), pushrod hole ○ over the hinge line
                // (6 mm ahead of the slot centre).
                let c = Poly.centroid(h.polygon)
                let foot = Poly.rect(minU: c.x - 5.5, maxU: c.x + 9.5, minV: c.y - 3, maxV: c.y + 3)
                ctx.saveGState()
                ctx.addPath(path(foot, map)); ctx.setStrokeColor(hornColor.cgColor); ctx.setLineWidth(0.3)
                ctx.setLineDash(phase: 0, lengths: [1, 0.8]); ctx.strokePath(); ctx.restoreGState()
                let hole = map(Vec2(c.x - 6, c.y))
                ctx.saveGState()
                ctx.setStrokeColor(hornColor.cgColor); ctx.setLineWidth(0.3)
                ctx.strokeEllipse(in: CGRect(x: hole.x - 1, y: hole.y - 1, width: 2, height: 2))
                ctx.restoreGState()
                text("HORN", at: map(Vec2(c.x + 2, c.y)) + Vec2(0, 3.4), size: 2.2, color: hornColor, weight: .bold, centered: true)
            }
        }

        // Features
        for f in part.features {
            switch f {
            case let .hinge(a, b): line(ctx, map(a), map(b), color: hingeColor, width: 0.35, dash: [2, 1.2])
            case let .cut(a, b): line(ctx, map(a), map(b), color: inkC, width: 0.35)
            case let .spar(a, b, w):
                let d = simd_normalize(map(b) - map(a)), n = Vec2(-d.y, d.x) * w / 2
                line(ctx, map(a) + n, map(b) + n, color: sparColor, width: 0.3, dash: [3, 1.5])
                line(ctx, map(a) - n, map(b) - n, color: sparColor, width: 0.3, dash: [3, 1.5])
            case let .zone(poly, name):
                ctx.saveGState()
                ctx.addPath(path(poly, map)); ctx.setStrokeColor(NSColor.gray.cgColor); ctx.setLineWidth(0.3)
                ctx.setLineDash(phase: 0, lengths: [1.5, 1.5]); ctx.strokePath(); ctx.restoreGState()
                text(name, at: map(Poly.centroid(poly)) - Vec2(0, 1.5), size: 2.6, color: .gray, centered: true)
            case let .label(s, p): text(s, at: map(p) - Vec2(0, 2), size: 3.2, color: inkC.withAlphaComponent(0.35), weight: .heavy, centered: true)
            case let .cg(p): drawCG(ctx, map(p))
            }
        }

        if let z = cgZ, part.role == .wing || part.role == .fuselage {
            let v = part.role == .wing && part.mirroredPair ? 8.0 : 0.0
            drawCG(ctx, map(Vec2(z, v)))
        }

        ctx.addPath(outline)
        ctx.setStrokeColor(inkC.cgColor)
        ctx.setLineWidth(0.4)
        ctx.strokePath()
    }

    static func drawCG(_ ctx: CGContext, _ c: Vec2) {
        ctx.saveGState()
        ctx.setStrokeColor(cgColor.cgColor); ctx.setLineWidth(0.35)
        ctx.strokeEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        ctx.move(to: CGPoint(x: c.x - 5, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 5, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5))
        ctx.strokePath()
        ctx.restoreGState()
        text("CG", at: c + Vec2(3.5, 0.8), size: 2.8, color: cgColor, weight: .bold)
    }
}
