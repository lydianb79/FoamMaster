import SwiftUI

struct RootView: View {
    @EnvironmentObject var project: Project
    /// Changing the theme rebuilds the whole view tree with the new colours.
    @AppStorage(ThemePalette.storageKey) private var theme = ThemePalette.defaultName
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
            if project.showAbout {
                AboutView { withAnimation(.easeOut(duration: 0.25)) { project.showAbout = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .id(theme)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.3), value: project.config == nil)
        .animation(.spring(duration: 0.35), value: project.statusMessage)
    }
}

extension AircraftKind {
    var tags: [String] {
        switch self {
        case .flyingWing: return ["Tailless", "Pusher", "Elevons"]
        case .delta: return ["Tailless", "Pusher", "High speed"]
        case .twinBoom: return ["Twin boom", "Pusher / dual", "\(Self.defaultChannels[self]!)-ch"]
        case .jet: return ["Jet", "Prop slot", "\(Self.defaultChannels[self]!)-ch"]
        case .trainer: return ["Tractor", "Flat wing", "Easy"]
        case .aerobat: return ["Tractor", "\(Self.defaultChannels[self]!)-ch", "3D"]
        case .glider: return ["Tractor", "Long span", "Thermal"]
        case .nutBall: return ["Tractor", "Round wing", "Slow & easy"]
        }
    }
    /// Receiver channels of each default design (servos + throttle).
    static let defaultChannels: [AircraftKind: Int] = Dictionary(uniqueKeysWithValues: AircraftKind.allCases.map { ($0, DesignBuilder.build($0.defaults).channels) })
    /// One accent colour for every type – the shapes and tags tell them apart.
    var tint: Color { Theme.accent }
}

struct GalleryView: View {
    var body: some View {
        GeometryReader { geo in
            ScrollView { GalleryContent(available: geo.size) }
        }
    }
}

struct ModelPreview: Identifiable {
    let kind: AircraftKind
    let design: Design
    let analysis: Analysis
    var id: AircraftKind { kind }
}

