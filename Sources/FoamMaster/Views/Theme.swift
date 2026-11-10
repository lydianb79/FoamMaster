import SwiftUI

enum Theme {
    static let bgTop = Color(red: 0.035, green: 0.045, blue: 0.09)
    static let bgBottom = Color(red: 0.09, green: 0.06, blue: 0.17)
    static let accent = Color(red: 0.25, green: 0.78, blue: 1.0)
    static let violet = Color(red: 0.58, green: 0.42, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.2)
    static let good = Color(red: 0.25, green: 0.9, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.2)
    static let bad = Color(red: 1.0, green: 0.3, blue: 0.4)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.16), .clear], center: .init(x: 0.25, y: 0.2), startRadius: 10, endRadius: 600)
            RadialGradient(colors: [violet.opacity(0.18), .clear], center: .init(x: 0.85, y: 0.85), startRadius: 10, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    static let accentGradient = LinearGradient(colors: [accent, violet], startPoint: .leading, endPoint: .trailing)

    static func color(_ s: Severity) -> Color {
        switch s { case .ok: return good; case .info: return accent; case .warning: return warn; case .error: return bad }
    }
    static func symbol(_ s: Severity) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"; case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill"
        }
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

extension View {
    func glass(radius: CGFloat = 16, padding: CGFloat = 14) -> some View { modifier(Glass(radius: radius, padding: padding)) }
}

struct SectionHeader: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentGradient)
            Text(title.uppercased()).font(.system(size: 11, weight: .heavy)).kerning(1.2).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct StatChip: View {
    var label: String
    var value: String
    var tint: Color = Theme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).kerning(0.8).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PillButton: View {
    var title: String
    var symbol: String
    var prominent = false
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(prominent ? .black : .white)
                .background {
                    if prominent { Capsule().fill(Theme.accentGradient) } else { Capsule().fill(.white.opacity(hover ? 0.16 : 0.09)) }
                }
                .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.12)))
                .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Top view of a design (X span horizontal, Z chord vertical) for previews.
struct PlanformView: View {
    var design: Design
    var lineColor: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            var polys: [([CGPoint], Bool)] = []
            var lo = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: .greatestFiniteMagnitude), hi = CGPoint(x: -lo.x, y: -lo.y)
            for part in design.parts {
                let regions = part.regions.isEmpty ? [Region(polygon: part.outline, isControl: false)] : part.regions
                for inst in part.instances {
                    for r in regions {
                        let pts = r.polygon.map { p -> CGPoint in let q = inst.point(p); return CGPoint(x: q.x, y: q.z) }
                        for p in pts { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
                        polys.append((pts, r.isControl))
                    }
                }
            }
            let w = hi.x - lo.x, h = hi.y - lo.y
            guard w > 0, h > 0 else { return }
            let s = min(size.width / w, size.height / h) * 0.9
            let off = CGPoint(x: (size.width - w * s) / 2 - lo.x * s, y: (size.height - h * s) / 2 - lo.y * s)
            for (pts, ctrl) in polys {
                var path = Path()
                path.addLines(pts.map { CGPoint(x: $0.x * s + off.x, y: $0.y * s + off.y) })
                path.closeSubpath()
                ctx.fill(path, with: .color(ctrl ? Theme.orange.opacity(0.55) : lineColor.opacity(0.12)))
                ctx.stroke(path, with: .color(ctrl ? Theme.orange : lineColor), lineWidth: 1)
            }
        }
    }
}
