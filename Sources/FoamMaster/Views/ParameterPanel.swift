import SwiftUI

struct ParameterPanel: View {
    /// The scroll area starts below the window's traffic-light buttons (hidden title bar), so cards never
    /// scroll underneath them.
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 30)
            ScrollView { ParameterContent() }
                .clipped()
        }
    }
}

struct ParameterContent: View {
    @EnvironmentObject var project: Project
    private var lastConfig: AircraftConfig { project.lastConfig ?? AircraftKind.trainer.defaults }

    /// Binding for a power-system choice: picking one by hand switches the automatic selection off.
    func manual<T>(_ kp: WritableKeyPath<AircraftConfig, T>) -> Binding<T> {
        let b = bind(kp)
        return Binding(get: { b.wrappedValue }, set: { v in
            if project.config != nil { project.config!.autoPower = false; project.config![keyPath: kp] = v }
        })
    }

    func bind<T>(_ kp: WritableKeyPath<AircraftConfig, T>) -> Binding<T> {
        // The editor stays on screen briefly while fading out after "Back", when config is already nil.
        let fallback = project.config ?? lastConfig
        return Binding(get: { project.config?[keyPath: kp] ?? fallback[keyPath: kp] },
                       set: { if project.config != nil { project.config![keyPath: kp] = $0 } })
    }

