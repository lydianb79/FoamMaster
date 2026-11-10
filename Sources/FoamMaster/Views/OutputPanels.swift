import SwiftUI
import AppKit

// MARK: - Plans

struct PlansPanel: View {
    @EnvironmentObject var project: Project
    var design: Design
    var analysis: Analysis

    var body: some View {
        let layout = PlanLayout.make(design.parts)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "1:1 plan on A4", symbol: "doc.richtext")
                PlanPreview(layout: layout, cgZ: analysis.recommendedCG)
                    .aspectRatio(CGFloat(layout.sheet.x / layout.sheet.y), contentMode: .fit)
                    .frame(maxHeight: 420)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    StatChip(label: "Plan pages", value: "\(layout.usedTiles.count)")
                    StatChip(label: "Grid", value: "\(layout.columns) × \(layout.rows)", tint: Theme.violet)
                    StatChip(label: "Total pages", value: "\(layout.usedTiles.count + 4)", tint: Theme.orange)
                }
                Text("Parts are printed at 100 %. Oversized parts are split across pages with registration crosses and a 50 mm scale check on every sheet. Includes cover, BOM and build instructions.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    PillButton(title: "Export PDF", symbol: "square.and.arrow.down", prominent: true) { project.exportPlans() }
                    PillButton(title: "Print…", symbol: "printer") { project.printPlans() }
                }
            }
            .glass()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Parts", symbol: "square.on.square.dashed")
                ForEach(design.parts) { p in
                    HStack {
                        Text(p.name).font(.system(size: 12, weight: .semibold))
                        Text(p.mirroredPair ? "×2 mirrored" : "×\(p.quantity)").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f × %.0f mm", p.size.x, p.size.y)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        Text(String(format: "%.1f g", p.massEach * Double(p.quantity))).font(.system(size: 11, weight: .semibold)).monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    let features = [("slots", p.holes.filter { $0.kind == .slot }.count), ("servo cutouts", p.holes.filter { $0.kind == .servo }.count), ("horn slots", p.holes.filter { $0.kind == .hornSlot }.count)].filter { $0.1 > 0 }
                    if !features.isEmpty {
                        Text(features.map { "\($0.1) \($0.0)" }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Divider().opacity(0.2)
                }
            }
            .glass()
        }
    }
}

struct PlanPreview: View {
    var layout: PlanLayout
    var cgZ: Double

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / layout.sheet.x, size.height / layout.sheet.y)
            ctx.withCGContext { cg in
                cg.scaleBy(x: s, y: s)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                // Page grid
                cg.setStrokeColor(NSColor(calibratedRed: 0.4, green: 0.7, blue: 1, alpha: 0.35).cgColor)
                cg.setLineWidth(0.6 / s)
                cg.setLineDash(phase: 0, lengths: [4 / s, 3 / s])
                for r in 0..<layout.rows {
                    for c in 0..<layout.columns {
                        cg.stroke(CGRect(x: Double(c) * PlanLayout.tile.x, y: Double(r) * PlanLayout.tile.y, width: PlanLayout.tile.x, height: PlanLayout.tile.y))
                    }
                }
                cg.setLineDash(phase: 0, lengths: [])
                for (r, c) in layout.usedTiles {
                    PlanDrawer.text(PlanLayout.tileName(row: r, col: c), at: Vec2(Double(c) * PlanLayout.tile.x + 4, Double(r) * PlanLayout.tile.y + 3), size: 9, color: NSColor(calibratedRed: 0.4, green: 0.7, blue: 1, alpha: 0.5), weight: .heavy)
                }
                for p in layout.placed { PlanDrawer.draw(p, in: cg, cgZ: cgZ, dark: true) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

// MARK: - Materials

struct MaterialsPanel: View {
    var design: Design
    var analysis: Analysis
    var body: some View {
        let items = BuildDocs.billOfMaterials(design, analysis)
        let cats = items.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(cats, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: cat, symbol: icon(cat))
                    ForEach(items.filter { $0.category == cat }) { it in
                        HStack(alignment: .top, spacing: 10) {
                            Text(it.quantity).font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.accent).frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.item).font(.system(size: 12, weight: .semibold))
                                Text(it.spec).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .glass()
            }
        }
    }

    func icon(_ c: String) -> String {
        switch c {
        case "Foam": return "square.stack.3d.up"
        case "Carbon": return "line.diagonal"
        case "Electronics": return "bolt"
        case "3D printed": return "cube"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Build

struct BuildPanel: View {
    var design: Design
    var analysis: Analysis
    @State private var done: Set<Int> = []

    var body: some View {
        let steps = BuildDocs.steps(design, analysis)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Build instructions", symbol: "hammer")
                Text("\(done.count)/\(steps.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.good)
            }
            ProgressView(value: Double(done.count), total: Double(steps.count)).tint(Theme.good)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                Button {
                    withAnimation(.spring(duration: 0.25)) { if done.contains(i) { done.remove(i) } else { done.insert(i) } }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(done.contains(i) ? AnyShapeStyle(Theme.good) : AnyShapeStyle(Theme.accentGradient.opacity(0.25)))
                            if done.contains(i) { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black) }
                            else { Text("\(i + 1)").font(.system(size: 12, weight: .heavy, design: .rounded)) }
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Label(s.title, systemImage: s.symbol).font(.system(size: 13, weight: .bold))
                            Text(s.text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        }
                        .opacity(done.contains(i) ? 0.5 : 1)
                        Spacer(minLength: 0)
                    }
                    .glass(radius: 12, padding: 11)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: design.config.kind) { _, _ in done = [] }
    }
}

// MARK: - 3D print

struct PrintPanel: View {
    @EnvironmentObject var project: Project
    var design: Design

    var body: some View {
        let parts = PrintedParts.generate(design)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Printed hardware", symbol: "cube.transparent")
                MetalView(scene: SceneBuilder.printed(parts), sceneID: project.revision, resetKey: "printed-\(project.config?.kind.rawValue ?? "")", autoRotate: true)
                    .frame(height: 220)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ForEach(parts) { p in
                    HStack {
                        Image(systemName: "cube.fill").foregroundStyle(Theme.good)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 12, weight: .semibold))
                            Text("\(p.fileName).stl · \(p.note)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("×\(p.quantity)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.accent)
                        Text(String(format: "%.1f g", p.mass)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
                PillButton(title: "Export STL files…", symbol: "square.and.arrow.down.on.square", prominent: true) { project.exportSTLs() }
                    .disabled(!(project.analysis?.feasible ?? false))
                if !(project.analysis?.feasible ?? false) {
                    Label("Resolve the feasibility errors before exporting.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
            }
            .glass()
        }
    }
}