struct GalleryContent: View {
    @EnvironmentObject var project: Project
    /// Window size – the thumbnails shrink so that all cards fit without scrolling where possible.
    var available = CGSize(width: 1300, height: 820)
    @State private var selected: AircraftKind?
    static let pad: CGFloat = 32, gridSpacing: CGFloat = 16, headerHeight: CGFloat = 58, topPad: CGFloat = 34
    /// Card height without the thumbnail (padding, title row, stat chips, spacing).
    static let cardChrome: CGFloat = 142
    private var thumbHeight: CGFloat {
        let cols = max(1, Int((available.width - 2 * Self.pad + Self.gridSpacing) / (320 + Self.gridSpacing)))
        let rows = CGFloat((previews.count + cols - 1) / cols)
        let free = available.height - Self.topPad - Self.headerHeight - 20 - Self.pad * 0.75 - (rows - 1) * Self.gridSpacing
        return min(190, max(110, free / rows - Self.cardChrome))
    }
    private var previews: [ModelPreview] { Self.all }
    private static let all: [ModelPreview] = AircraftKind.allCases.map { k in
        let d = DesignBuilder.build(Project.balanced(k.defaults))
        return ModelPreview(kind: k, design: d, analysis: Analysis(design: d))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Compact header so both rows of cards fit in the window.
            VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.accentGradient)
                    Text("FoamMaster")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.accentGradient)
                }
                Text("Design, check and build Micro Flat Foam Planes and Wings up to 800 mm Wingspan")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            Text("Choose a base model to start customising")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.leading, 2)
            }
            .frame(height: Self.headerHeight)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Self.gridSpacing)], spacing: Self.gridSpacing) {
                ForEach(previews) { item in
                    ModelCard(preview: item, thumbHeight: thumbHeight) { selected = item.kind }
                }
            }
        }
        .padding(.horizontal, Self.pad).padding(.top, Self.topPad).padding(.bottom, Self.pad * 0.75)
        .sheet(item: $selected) { kind in
            SetupSheet(preview: previews.first { $0.kind == kind }!) { ch in
                selected = nil
                project.start(kind, choice: ch)
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
    var thumbHeight: CGFloat = 190
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let kind = preview.kind
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
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
                .frame(height: thumbHeight)
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

/// Everything picked in the setup sheet.
struct SetupChoice {
    var fins: TaillessFins
    var layout: ControlLayout
    var servos: Int
    var motors: MotorLayout
    var winglets: Bool
}

enum ControlLayout: String, CaseIterable, Hashable {
    case rudderElevator, aileronElevator, full
    var title: String { [.rudderElevator: "Rudder + elevator", .aileronElevator: "Ailerons + elevator", .full: "Ailerons + elevator + rudder"][self]! }
    var detail: String { [.rudderElevator: "Easy, stable", .aileronElevator: "No rudder – simpler, lighter", .full: "Full control – aerobatics"][self]! }
    var ailerons: Bool { self != .rudderElevator }
    var rudder: Bool { self != .aileronElevator }
    init(ailerons: Bool, rudder: Bool) { self = ailerons ? (rudder ? .full : .aileronElevator) : .rudderElevator }
}

/// Options asked for when a base model is picked.
struct SetupSheet: View {
    var preview: ModelPreview
    var start: (SetupChoice) -> Void
    var cancel: () -> Void
    @State private var fins: TaillessFins
    @State private var layout: ControlLayout
    @State private var servos = 2

    @State private var motors: MotorLayout = .single
    @State private var winglets = false

    init(preview: ModelPreview, start: @escaping (SetupChoice) -> Void, cancel: @escaping () -> Void) {
        self.preview = preview
        self.start = start
        self.cancel = cancel
        let d = preview.kind.defaults
        _layout = State(initialValue: ControlLayout(ailerons: d.ailerons, rudder: d.rudder))
        _fins = State(initialValue: d.taillessFins)
    }

    private var optionKey: String { "\(preview.kind.rawValue)-\(fins.rawValue)-\(layout.rawValue)-\(servos)-\(motors.rawValue)-\(winglets)" }

    private var candidate: AircraftConfig {
        var c = preview.kind.defaults
        c.taillessFins = fins; c.motorLayout = motors
        if preview.kind.hasTail { c.tailWinglets = winglets; c.ailerons = layout.ailerons }
        c.rudder = layout.rudder
        c.aileronServos = preview.kind.allowsSingleAileronServo ? servos : 2
        return c
    }

    var body: some View {
        let kind = preview.kind
        let design = DesignBuilder.build(candidate)
        let servoGroups = Dictionary(grouping: design.controls, by: \.servoID)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                // Live render of exactly what is selected below (fins, control surfaces, servos, motors).
                Group {
                    if let img = Thumbnailer.image(for: DesignBuilder.build(Project.balanced(candidate)), key: optionKey) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ModelThumbnail(preview: preview)
                    }
                }
                .frame(width: 300, height: 175)
                .background(RadialGradient(colors: [kind.tint.opacity(0.25), .clear], center: .center, startRadius: 5, endRadius: 170))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .animation(.easeInOut(duration: 0.2), value: optionKey)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.system(size: 24, weight: .heavy, design: .rounded))
                    Text(kind.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("You can change everything later in the editor.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
                }
            }

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            OptionGroup(title: "Control surfaces", symbol: "slider.horizontal.below.square.filled.and.square") {
                if kind.isNutBall {
                    Text("NutBall: rudder + elevator – 3 channels with the throttle. One-piece elevator across the trailing edge, rudder on the centre fin with a cut-out at its bottom so the elevator moves freely – the round wing turns with the rudder.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if kind.isTailless {
                    Text("Tailless: two elevons (combined aileron + elevator), one servo each.").font(.system(size: 11)).foregroundStyle(.secondary)
                    OptionTiles(selection: $fins, options: TaillessFins.allCases, title: \.name, detail: \.detail, tint: kind.tint)
                } else {
                    if kind.isTwinBoom {
                        Text("Twin boom: ailerons + elevator, fixed twin fins (no rudder).").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        OptionTiles(selection: $layout, options: [.aileronElevator, .full], title: \.title, detail: \.detail, tint: kind.tint)
                    }
                    OptionTiles(selection: $winglets, options: [false, true], title: { $0 ? "Winglets" : "Plain tips" },
                                detail: { $0 ? "Side-mounted winglets at both wing tips" : "Straight wing tips" }, tint: kind.tint)
                    if layout.ailerons && kind.allowsSingleAileronServo {
                        OptionTiles(selection: $servos, options: [1, 2], title: { $0 == 1 ? "1 aileron servo" : "2 aileron servos" },
                                    detail: { $0 == 1 ? "Central servo with a double arm, pushrods to both ailerons" : "One servo in each wing half" }, tint: kind.tint)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundStyle(kind.tint)
                    Text("\(design.controls.surfaceCount) control surfaces · \(servoGroups.count) servos · \(design.channels) channels incl. throttle: " +
                         servoGroups.keys.sorted().map { key -> String in
                             let n = servoGroups[key]!.surfaceCount
                             return n > 1 ? "\(key) → \(n) surfaces\(key.contains("double arm") ? "" : ", linked")" : (key == "Elevator" ? "Elevator (one piece)" : key)
                         }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if kind.allowsDualMotors {
                OptionGroup(title: "Motors", symbol: "fanblades.fill") {
                    OptionTiles(selection: $motors, options: MotorLayout.allCases, title: \.name,
                                detail: { $0 == .single ? (kind.isPusher ? "One pusher motor" : "One motor in the nose") : $0.detail }, tint: kind.tint)
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
                PillButton(title: "Start building", symbol: "arrow.right.circle.fill", prominent: true) { start(SetupChoice(fins: fins, layout: layout, servos: servos, motors: motors, winglets: winglets)) }
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
