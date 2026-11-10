import SwiftUI

struct EditorView: View {
    @EnvironmentObject var project: Project

    var body: some View {
        HStack(spacing: 0) {
            ParameterPanel()
                .frame(width: 300)
                .background(.black.opacity(0.18))
            Divider().opacity(0.3)
            ViewportView()
            Divider().opacity(0.3)
            InspectorView()
                .frame(width: 360)
                .background(.black.opacity(0.18))
        }
    }
}

struct ViewportView: View {
    @EnvironmentObject var project: Project

    var scene: SceneData {
        guard let d = project.design else { return SceneData() }
        return SceneBuilder.aircraft(d, project.analysis, deflection: project.deflection, showCG: project.showCG)
    }

    var body: some View {
        ZStack {
            if project.design != nil {
                MetalView(scene: scene,
                          sceneID: project.revision &* 31 &+ Int(project.deflection * 100) &+ (project.showCG ? 1 : 0),
                          resetKey: project.config?.kind.rawValue ?? "",
                          autoRotate: project.autoRotate)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(16)
            if let c = project.config {
                VStack { HStack { Spacer(); ComponentLegend(config: c) }; Spacer() }
                    .padding(.top, 84).padding(.trailing, 20)
                    .allowsHitTesting(false)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { project.config = nil } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32).background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain).help("Back to model gallery")
            VStack(alignment: .leading, spacing: 1) {
                Text(project.config?.name ?? "").font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                Text(project.config?.kind.title ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let a = project.analysis {
                Button { withAnimation { project.inspectorTab = .analysis } } label: { FeasibilityBadge(analysis: a).fixedSize() }
                    .buttonStyle(.plain).help(a.feasible ? "Show analysis" : "Show why it is not feasible and how to fix it")
            }
            Spacer()
            PillButton(title: "Randomize", symbol: "dice.fill", prominent: true) {
                withAnimation(.spring) { project.randomize() }
            }
        }
        .glass(radius: 18, padding: 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle(isOn: $project.showCG) { Label("CG", systemImage: "scope") }
                Toggle(isOn: $project.autoRotate) { Label("Turntable", systemImage: "rotate.3d") }
                Divider().frame(height: 18)
                Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.secondary)
                Text("Surfaces").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Slider(value: $project.deflection, in: -1...1).frame(minWidth: 80, maxWidth: 160)
                Button("Center") { project.deflection = 0 }.buttonStyle(.borderless).font(.system(size: 11))
                Spacer(minLength: 0)
                Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
                    .help("Drag to orbit · right-drag to pan · scroll to zoom · double-click to reset")
            }
            .toggleStyle(.button)
            .font(.system(size: 12, weight: .semibold))
            if let a = project.analysis, let c = project.config {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    StatChip(label: "Span", value: "\(Int(c.wingspan)) mm")
                    StatChip(label: "AUW", value: "\(Int(a.totalMass.rounded())) g", tint: Theme.orange)
                    StatChip(label: "Loading", value: String(format: "%.1f g/dm²", a.wingLoading), tint: Theme.violet)
                    StatChip(label: "CG", value: String(format: "%.0f mm", a.cg.z), tint: Theme.cgColor(a))
                    StatChip(label: "Thrust/W", value: String(format: "%.2f", a.thrustToWeight), tint: a.thrustToWeight >= c.kind.minThrustToWeight ? Theme.good : Theme.warn)
                    StatChip(label: "Flight", value: String(format: "≈%.0f min", a.flightTime), tint: Theme.good)
                }
            }
        }
        .glass(radius: 18, padding: 12)
    }
}

extension Theme {
    static func cgColor(_ a: Analysis) -> Color { a.cgRange.contains(a.cg.z) ? good : warn }
}

struct FeasibilityBadge: View {
    var analysis: Analysis
    var body: some View {
        let sev = analysis.feasible ? (analysis.worst == .warning ? Severity.warning : .ok) : .error
        let text = analysis.feasible ? (sev == .ok ? "Feasible" : "Feasible · check warnings") : "Not feasible"
        HStack(spacing: 6) {
            Image(systemName: Theme.symbol(sev))
            Text(text)
            Text("\(analysis.score)").monospacedDigit().padding(.horizontal, 6).padding(.vertical, 1)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Theme.color(sev))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.color(sev).opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.color(sev).opacity(0.35)))
        .animation(.easeInOut, value: analysis.score)
    }
}


/// Colour key for the 3D view – shows only what the current design contains.
struct ComponentLegend: View {
    var config: AircraftConfig

    private func swatch(_ c: SIMD4<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    var body: some View {
        var items: [(String, SIMD4<Float>)] = [("Motor", Palette.motor), ("Propeller", Palette.prop), ("Battery", Palette.battery), ("Servo", Palette.servo)]
        if !config.aio { items += [("ESC", Palette.esc), ("Receiver", Palette.receiver)] }
        if config.fpv != .none { items += [("FPV camera", Palette.carbon), ("VTX + antenna", Palette.vtx)] }
        if config.aio { items.append(("AIO board", Palette.aio)) }
        items += [("Printed parts", Palette.printed), ("Control surface", Palette.control), ("Carbon", Palette.carbon)]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(swatch(item.1)).frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    Text(item.0).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
