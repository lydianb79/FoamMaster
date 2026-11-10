import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case analysis = "Analysis", plans = "Plans", materials = "Materials", build = "Build", printed = "3D Print"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .analysis: return "gauge.with.dots.needle.67percent"
        case .plans: return "doc.richtext"
        case .materials: return "shippingbox"
        case .build: return "hammer"
        case .printed: return "cube.transparent"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var project: Project
    private var tab: InspectorTab { project.inspectorTab }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { t in
                    Button { withAnimation(.spring(duration: 0.25)) { project.inspectorTab = t } } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 14, weight: .semibold))
                            Text(t.rawValue).font(.system(size: 9.5, weight: .bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundStyle(tab == t ? .black : .secondary)
                        .background {
                            if tab == t { RoundedRectangle(cornerRadius: 9).fill(Theme.accentGradient) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .padding(14)

            if let d = project.design, let a = project.analysis {
                ScrollView {
                    Group {
                        switch tab {
                        case .analysis: AnalysisPanel(design: d, analysis: a)
                        case .plans: PlansPanel(design: d, analysis: a)
                        case .materials: MaterialsPanel(design: d, analysis: a)
                        case .build: BuildPanel(design: d, analysis: a)
                        case .printed: PrintPanel(design: d)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - Analysis

struct AnalysisPanel: View {
    @EnvironmentObject var project: Project
    var design: Design
    var analysis: Analysis

    var body: some View {
        let a = analysis
        VStack(alignment: .leading, spacing: 14) {
            if !a.feasible { InfeasibleCard(analysis: a) }
            HStack(spacing: 16) {
                ScoreRing(score: a.score, feasible: a.feasible).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.feasible ? "Buildable design" : "Not feasible")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(a.feasible ? Theme.good : Theme.bad)
                    Text("\(a.checks.filter { $0.severity == .error }.count) errors · \(a.checks.filter { $0.severity == .warning }.count) warnings")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(String(format: "Stall ≈ %.0f km/h · AR %.1f", a.stallSpeed, a.aspectRatio))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .glass()

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Centre of gravity", symbol: "scope")
                CGBar(analysis: a).frame(height: 54)
                HStack {
                    StatChip(label: "Current", value: String(format: "%.1f mm", a.cg.z), tint: Theme.cgColor(a))
                    StatChip(label: "Target", value: String(format: "%.1f mm", a.recommendedCG), tint: Theme.good)
                    StatChip(label: "Margin", value: String(format: "%.0f %%", a.staticMargin * 100), tint: Theme.violet)
                }
                Text(String(format: "Measured from the root leading edge. Neutral point %.1f mm, MAC %.0f mm.", a.neutralPoint, a.mac))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if !a.cgReachable {
                    HStack {
                        Label("The battery alone cannot balance this design.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warn)
                        Spacer()
                        PillButton(title: "Fix with bigger battery", symbol: "battery.100.bolt", prominent: true) { withAnimation { project.fixBalanceWithBattery() } }
                    }
                }
                if let note = project.balanceNote {
                    Label(note, systemImage: "info.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .glass()

            if let st = a.structure { StructureCard(report: st, config: design.config) }
            ControlsCard(design: design)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Weight breakdown", symbol: "scalemass")
                WeightBars(design: design, analysis: a)
            }
            .glass()

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Feasibility checks", symbol: "checklist")
                ForEach(a.checks) { ch in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Theme.symbol(ch.severity)).foregroundStyle(Theme.color(ch.severity)).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ch.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(ch.category.uppercased()).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
                            }
                            Text(ch.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(9)
                    .background(Theme.color(ch.severity).opacity(ch.severity >= .warning ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .glass()
        }
    }
}

struct ScoreRing: View {
    var score: Int
    var feasible: Bool
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(AngularGradient(colors: feasible ? [Theme.accent, Theme.good, Theme.accent] : [Theme.bad, Theme.orange, Theme.bad], center: .center),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text("\(score)").font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("SCORE").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
        }
    }
}

struct CGBar: View {
    var analysis: Analysis
    var body: some View {
        GeometryReader { g in
            let a = analysis
            let lo = min(a.cgRange.lowerBound, a.cg.z, a.macLE) - 10
            let hi = max(a.cgRange.upperBound, a.cg.z, a.macLE + a.mac * 0.6) + 10
            let x = { (z: Double) in CGFloat((z - lo) / (hi - lo)) * g.size.width }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)).frame(height: 22).offset(y: 10)
                RoundedRectangle(cornerRadius: 6).fill(Theme.good.opacity(0.25))
                    .frame(width: max(2, x(a.cgRange.upperBound) - x(a.cgRange.lowerBound)), height: 22)
                    .offset(x: x(a.cgRange.lowerBound), y: 10)
                Rectangle().fill(Theme.good).frame(width: 2, height: 30).offset(x: x(a.recommendedCG) - 1, y: 6)
                Rectangle().fill(Theme.violet.opacity(0.8)).frame(width: 2, height: 30).offset(x: x(a.neutralPoint) - 1, y: 6)
                Circle().fill(Color(red: 1, green: 0.25, blue: 0.6)).frame(width: 14, height: 14)
                    .shadow(color: .pink, radius: 6).offset(x: x(a.cg.z) - 7, y: 14)
                    .animation(.spring(duration: 0.4), value: a.cg.z)
                Text("NP").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.violet).offset(x: x(a.neutralPoint) - 6, y: 40)
                Text("target").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.good).offset(x: x(a.recommendedCG) - 12, y: -6)
            }
        }
    }
}

struct WeightBars: View {
    var design: Design
    var analysis: Analysis
    var body: some View {
        let groups = Dictionary(grouping: design.components, by: \.category).mapValues { $0.reduce(0) { $0 + $1.mass } }
        let rows = [("Foam", analysis.foamMass)] + groups.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let maxV = rows.map(\.1).max() ?? 1
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 8) {
                    Text(r.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.accentGradient).frame(width: max(4, g.size.width * r.1 / maxV))
                    }
                    .frame(height: 8)
                    Text(String(format: "%.1f g", r.1)).font(.system(size: 11, weight: .semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            Divider().opacity(0.3)
            HStack {
                Text("All-up weight").font(.system(size: 12, weight: .bold))
                Spacer()
                Text(String(format: "%.1f g", analysis.totalMass)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.orange)
            }
        }
    }
}


// MARK: - Infeasible explanation

struct InfeasibleCard: View {
    @EnvironmentObject var project: Project
    var analysis: Analysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                Text("Why it’s not feasible").font(.system(size: 14, weight: .bold))
            }
            ForEach(analysis.checks.filter { $0.severity == .error }) { ch in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ch.title).font(.system(size: 12, weight: .semibold))
                    Text(ch.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bad.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider().opacity(0.3)
            HStack {
                SectionHeader(title: "Suggested changes", symbol: "wand.and.stars")
                if project.findingFixes { ProgressView().controlSize(.small) }
            }
            if !project.findingFixes && project.fixes.isEmpty {
                Text("No single change fixes this – combine the hints above.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(project.fixes) { fix in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: fix.solvesAll ? "checkmark.seal.fill" : "circle.lefthalf.filled")
                        .foregroundStyle(fix.solvesAll ? Theme.good : Theme.warn)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fix.title).font(.system(size: 12, weight: .semibold))
                        Text(fix.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Apply") { withAnimation { project.apply(fix) } }
                        .buttonStyle(.borderedProminent).tint(fix.solvesAll ? Theme.good : Theme.accent).controlSize(.small)
                }
            }
        }
        .glass()
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.bad.opacity(0.45)))
    }
}

struct StructureCard: View {
    var report: StructureReport
    var config: AircraftConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Structure (beam model)", symbol: "building.columns")
            Text("Load case: full deflection at \(Int(report.loadSpeed)) km/h, wing at 3 g.").font(.system(size: 10)).foregroundStyle(.tertiary)
            Meter(label: "Wing tip deflection", value: report.wingDeflectionRatio * 100, unit: "%", good: 4, bad: 10,
                  detail: String(format: "%.1f mm", report.wingTipDeflection))
            if let twist = report.tailTwistDeg {
                Meter(label: "Fuselage twist (rudder)", value: twist, unit: "°", good: 3, bad: 6, detail: config.kind.isTwinBoom ? "twin booms" : config.fuselageType.name)
            }
            if let bend = report.tailBendDeg {
                Meter(label: "Tail bend (elevator)", value: bend, unit: "°", good: 1, bad: 3, detail: "carbon chords")
            }
        }
        .glass()
    }
}

