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
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var project: Project
    /// Object under the mouse in the 3D view and where the mouse is.
    @State private var hoverName: String?
    @State private var hoverPoint = CGPoint.zero

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
                          autoRotate: project.autoRotate,
                          motorOn: project.motorOn,
                          onHover: { name, point in
                              if hoverName != name { hoverName = name }
                              hoverPoint = point
                          })
            }
            if let hoverName {
                // Hover label next to the cursor naming the part under it.
                Text(hoverName)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15)))
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in -(hoverPoint.x + 14) }
                    .alignmentGuide(.top) { _ in -(hoverPoint.y + 16) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(16)
            if let c = project.config {
                VStack { HStack { Spacer(); ComponentLegend(config: c, struts: project.design?.struts ?? []) }; Spacer() }
                    .padding(.top, 84).padding(.trailing, 20)
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
            PillButton(title: "Fly", symbol: "airplane.departure") {
                // The simulator flies the design on screen now (also when its window was open before, or reused).
                NotificationCenter.default.post(name: .flyDesign, object: nil)
                openWindow(id: "simulator")
            }
                .help("Fly this design in the flight simulator (line of sight, keyboard or USB transmitter)")
            PillButton(title: "Save", symbol: "square.and.arrow.down") { project.saveDesign() }
                .help("Save this design (⌘S) – Save As: ⇧⌘S, open: ⌘O")
            PillButton(title: project.randomizing ? "Randomizing …" : "Randomize", symbol: project.randomizing ? "hourglass" : "dice.fill", prominent: true) {
                withAnimation(.spring) { project.randomize() }
            }
            .disabled(project.randomizing)
            .help("Random variant of this type that passes every check (score 100)")
        }
        .glass(radius: 18, padding: 10)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle(isOn: $project.showCG) { Label("CG", systemImage: "scope") }
                Toggle(isOn: $project.autoRotate) { Label("Turntable", systemImage: "rotate.3d") }
                Toggle(isOn: $project.motorOn) { Label("Motor", systemImage: "fanblades.fill") }
                    .help("Run the motor: the propeller\(project.config?.isDual == true ? "s spin (counter-rotating)" : " spins") in the 3D view")
                Divider().frame(height: 18)
                Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.secondary)
                Text("Surfaces").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Slider(value: $project.deflection, in: -1...1).frame(minWidth: 80, maxWidth: 160)
                    .help("Control-surface preview up to the full throw, like the stick moved sideways: right = right aileron / elevon up, left one down, rudder right, elevator down; left = left aileron / elevon up, right one down, rudder left, elevator up. Horns, pushrods and servo arms follow.")
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
                    if let d = project.design { StatChip(label: "Length", value: "\(Int(d.overallLength.rounded())) mm") }
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


/// Colour key for the 3D view – shows only what the current design contains. Hovering an entry explains it.
struct ComponentLegend: View {
    var config: AircraftConfig
    var struts: [Strut] = []
    @State private var hovered: String?

    private func swatch(_ c: SIMD4<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    private var items: [(name: String, color: SIMD4<Float>, detail: String)] {
        let c = config
        let esc = "\(c.motor.escMass > 4 ? 12 : 6) A brushless ESC\(c.isDual ? " (one per motor)" : ""), taped where the motor leads reach"
        var list: [(String, SIMD4<Float>, String)] = [
            ("Foam", c.material.family == .depron ? Palette.depron : Palette.epp, "\(c.material.displayName) – all flat foam parts"),
            ("Control surface", Palette.control, "Hinged \(c.kind.isTailless ? "elevons" : (c.hasAilerons ? "ailerons, elevator\(c.hasRudder ? " and rudder" : "")" : "elevator\(c.hasRudder ? " and rudder" : "")")) – the Surfaces slider previews the throw"),
            ("Motor", Palette.motor, "\(c.motorCount) × \(c.motor.name) – stator base, red bell, shaft · \(c.motor.pattern.label) mount"),
            ("Propeller", Palette.prop, c.propRecommendation),
            ("Battery", Palette.battery, "\(c.battery.name), \(Int(c.battery.mass)) g on a printed tray – move it to balance"),
            ("Servo", Palette.servo, "\(c.servo.name), glued into flush cutouts"),
            ("ESC", Palette.esc, esc),
            ("Receiver", Palette.receiver, "Micro receiver, taped to the fuselage / wing"),
            ("Servo arm", Palette.linkage, "Servo arms as supplied with the servos (no STL)"),
            ("Pushrod", Palette.steel, "Ø1 mm carbon rods with Ø0.8 mm steel-wire Z-bend ends, joined with heat-shrink (red)"),
            ("Printed parts", Palette.printed, "Motor mount, horns, battery tray – exported as STL"),
        ]
        if c.sparEnabled || c.kind.isTwinBoom || !struts.isEmpty {
            list.append(("Carbon", Palette.carbon, [c.sparEnabled ? "\(c.sparSpec.name) wing spar" : nil, c.kind.isTwinBoom ? "\(CarbonSpar.tube4.name) tail booms" : nil,
                                                     struts.isEmpty ? nil : "\(struts.count) stabilisation struts in printed anchors"].compactMap { $0 }.joined(separator: " · ")))
        }
        list.append(("Centre of gravity", Palette.cg, "Pink ball = current CG, green line = target, faint lines = allowed range (toggle with CG)"))
        return list
    }

    var body: some View {
        let list = items
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.name) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(swatch(item.color)).frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    Text(item.name).font(.system(size: 10, weight: hovered == item.name ? .bold : .medium))
                        .foregroundStyle(hovered == item.name ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onHover { h in hovered = h ? item.name : (hovered == item.name ? nil : hovered) }
                .help(item.detail)
            }
            if let h = hovered, let item = list.first(where: { $0.name == h }) {
                Text(item.detail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            } else {
                Text("Hover the model to name a part").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 3)
            }
        }
        .padding(10)
        .frame(width: 170, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
