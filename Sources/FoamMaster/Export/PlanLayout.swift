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

    static func make(_ parts: [Part]) -> PlanLayout {
        var best: PlanLayout?
        for cols in 1...4 {
            let width = Double(cols) * tile.x - 4
            var items: [Placed] = []
            for p in parts {
                let b = Poly.bounds(p.outline)
                let sz = b.max - b.min
                // Prefer the wide orientation unless it does not fit.
                var rotate = sz.y > sz.x
                if rotate && sz.y > width { rotate = false }
                if !rotate && sz.x > width && sz.y <= width { rotate = true }
                if rotate && sz.y > width && sz.x <= width { rotate = false }
                let size = rotate ? Vec2(sz.y, sz.x) : sz
                items.append(Placed(part: p, origin: .zero, rotated: rotate, size: size, bmin: b.min, bmax: b.max))
            }
            if items.contains(where: { $0.size.x > width }) && cols < 4 { continue }
            items.sort { $0.size.y > $1.size.y }
            var x = 4.0, y = 4.0, shelf = 0.0
            for i in items.indices {
                if x + items[i].size.x > width && x > 4 { x = 4; y += shelf + gap + labelSpace; shelf = 0 }
                items[i].origin = Vec2(x, y + labelSpace)
                x += items[i].size.x + gap
                shelf = max(shelf, items[i].size.y)
            }
            let height = y + shelf + labelSpace + 4
            let rows = max(1, Int(ceil(height / tile.y)))
            let layout = PlanLayout(placed: items, columns: cols, rows: rows)
            if best == nil || cols * rows < best!.columns * best!.rows { best = layout }
        }
        return best!
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
