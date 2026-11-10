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
                    Spacer()
                    Text(msg)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                        .padding(.bottom, 90)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: project.config == nil)
        .animation(.spring(duration: 0.35), value: project.statusMessage)
    }
}

struct GalleryView: View {
    var body: some View { ScrollView { GalleryContent() } }
}

struct GalleryContent: View {
    @EnvironmentObject var project: Project
    private let previews: [(AircraftKind, Design, Analysis)] = AircraftKind.allCases.map { k in
        let d = DesignBuilder.build(k.defaults)
        return (k, d, Analysis(design: d))
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
                    ForEach(previews, id: \.0) { item in
                        ModelCard(kind: item.0, design: item.1, analysis: item.2) { project.start(item.0) }
                    }
                }
            }
            .padding(48)
    }
}

struct ModelCard: View {
    var kind: AircraftKind
    var design: Design
    var analysis: Analysis
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(hover ? 0.18 : 0.08), Theme.violet.opacity(0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    PlanformView(design: design).padding(18)
                }
                .frame(height: 190)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(kind.subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: kind.symbol)
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Theme.accentGradient.opacity(hover ? 1 : 0.25), in: Circle())
                        .foregroundStyle(hover ? .black : .white)
                }
                HStack(spacing: 8) {
                    StatChip(label: "Span", value: "\(Int(design.config.wingspan)) mm")
                    StatChip(label: "AUW", value: "\(Int(analysis.totalMass)) g", tint: Theme.orange)
                    StatChip(label: "Load", value: String(format: "%.0f g/dm²", analysis.wingLoading), tint: Theme.violet)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(hover ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.white.opacity(0.08)), lineWidth: hover ? 1.5 : 1))
            .shadow(color: Theme.accent.opacity(hover ? 0.25 : 0), radius: 24, y: 10)
            .scaleEffect(hover ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hover = h } }
    }
}