struct Meter: View {
    var label: String
    var value: Double
    var unit: String
    var good: Double
    var bad: Double
    var detail: String

    var body: some View {
        let color = value < good ? Theme.good : (value < bad ? Theme.warn : Theme.bad)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: value < 10 ? "%.1f" : "%.0f", value) + " " + unit).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(color)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(Theme.good.opacity(0.25)).frame(width: g.size.width * good / (bad * 1.5))
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(value / (bad * 1.5), 1)))
                }
            }
            .frame(height: 6)
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }
}

struct ControlsCard: View {
    var design: Design
    var body: some View {
        let groups = Dictionary(grouping: design.controls, by: \.servoID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Controls & servos", symbol: "gearshape.2")
                Text("\(design.controls.surfaceCount) surfaces · \(groups.count) servos").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
            }
            ForEach(groups.keys.sorted(), id: \.self) { servo in
                HStack(alignment: .top) {
                    Image(systemName: "gearshape.fill").font(.system(size: 10)).foregroundStyle(Theme.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Servo: \(servo)").font(.system(size: 11.5, weight: .semibold))
                        Text(groups[servo]!.map(\.name).joined(separator: " + ") + linkNote(servo, groups[servo]!.count))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .glass()
    }

    func linkNote(_ servo: String, _ n: Int) -> String {
        if servo.contains("torque") { return " · one servo, torque rods" }
        if servo == "Rudders" { return " · twin rudders linked by a wire" }
        if servo == "Elevator" && design.config.kind.isTwinBoom { return " · elevator halves joined" }
        return ""
    }
}

extension Array where Element == ControlSurface {
    /// Physical surfaces (split elevator halves and twin rudders count separately).
    var surfaceCount: Int {
        reduce(0) { n, c in n + ((c.name == "Rudders" || (c.name == "Elevator")) ? 2 : 1) }
    }
}
