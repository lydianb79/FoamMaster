import SwiftUI

struct RootView: View {
    @EnvironmentObject var project: Project
    var body: some View {
        ZStack {
            Theme.background
            if project.config == nil {
                GalleryView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                EditorView().transition(.opacity)
            }
            if let msg = project.statusMessage {
                VStack {
                    Text(msg)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                        .padding(.top, 70)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: project.config == nil)
        .animation(.spring(duration: 0.35), value: project.statusMessage)
    }
}

extension AircraftKind {
    var tags: [String] {
        switch self {
        case .flyingWing: return ["Tailless", "Pusher", "Elevons"]
        case .delta: return ["Tailless", "Pusher", "High speed"]
        case .twinBoom: return ["Twin boom", "Pusher", "FPV"]
        case .jet: return ["Jet", "Prop slot", "4-ch"]
        case .trainer: return ["Tractor", "Flat wing", "Easy"]
        case .aerobat: return ["Tractor", "4-ch", "3D"]
        case .glider: return ["Tractor", "Long span", "Thermal"]
        }
    }
    /// Accent per type so the cards read differently at a glance.
    var tint: Color {
        switch self {
        case .flyingWing: return Theme.accent
        case .delta: return Color(red: 1, green: 0.35, blue: 0.45)
        case .twinBoom: return Theme.good
        case .jet: return Color(red: 0.45, green: 0.6, blue: 1.0)
        case .trainer: return Theme.warn
        case .aerobat: return Theme.orange
        case .glider: return Theme.violet
        }
    }
}

struct GalleryView: View {
    var body: some View { ScrollView { GalleryContent() } }
}

struct ModelPreview: Identifiable {
    let kind: AircraftKind
    let design: Design
    let analysis: Analysis
    var id: AircraftKind { kind }
}

struct GalleryContent: View {
    @EnvironmentObject var project: Project
    @State private var selected: AircraftKind?
    private var previews: [ModelPreview] { Self.all }
    private static let all: [ModelPreview] = AircraftKind.allCases.map { k in
        let d = DesignBuilder.build(Project.balanced(k.defaults))
        return ModelPreview(kind: k, design: d, analysis: Analysis(design: d))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.accentGradient)
                    Text("FoamMaster")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accentGradient)
                }
                Text("Design, check and build micro foam RC aircraft up to 600 mm span.")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                Text("Choose a base model to start customising")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 14)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20)], spacing: 20) {
                ForEach(previews) { item in
                    ModelCard(preview: item) { selected = item.kind }
                }
            }
        }
        .padding(48)
        .sheet(item: $selected) { kind in
            SetupSheet(preview: previews.first { $0.kind == kind }!) { fpv, fuselage, layout, servos in
                selected = nil
                project.start(kind, fpv: fpv, fuselage: fuselage, ailerons: layout.ailerons, rudder: layout.rudder, aileronServos: servos)
            } cancel: { selected = nil }
        }
    }
}

struct ModelThumbnail: View {
    var preview: ModelPreview
    var body: some View {
        if let img = Thumbnailer.image(for: preview.design, key: preview.kind.rawValue) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else {
            PlanformView(design: preview.design, lineColor: preview.kind.tint).padding(18)
        }
    }
}

struct ModelCard: View {
    var preview: ModelPreview
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let kind = preview.kind
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(RadialGradient(colors: [kind.tint.opacity(hover ? 0.32 : 0.2), .clear], center: .center, startRadius: 5, endRadius: 220))
                    ModelThumbnail(preview: preview)
                        .scaleEffect(hover ? 1.05 : 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 5) {
                        ForEach(kind.tags, id: \.self) { tag in
                            Text(tag.uppercased()).font(.system(size: 8.5, weight: .heavy)).kerning(0.6)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(kind.tint.opacity(0.18), in: Capsule())
                                .foregroundStyle(kind.tint)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(kind.subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: kind.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(kind.tint.opacity(hover ? 1 : 0.22), in: Circle())
                        .foregroundStyle(hover ? .black : .white)
                }
                HStack(spacing: 8) {
                    StatChip(label: "Span", value: "\(Int(preview.design.config.wingspan)) mm", tint: kind.tint)
                    StatChip(label: "AUW", value: "\(Int(preview.analysis.totalMass)) g", tint: Theme.orange)
                    StatChip(label: "Load", value: String(format: "%.0f g/dm²", preview.analysis.wingLoading), tint: Theme.violet)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(hover ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.white.opacity(0.08)), lineWidth: hover ? 1.5 : 1))
            .shadow(color: kind.tint.opacity(hover ? 0.3 : 0), radius: 24, y: 10)
            .scaleEffect(hover ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hover = h } }
    }
}

enum ControlLayout: String, CaseIterable, Hashable {
    case rudderElevator, aileronElevator, full
    var title: String { [.rudderElevator: "Rudder + elevator", .aileronElevator: "Ailerons + elevator", .full: "Ailerons + elevator + rudder"][self]! }
    var detail: String { [.rudderElevator: "2 channels – easy, stable", .aileronElevator: "3 channels – no rudder", .full: "4 channels – full aerobatics"][self]! }
    var ailerons: Bool { self != .rudderElevator }
    var rudder: Bool { self != .aileronElevator }
    init(ailerons: Bool, rudder: Bool) { self = ailerons ? (rudder ? .full : .aileronElevator) : .rudderElevator }
}

