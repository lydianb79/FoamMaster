import Foundation
import AppKit

/// Multi-page A4 PDF: cover + BOM + instructions + 1:1 tiled plans.
enum PlanPDF {
    static let mm = 72.0 / 25.4
    static let pageSize = CGSize(width: 595.28, height: 841.89)

    static func render(_ d: Design, _ a: Analysis) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: d.config.name] as CFDictionary)
        else { return Data() }
        let layout = PlanLayout.make(d.parts)

        func page(_ body: () -> Void) {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: mm, y: -mm)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            body()
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        page { cover(ctx, d, a, layout) }
        let bom = BuildDocs.billOfMaterials(d, a)
        // As many BOM pages as the list needs (rows grow with their wrapped spec text).
        var rest = bom[...]
        repeat {
            var used = 0
            page { used = bomPage(ctx, d, Array(rest), continued: rest.count < bom.count) }
            rest = rest.dropFirst(max(used, 1))
        } while !rest.isEmpty
        let steps = BuildDocs.steps(d, a)
        let half = (steps.count + 1) / 2
        page { stepsPage(ctx, d, Array(steps[..<half]), offset: 0) }
        page { stepsPage(ctx, d, Array(steps[half...]), offset: half) }
        for tile in layout.usedTiles {
            page { tilePage(ctx, d, a, layout, row: tile.row, col: tile.col) }
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: Pages

    static func header(_ title: String, _ d: Design) {
        PlanDrawer.text("FOAMMASTER", at: Vec2(15, 12), size: 3.2, color: .gray, weight: .heavy)
        PlanDrawer.text(title, at: Vec2(15, 17), size: 8, weight: .bold)
        PlanDrawer.text("\(d.config.name) · \(d.config.kind.title) · \(Int(d.config.wingspan)) mm", at: Vec2(15, 28), size: 3.6, color: .darkGray)
    }

    static func cover(_ ctx: CGContext, _ d: Design, _ a: Analysis, _ layout: PlanLayout) {
        let c = d.config
        header("Build Plans", d)
        let f1 = { (v: Double) in String(format: "%.1f", v) }
        let rows: [(String, String)] = [
            ("Wingspan", "\(Int(c.wingspan)) mm"), ("Length", "\(Int(d.overallLength.rounded())) mm"), ("Wing area", "\(f1(a.wingArea / 1e4)) dm²"),
            ("Aspect ratio", f1(a.aspectRatio)), ("All-up weight", "\(Int(a.totalMass.rounded())) g"),
            ("Wing loading", "\(f1(a.wingLoading)) g/dm²"), ("Material", c.material.displayName),
            ("CG (from root LE)", "\(Int(a.recommendedCG.rounded())) mm  (\(Int(a.cgRange.lowerBound))–\(Int(a.cgRange.upperBound)))"),
            ("Battery position", "\(Int(c.batteryPosition)) mm from LE"),
            ("Propeller", c.propRecommendation),
            ("Thrust / weight", f1(a.thrustToWeight)), ("Stall speed", "≈\(Int(a.stallSpeed)) km/h"),
            ("Flight time", "≈\(Int(a.flightTime)) min"), ("Feasibility", a.feasible ? "PASSED (score \(a.score))" : "NOT FEASIBLE")
        ]
        for (i, r) in rows.enumerated() {
            let y = 42 + Double(i) * 6.0
            PlanDrawer.text(r.0, at: Vec2(15, y), size: 3.6, color: .darkGray)
            PlanDrawer.text(r.1, at: Vec2(70, y), size: 3.6, weight: .semibold)
        }

        // Scale check
        let sy = 140.0
        PlanDrawer.text("SCALE CHECK – must measure exactly 100 mm", at: Vec2(15, sy - 6), size: 3.2, weight: .bold)
        PlanDrawer.line(ctx, Vec2(15, sy + 2), Vec2(115, sy + 2), color: .black, width: 0.5)
        for i in 0...10 {
            let x = 15 + Double(i) * 10
            PlanDrawer.line(ctx, Vec2(x, sy + 2), Vec2(x, sy + (i % 5 == 0 ? -2 : 0)), color: .black, width: 0.3)
        }
        ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(0.4)
        ctx.stroke(CGRect(x: 130, y: sy - 8, width: 50, height: 50))
        PlanDrawer.text("50 × 50 mm", at: Vec2(143, sy + 15), size: 3)
        // How to read the measurements on the plan pages.
        PlanDrawer.text("MEASUREMENTS (mm)", at: Vec2(15, sy + 12), size: 3.2, weight: .bold)
        for (i, l) in ["Overall length under each part, height beside it.",
                       "Edge lengths along each straight edge; HINGE = hinge length.",
                       "Every cutout / slot / horn slot and placement mark (battery,",
                       "ESC, RX = receiver, motor mount, joiner pocket, strut anchor):",
                       "distance to the nearest part edge or mark, across and along.",
                       "Servo cutouts: width × height. Spar ends: “x · y” from the",
                       "part's left and top edge."].enumerated() {
            PlanDrawer.text(l, at: Vec2(15, sy + 17 + Double(i) * 4.0), size: 2.9)
        }

        // Legend
        let ly = 205.0
        PlanDrawer.text("LEGEND", at: Vec2(15, ly - 6), size: 3.4, weight: .bold)
        let legend: [(NSColor, String, [CGFloat])] = [
            (.black, "Cut line (through)", []), (PlanDrawer.hingeColor, "Hinge line – bevel 45° underneath, tape on top", [2, 1.2]),
            (PlanDrawer.sparColor, "Carbon rod spar (groove underneath) / boom groove", [3, 1.5]), (.gray, "Component zone", [1.5, 1.5]),
            (PlanDrawer.hornColor, "Horn position – flange outline, ○ = pushrod hole over the hinge", [1, 0.8])
        ]
        for (i, l) in legend.enumerated() {
            let y = ly + Double(i) * 6
            PlanDrawer.line(ctx, Vec2(15, y + 2), Vec2(30, y + 2), color: l.0, width: 0.4, dash: l.2)
            PlanDrawer.text(l.1, at: Vec2(34, y), size: 3.2)
        }
        let swatches: [(NSColor, String)] = [(PlanDrawer.servoColor.withAlphaComponent(0.35), "Servo cutout"), (.gray, "Slot for tab / wing"), (.black, "Horn slot")]
        for (i, s) in swatches.enumerated() {
            let y = ly + 30 + Double(i) * 6
            ctx.setFillColor(s.0.cgColor); ctx.fill(CGRect(x: 15, y: y, width: 15, height: 4))
            PlanDrawer.text(s.1, at: Vec2(34, y), size: 3.2)
        }
        PlanDrawer.drawCG(ctx, Vec2(120, ly + 2))
        PlanDrawer.text("Balance point (marked on wing & fuselage)", at: Vec2(128, ly + 6), size: 3)
        // Right column below the line legend (kept clear of the long legend lines on the left).
        PlanDrawer.drawStrutAnchor(ctx, map: { $0 }, center: Vec2(116, ly + 33), dir: Vec2(1, 0), size: Vec2(9, 7), label: "S1")
        PlanDrawer.text("Strut anchor – glue the printed anchor on the", at: Vec2(132, ly + 29), size: 3)
        PlanDrawer.text("pad, arrow = rod direction (S1 L/R …)", at: Vec2(132, ly + 33.5), size: 3)
        PlanDrawer.text("Fine dashed box to the edge = one-piece saddle", at: Vec2(132, ly + 38), size: 3)
        PlanDrawer.text("V-notches = alignment marks · tabs fit matching slots", at: Vec2(110, ly + 44), size: 3)


        // Tile map
        let my = 262.0
        PlanDrawer.text("PAGE MAP – \(layout.usedTiles.count) plan pages (print at 100 %, no scaling)", at: Vec2(15, my - 6), size: 3.2, weight: .bold)
        let cell = min(10.0, 30.0 / Double(layout.rows))
        let used = Set(layout.usedTiles.map { "\($0.row)-\($0.col)" })
        for r in 0..<layout.rows {
            for col in 0..<layout.columns {
                let rect = CGRect(x: 15 + Double(col) * cell * 0.7, y: my + Double(r) * cell, width: cell * 0.7, height: cell)
                ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(0.25); ctx.stroke(rect)
                if used.contains("\(r)-\(col)") {
                    PlanDrawer.text(PlanLayout.tileName(row: r, col: col), at: Vec2(rect.midX, rect.midY - 1.5), size: 2.6, centered: true)
                }
            }
        }
    }

    /// Draws BOM rows until the page is full; returns how many items were drawn.
    @discardableResult
    static func bomPage(_ ctx: CGContext, _ d: Design, _ items: [BOMItem], continued: Bool = false) -> Int {
        header(continued ? "Bill of Materials (continued)" : "Bill of Materials", d)
        var y = 40.0
        var lastCat = ""
        for (i, it) in items.enumerated() {
            let spec = NSAttributedString(string: it.spec, attributes: [.font: NSFont.systemFont(ofSize: 2.8), .foregroundColor: NSColor.darkGray])
            let specH = spec.boundingRect(with: NSSize(width: 88, height: 200), options: [.usesLineFragmentOrigin]).height
            let rowH = max(7.5, specH + 2.5)
            let catH = it.category != lastCat ? 9.0 : 0
            if i > 0 && y + catH + rowH > 285 { return i }
            if it.category != lastCat {
                y += 3
                PlanDrawer.text(it.category.uppercased(), at: Vec2(15, y), size: 3.2, color: .gray, weight: .heavy)
                y += 6; lastCat = it.category
            }
            PlanDrawer.text(it.quantity, at: Vec2(15, y), size: 3.2, weight: .semibold)
            PlanDrawer.text(it.item, at: Vec2(38, y), size: 3.2, weight: .semibold)
            spec.draw(with: NSRect(x: 110, y: y, width: 88, height: specH + 1), options: [.usesLineFragmentOrigin])
            y += rowH
        }
        return items.count
    }

    static func stepsPage(_ ctx: CGContext, _ d: Design, _ steps: [BuildStep], offset: Int) {
        header("Build Instructions", d)
        var y = 42.0
        for (i, s) in steps.enumerated() {
            ctx.setFillColor(NSColor(calibratedRed: 0.1, green: 0.45, blue: 0.95, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 15, y: y - 0.5, width: 8, height: 8))
            PlanDrawer.text("\(offset + i + 1)", at: Vec2(19, y + 0.8), size: 4, color: .white, weight: .bold, centered: true)
            PlanDrawer.text(s.title, at: Vec2(28, y), size: 4.4, weight: .bold)
            let body = NSAttributedString(string: s.text, attributes: [.font: NSFont.systemFont(ofSize: 3.4), .foregroundColor: NSColor.darkGray])
            let rect = body.boundingRect(with: NSSize(width: 165, height: 200), options: [.usesLineFragmentOrigin])
            body.draw(with: NSRect(x: 28, y: y + 7, width: 165, height: rect.height + 2), options: [.usesLineFragmentOrigin])
            y += 12 + rect.height + 6
        }
    }

    static func tilePage(_ ctx: CGContext, _ d: Design, _ a: Analysis, _ layout: PlanLayout, row: Int, col: Int) {
        let m = PlanLayout.margin, t = PlanLayout.tile
        let origin = Vec2(Double(col) * t.x, Double(row) * t.y)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: m.x, y: m.y, width: t.x, height: t.y))
        ctx.translateBy(x: m.x - origin.x, y: m.y - origin.y)
        for p in layout.placed { PlanDrawer.draw(p, in: ctx, cgZ: a.recommendedCG) }
        ctx.restoreGState()

        // Frame, registration crosses, labels
        ctx.setStrokeColor(NSColor.gray.cgColor); ctx.setLineWidth(0.2)
        ctx.setLineDash(phase: 0, lengths: [1, 1])
        ctx.stroke(CGRect(x: m.x, y: m.y, width: t.x, height: t.y))
        ctx.setLineDash(phase: 0, lengths: [])
        for cx in [m.x, m.x + t.x] {
            for cy in [m.y, m.y + t.y] {
                PlanDrawer.line(ctx, Vec2(cx - 4, cy), Vec2(cx + 4, cy), color: .black, width: 0.25)
                PlanDrawer.line(ctx, Vec2(cx, cy - 4), Vec2(cx, cy + 4), color: .black, width: 0.25)
            }
        }
        let name = PlanLayout.tileName(row: row, col: col)
        PlanDrawer.text("\(d.config.name) – page \(name)  (column \(col + 1)/\(layout.columns), row \(row + 1)/\(layout.rows))",
                        at: Vec2(m.x + 6, 3.5), size: 2.8, color: .darkGray)
        PlanDrawer.text(name, at: Vec2(m.x + t.x - 12, 2.5), size: 5, weight: .heavy)
        // 50 mm scale check in the bottom margin
        let sy = m.y + t.y + 5
        PlanDrawer.line(ctx, Vec2(m.x + 6, sy), Vec2(m.x + 56, sy), color: .black, width: 0.4)
        PlanDrawer.line(ctx, Vec2(m.x + 6, sy - 1.5), Vec2(m.x + 6, sy + 1.5), color: .black, width: 0.3)
        PlanDrawer.line(ctx, Vec2(m.x + 56, sy - 1.5), Vec2(m.x + 56, sy + 1.5), color: .black, width: 0.3)
        PlanDrawer.text("50 mm", at: Vec2(m.x + 60, sy - 1.6), size: 2.6)
        if col + 1 < layout.columns { PlanDrawer.text("→ \(PlanLayout.tileName(row: row, col: col + 1))", at: Vec2(m.x + t.x + 0.8, m.y + t.y / 2), size: 2.4, color: .gray) }
        if row + 1 < layout.rows { PlanDrawer.text("↓ \(PlanLayout.tileName(row: row + 1, col: col))", at: Vec2(m.x + t.x / 2, m.y + t.y + 3.2), size: 2.4, color: .gray) }
    }
}