    var body: some View {
        if let c = project.config {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Model", symbol: "tag.fill")
                        TextField("Name", text: bind(\.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Wing", symbol: "airplane")
                        ParamSlider(label: c.kind.isNutBall ? "Width (span)" : "Wingspan", unit: "mm", value: bind(\.wingspan), range: range(\.wingspan, c), step: 5)
                        ParamSlider(label: c.kind.isNutBall ? "Length" : "Root chord", unit: "mm", value: bind(\.rootChord), range: range(\.rootChord, c), step: 1)
                        if c.kind.isNutBall {
                            ParamSlider(label: "Elevator depth", unit: "%",
                                        value: Binding(get: { c.controlChordPct * 100 }, set: { project.config?.controlChordPct = $0 / 100 }),
                                        range: 12...40, step: 1)
                        } else {
                            ParamSlider(label: "Tip chord", unit: "mm", value: bind(\.tipChord), range: range(\.tipChord, c), step: 1)
                            ParamSlider(label: "Sweep (tip LE)", unit: "mm", value: bind(\.sweep), range: range(\.sweep, c), step: 1)
                            if c.kind.hasTail {
                                ParamSlider(label: "Wing tip rounding", unit: "mm", value: bind(\.wingTipRounding),
                                            range: 0...max(5, (c.tipChord * 0.45).rounded()), step: 1)
                            }
                        }
                        if c.kind.isTailless || c.hasAilerons {
                            ParamSlider(label: c.kind.isTailless ? "Elevon chord" : "Aileron chord", unit: "%",
                                        value: Binding(get: { c.controlChordPct * 100 }, set: { project.config?.controlChordPct = $0 / 100 }),
                                        range: 12...40, step: 1)
                        }
                        if c.kind.isTailless {
                            Picker("", selection: bind(\.taillessFins)) {
                                ForEach(TaillessFins.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            if c.taillessFins == .finAndWinglets {
                                ParamSlider(label: "Centre fin height", unit: "mm", value: bind(\.centreFinHeight), range: range(\.centreFinHeight, c), step: 1)
                            }
                            if c.taillessFins != .none {
                                ParamSlider(label: c.taillessFins == .centreFin ? "Fin height" : "Winglet height", unit: "mm", value: bind(\.wingletHeight), range: range(\.wingletHeight, c), step: 1)
                            }
                            if c.taillessFins.hasCentreFin {
                                ParamSlider(label: "Fin position (LE from nose)", unit: "mm", value: bind(\.finPosition), range: 0...max(10, c.rootChord * 0.58 - c.motorNotchDepth - 4), step: 1)
                            }
                        }
                    }
                    .glass()

                    if c.kind.isNutBall {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Spine & fin", symbol: "arrow.left.and.right")
                            ParamSlider(label: "Motor ahead of the disc", unit: "mm", value: bind(\.noseLength), range: range(\.noseLength, c), step: 1)
                            ParamSlider(label: "Spine + keel height", unit: "mm", value: bind(\.fuselageHeight), range: range(\.fuselageHeight, c), step: 1)
                            ParamSlider(label: "Fin height", unit: "mm", value: bind(\.vStabHeight), range: range(\.vStabHeight, c), step: 1)
                            ParamSlider(label: "Fin chord", unit: "mm", value: bind(\.vStabChord), range: range(\.vStabChord, c), step: 1)
                            ParamSlider(label: "Rudder / fin top rounding", unit: "mm", value: bind(\.finTopRounding),
                                        range: 0...max(5, (c.vStabChord * 0.5).rounded()), step: 1)
                        }
                        .glass()
                    } else if !c.kind.isTailless {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: c.kind.isTwinBoom ? "Pod, booms & tail" : "Fuselage & Tail", symbol: "arrow.left.and.right")
                            ParamSlider(label: c.kind.isTwinBoom ? "Pod nose length" : "Nose length", unit: "mm", value: bind(\.noseLength), range: range(\.noseLength, c), step: 1)
                            ParamSlider(label: c.kind.isTwinBoom ? "Pod height" : "Fuselage height", unit: "mm", value: bind(\.fuselageHeight), range: range(\.fuselageHeight, c), step: 1)
                            if c.kind.hasFuselage {
                                // The cross can only be made wider than the default – narrower would cost torsional stiffness.
                                ParamSlider(label: "Fuselage cross width", unit: "mm",
                                            value: Binding(get: { c.fuselagePlateWidth }, set: { project.config?.plateWidthExtra = max(0, $0 - c.basePlateWidth) }),
                                            range: c.basePlateWidth...(c.basePlateWidth + AircraftConfig.maxPlateWidthExtra), step: 1)
                            }
                            ParamSlider(label: "Tail arm", unit: "mm", value: bind(\.tailArm), range: range(\.tailArm, c), step: 1)
                            ParamSlider(label: c.kind.isTwinBoom ? "Stab span (boom spacing)" : "Stab span", unit: "mm", value: bind(\.hStabSpan), range: range(\.hStabSpan, c), step: 1)
                            ParamSlider(label: "Stab chord", unit: "mm", value: bind(\.hStabChord), range: range(\.hStabChord, c), step: 1)
                            ParamSlider(label: "Stab sweep (− = forward)", unit: "mm", value: bind(\.hStabSweep), range: c.stabSweepLimits, step: 1)
                            ParamSlider(label: "Fin height", unit: "mm", value: bind(\.vStabHeight), range: range(\.vStabHeight, c), step: 1)
                            ParamSlider(label: "Fin chord", unit: "mm", value: bind(\.vStabChord), range: range(\.vStabChord, c), step: 1)
                            ParamSlider(label: c.hasRudder ? "Rudder / fin top rounding" : "Fin top rounding", unit: "mm", value: bind(\.finTopRounding),
                                        range: 0...max(5, (c.vStabChord * 0.5).rounded()), step: 1)
                            if !c.kind.isTwinBoom {
                                ParamSlider(label: "Elevator tip rounding", unit: "mm", value: bind(\.stabTipRounding),
                                            range: 0...max(5, (c.hStabChord * 0.4).rounded()), step: 1)
                            }
                        }
                        .glass()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Build options", symbol: "slider.horizontal.3")
                        if c.kind.allowsDualMotors {
                            Picker("", selection: bind(\.motorLayout)) {
                                ForEach(MotorLayout.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        if c.kind.offersWinglets {
                            Toggle(isOn: bind(\.tailWinglets)) { Text("Winglets").font(.system(size: 12, weight: .semibold)) }
                                .toggleStyle(.switch).tint(Theme.accent)
                            if c.tailWinglets {
                                ParamSlider(label: "Winglet height", unit: "mm", value: bind(\.wingletHeight), range: range(\.wingletHeight, c), step: 1)
                            }
                        }
                        if c.kind.hasTail && !c.kind.isTwinBoom {
                            Picker("", selection: Binding(get: { ControlLayout(ailerons: true, rudder: c.rudder) },
                                                          set: { project.config?.ailerons = $0.ailerons; project.config?.rudder = $0.rudder })) {
                                Text("A + E").tag(ControlLayout.aileronElevator)
                                Text("A + E + R").tag(ControlLayout.full)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .help("Control layout: rudder, ailerons, elevator")
                        }
                        if c.hasAilerons && c.kind.allowsSingleAileronServo {
                            Picker("", selection: bind(\.aileronServos)) {
                                Text("1 aileron servo").tag(1)
                                Text("2 aileron servos").tag(2)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Electronics", symbol: "bolt.fill")
                        Toggle(isOn: bind(\.autoPower)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Auto power system").font(.system(size: 12, weight: .semibold))
                                Text(project.findingPower ? "Finding the best motor, ESC, prop and battery…"
                                     : (c.autoPower ? "Motor, ESC, prop and battery follow the airframe (T/W ≥ \(String(format: "%.2f", c.kind.recommendedThrustToWeight)), ≥ 6 min)"
                                                     : "Off – picking a motor or battery yourself switches it off"))
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch).tint(Theme.accent)
                        PickerRow(label: "Motor", selection: manual(\.motor), options: MotorClass.allCases) { $0.name }
                        PickerRow(label: "Battery", selection: manual(\.battery), options: BatteryPack.allCases) { "\($0.name) · \(Int($0.mass)) g" }
                        PickerRow(label: "Servos", selection: bind(\.servo), options: ServoClass.allCases) { $0.name }
                        if let d = project.design, let a = project.analysis {
                            // Full electronics list – the same items as under Materials ▸ Electronics.
                            Divider().opacity(0.3).padding(.vertical, 2)
                            ElectronicsList(design: d, analysis: a)
                        }
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Material", symbol: "square.stack.3d.up.fill")
                        MaterialPicker(selection: bind(\.material))
                        Toggle(isOn: bind(\.sparEnabled)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Carbon spar").font(.system(size: 12, weight: .semibold))
                                Text(c.sparEnabled ? c.sparSpec.name : "Foam only").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch).tint(Theme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Carbon struts").font(.system(size: 12, weight: .semibold))
                            // One row per group: Auto (only when its check fails), On (also to clear a warning), Off.
                            strutRow("Wing", bind(\.wingStruts), help: "Wing underside to the bottom of the fuselage. Auto: only when the wing is far too flexible; On: also to clear a flex warning.")
                            if c.offersTailStruts {
                                strutRow("Tail", bind(\.tailStruts), help: "Wing to the tail boom, against twist and bending. Auto: only when the fuselage fails; On: also to clear a torsion / bending warning.")
                            }
                            if c.offersFinStruts {
                                strutRow("Fin", bind(\.finStruts), help: "Stabiliser up to the fin. Auto: whenever other struts are fitted; On: always.")
                            }
                            if c.offersTorsionTruss {
                                // Switching it on or off moves mass at the tail: re-balance the battery right away.
                                Toggle(isOn: Binding(get: { c.torsionTruss }, set: { v in
                                    guard var n = project.config else { return }
                                    n.torsionTruss = v
                                    project.config = Project.balanced(n)
                                })) {
                                    Text("Torsion truss – zigzag under the rear fuselage").font(.system(size: 11))
                                }
                                .toggleStyle(.switch).controlSize(.small)
                                .help("Carbon rods zigzagging between the plate edges and the bottom edge of the lower fuselage half, from behind the wing to the tail: closes the + section into a torsion box – much stiffer against twist.")
                            }
                            Text(strutSummary(c)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Balance", symbol: "scalemass.fill")
                        ParamSlider(label: "Battery position", unit: "mm", value: bind(\.batteryPosition), range: range(\.batteryPosition, c), step: 1)
                        if let a = project.analysis {
                            Text(String(format: "Target CG %.0f mm · battery for target %.0f mm", a.recommendedCG, a.requiredBatteryPosition))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack {
                            PillButton(title: "Auto-balance", symbol: "target") { withAnimation { project.autoBalance() } }
                            if !(project.analysis?.cgReachable ?? true) {
                                PillButton(title: "Bigger battery", symbol: "battery.100.bolt", prominent: true) { withAnimation { project.fixBalanceWithBattery() } }
                            }
                        }
                    }
                    .glass()
                }
                .padding(14)
        }
    }

    private func strutRow(_ title: String, _ value: Binding<StrutMode>, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).frame(width: 34, alignment: .leading)
            Picker("", selection: value) {
                ForEach(StrutMode.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .help(help)
    }

    private func strutSummary(_ c: AircraftConfig) -> String {
        let struts = project.design?.struts ?? []
        if struts.isEmpty { return c.struts == .off ? "No struts – stiffness from foam and spar only" : "None fitted – not needed on Auto, or none fit" }
        let wing = struts.filter { $0.group == .wing }.count, tail = struts.filter { $0.group == .tail }.count
        let fin = struts.filter { $0.group == .fin }.count, truss = struts.filter { $0.group == .torsion }.count
        let parts = [wing > 0 ? "\(wing) wing" : nil, tail > 0 ? "\(tail) tail" : nil, fin > 0 ? "\(fin) fin" : nil, truss > 0 ? "\(truss) torsion-truss" : nil].compactMap { $0 }.joined(separator: " + ")
        let mass = struts.reduce(0) { $0 + $1.rodMass }
        return "\(parts) struts fitted (\(String(format: "%.1f", mass)) g carbon + printed anchors) – marked S1… on the plans"
    }

    private func range(_ kp: PartialKeyPath<AircraftConfig>, _ c: AircraftConfig) -> ClosedRange<Double> {
        // The battery slides only where it physically fits (between nose and the servos / wing).
        if kp == \AircraftConfig.batteryPosition { let l = Analysis.batteryLimits(c); return l.lowerBound.rounded(.up)...max(l.lowerBound.rounded(.up), l.upperBound.rounded(.down)) }
        let r = AircraftConfig.range(kp, kind: c.kind)
        // The jet's fuselage must stay taller than its prop (window + frame above and below).
        if kp == \AircraftConfig.fuselageHeight, c.minFuselageHeight > r.lowerBound { return c.minFuselageHeight...max(r.upperBound, c.minFuselageHeight + 10) }
        return r
    }
}

struct ParamSlider: View {
    var label: String
    var unit: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(step < 1 ? String(format: "%.1f", value) : String(format: "%.0f", value))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { value = ($0 / step).rounded() * step }), in: range)
                .tint(Theme.accent)
                .controlSize(.small)
        }
    }
}

struct PickerRow<T: Hashable & Identifiable>: View {
    var label: String
    @Binding var selection: T
    var options: [T]
    var title: (T) -> String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Picker("", selection: $selection) {
                ForEach(options) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
        }
    }
}

struct MaterialPicker: View {
    @Binding var selection: FoamMaterial
    var body: some View {
        VStack(spacing: 6) {
            ForEach([FoamFamily.depron, .epp], id: \.self) { fam in
                HStack(spacing: 6) {
                    Text(fam.rawValue).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    ForEach(FoamMaterial.allCases.filter { $0.family == fam }) { m in
                        let on = m == selection
                        Button { withAnimation(.spring(duration: 0.25)) { selection = m } } label: {
                            Text("\(Int(m.thickness))")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .foregroundStyle(on ? .black : .primary)
                                .background {
                                    if on { RoundedRectangle(cornerRadius: 7).fill(Theme.accentGradient) }
                                    else { RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("mm sheet · \(selection.displayName) · \(Int(selection.density)) kg/m³")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}


/// The electronics of the design (motor, ESC, propeller, battery, servos, receiver …) – the same items as under
/// Materials ▸ Electronics. One column in the side panel, a compact grid under the 3D view.
struct ElectronicsList: View {
    let design: Design
    let analysis: Analysis
    var columns = 1

    var body: some View {
        let items = BuildDocs.billOfMaterials(design, analysis).filter { $0.category == "Electronics" }
        if columns <= 1 {
            VStack(alignment: .leading, spacing: 10) { ForEach(items) { row($0, compact: false) } }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: columns),
                      alignment: .leading, spacing: 8) {
                ForEach(items) { row($0, compact: true) }
            }
        }
    }

    private func row(_ it: BOMItem, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(it.quantity).font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent).frame(width: compact ? 38 : 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.item).font(.system(size: 11, weight: .semibold)).lineLimit(compact ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: !compact)
                Text(it.spec).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: !compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(it.item + " – " + it.spec)
    }
}