/// Options asked for when a base model is picked.
struct SetupSheet: View {
    var preview: ModelPreview
    var start: (FPVSystem, FuselageType, ControlLayout, Int) -> Void
    var cancel: () -> Void
    @State private var fpv: FPVSystem
    @State private var fuselage: FuselageType
    @State private var layout: ControlLayout
    @State private var servos = 2

    init(preview: ModelPreview, start: @escaping (FPVSystem, FuselageType, ControlLayout, Int) -> Void, cancel: @escaping () -> Void) {
        self.preview = preview
        self.start = start
        self.cancel = cancel
        let d = preview.kind.defaults
        _fpv = State(initialValue: d.fpv)
        _layout = State(initialValue: ControlLayout(ailerons: d.ailerons, rudder: d.rudder))
        _fuselage = State(initialValue: FixFinder.recommendedStructure(for: d))
    }

    private var candidate: AircraftConfig {
        var c = preview.kind.defaults
        c.fpv = fpv; c.fuselageType = fuselage
        c.ailerons = layout.ailerons; c.rudder = layout.rudder
        c.aileronServos = preview.kind.isTwinBoom ? 2 : servos
        return c
    }

    var body: some View {
        let kind = preview.kind
        let design = DesignBuilder.build(candidate)
        let servoGroups = Dictionary(grouping: design.controls, by: \.servoID)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ModelThumbnail(preview: preview).frame(width: 230, height: 135)
                    .background(RadialGradient(colors: [kind.tint.opacity(0.25), .clear], center: .center, startRadius: 5, endRadius: 140))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text(kind.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("You can change everything later in the editor.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
                }
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            OptionGroup(title: "Control surfaces", symbol: "slider.horizontal.below.square.filled.and.square") {
                if kind.isTailless {
                    Text("Tailless: two elevons (combined aileron + elevator), one servo each.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    OptionTiles(selection: $layout, options: ControlLayout.allCases, title: \.title, detail: \.detail, tint: kind.tint)
                    if layout.ailerons && !kind.isTwinBoom {
                        OptionTiles(selection: $servos, options: [1, 2], title: { $0 == 1 ? "1 aileron servo" : "2 aileron servos" },
                                    detail: { $0 == 1 ? "Central servo, torque rods to both ailerons" : "One servo in each wing half" }, tint: kind.tint)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(kind.tint)
                    Text("\(design.controls.surfaceCount) control surfaces · \(servoGroups.count) servos: " +
                         servoGroups.keys.sorted().map { key -> String in
                             let n = servoGroups[key]!.surfaceCount
                             return n > 1 ? "\(key) → \(n) surfaces\(key.contains("torque") ? "" : (key == "Rudders" ? ", linked" : " (joined halves)"))" : key
                         }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            OptionGroup(title: "FPV system", symbol: "video.fill") {
                OptionTiles(selection: $fpv, options: FPVSystem.allCases, title: \.name, detail: { $0 == .none ? $0.detail : "\(String(format: "%.0f", $0.mass)) g · \(String(format: "%.1f", $0.power)) W" }, tint: kind.tint)
            }
            if kind.hasFuselage {
                OptionGroup(title: "Fuselage structure", symbol: "square.split.2x2") {
                    OptionTiles(selection: $fuselage, options: FuselageType.allCases, title: \.name, detail: { f in
                        var c = candidate; c.fuselageType = f
                        let st = StructureReport(c, totalMass: Analysis(design: DesignBuilder.build(c)).totalMass, stallSpeed: 16)
                        let twist = st.tailTwistDeg ?? 0
                        return "\(String(format: "%.1f", twist))° twist · " + (twist < 2 ? "stiff" : (twist < 5 ? "soft" : "too soft"))
                    }, tint: kind.tint)
                    Text(fuselage.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }

            }
            .padding(.trailing, 6)
            }
            .frame(maxHeight: 470)
            Divider().opacity(0.3)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                PillButton(title: "Start building", symbol: "arrow.right.circle.fill", prominent: true) { start(fpv, fuselage, layout, servos) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

struct OptionGroup<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title, symbol: symbol)
            content
        }
    }
}

/// Large selectable tiles (title + one-line detail) – used for the setup options.
struct OptionTiles<T: Hashable>: View {
    @Binding var selection: T
    var options: [T]
    var title: (T) -> String
    var detail: (T) -> String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { withAnimation(.spring(duration: 0.25)) { selection = o } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(o)).font(.system(size: 13, weight: .bold))
                        Text(detail(o)).font(.system(size: 10)).foregroundStyle(on ? .black.opacity(0.7) : .secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                    .padding(10)
                    .foregroundStyle(on ? .black : .primary)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.06))))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(on ? 0 : 0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
