import SwiftUI

struct ParameterPanel: View {
    var body: some View { ScrollView { ParameterContent() } }
}

struct ParameterContent: View {
    @EnvironmentObject var project: Project
    private var lastConfig: AircraftConfig { project.lastConfig ?? AircraftKind.trainer.defaults }

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
                        ParamSlider(label: "Wingspan", unit: "mm", value: bind(\.wingspan), range: range(\.wingspan, c), step: 5)
                        ParamSlider(label: "Root chord", unit: "mm", value: bind(\.rootChord), range: range(\.rootChord, c), step: 1)
                        ParamSlider(label: "Tip chord", unit: "mm", value: bind(\.tipChord), range: range(\.tipChord, c), step: 1)
                        ParamSlider(label: "Sweep (tip LE)", unit: "mm", value: bind(\.sweep), range: range(\.sweep, c), step: 1)
                        if c.kind.hasFuselage {
                            ParamSlider(label: "Dihedral", unit: "°", value: bind(\.dihedral), range: range(\.dihedral, c), step: 0.5)
                        }
                        if c.kind.isTailless || c.hasAilerons {
                            ParamSlider(label: c.kind.isTailless ? "Elevon chord" : "Aileron chord", unit: "%",
                                        value: Binding(get: { c.controlChordPct * 100 }, set: { project.config?.controlChordPct = $0 / 100 }),
                                        range: 12...40, step: 1)
                        }
                        if c.kind.isTailless {
                            ParamSlider(label: c.kind == .delta ? "Fin height" : "Winglet height", unit: "mm", value: bind(\.wingletHeight), range: range(\.wingletHeight, c), step: 1)
                        }
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Build options", symbol: "slider.horizontal.3")
                        PickerRow(label: "FPV", selection: bind(\.fpv), options: FPVSystem.allCases) { $0 == .none ? $0.name : "\($0.name) · \(Int($0.mass.rounded())) g" }
                        if c.kind.hasFuselage {
                            Picker("", selection: bind(\.fuselageType)) {
                                ForEach(FuselageType.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Text(c.fuselageType.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if !c.kind.isTailless {
                            Picker("", selection: Binding(get: { ControlLayout(ailerons: c.ailerons, rudder: c.rudder) },
                                                          set: { project.config?.ailerons = $0.ailerons; project.config?.rudder = $0.rudder })) {
                                Text("R + E").tag(ControlLayout.rudderElevator)
                                Text("A + E").tag(ControlLayout.aileronElevator)
                                Text("A + E + R").tag(ControlLayout.full)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .help("Control layout: rudder, ailerons, elevator")
                        }
                        if c.hasAilerons && !c.kind.isTwinBoom {
                            Picker("", selection: bind(\.aileronServos)) {
                                Text("1 aileron servo").tag(1)
                                Text("2 aileron servos").tag(2)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    .glass()

                    if !c.kind.isTailless {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: c.kind.isTwinBoom ? "Pod, booms & tail" : "Fuselage & Tail", symbol: "arrow.left.and.right")
                            ParamSlider(label: c.kind.isTwinBoom ? "Pod nose length" : "Nose length", unit: "mm", value: bind(\.noseLength), range: range(\.noseLength, c), step: 1)
                            ParamSlider(label: c.kind.isTwinBoom ? "Pod height" : "Fuselage height", unit: "mm", value: bind(\.fuselageHeight), range: range(\.fuselageHeight, c), step: 1)
                            ParamSlider(label: "Tail arm", unit: "mm", value: bind(\.tailArm), range: range(\.tailArm, c), step: 1)
                            ParamSlider(label: c.kind.isTwinBoom ? "Stab span (boom spacing)" : "Stab span", unit: "mm", value: bind(\.hStabSpan), range: range(\.hStabSpan, c), step: 1)
                            ParamSlider(label: "Stab chord", unit: "mm", value: bind(\.hStabChord), range: range(\.hStabChord, c), step: 1)
                            ParamSlider(label: "Fin height", unit: "mm", value: bind(\.vStabHeight), range: range(\.vStabHeight, c), step: 1)
                            ParamSlider(label: "Fin chord", unit: "mm", value: bind(\.vStabChord), range: range(\.vStabChord, c), step: 1)
                        }
                        .glass()
                    }

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
                    }
                    .glass()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Electronics", symbol: "bolt.fill")
                        PickerRow(label: "Motor", selection: bind(\.motor), options: MotorClass.allCases) { $0.name }
                        PickerRow(label: "Battery", selection: bind(\.battery), options: BatteryPack.allCases) { "\($0.name) · \(Int($0.mass)) g" }
                        PickerRow(label: "Servos", selection: bind(\.servo), options: ServoClass.allCases) { $0.name }
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

    private func range(_ kp: PartialKeyPath<AircraftConfig>, _ c: AircraftConfig) -> ClosedRange<Double> {
        AircraftConfig.range(kp, kind: c.kind)
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
