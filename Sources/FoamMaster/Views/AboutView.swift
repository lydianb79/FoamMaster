import SwiftUI
import AppKit

enum AboutLinks {
    static let youtube = URL(string: "https://www.youtube.com/@RockFPV")!
    static let github = URL(string: "https://github.com/lydianb79/FoamMaster")!
}

/// Credits splash shown when the app starts: designer, YouTube channel (with its logo) and the GitHub repository.
/// A click anywhere closes it; the two links stay clickable.
struct AboutView: View {
    var close: () -> Void

    /// Channel logo bundled with the app (Assets/RockFPV_logo.png, copied by build_app.sh).
    private var logo: NSImage? {
        Bundle.main.url(forResource: "RockFPV_logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            VStack(spacing: 18) {
                Group {
                    if let logo {
                        Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            Circle().fill(Color(red: 0.9, green: 0.1, blue: 0.12))
                            Image(systemName: "play.fill").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 140, height: 140)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)

                VStack(spacing: 6) {
                    Text("FoamMaster").font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accentGradient)
                    Text("Design by TriX aka Rock FPV").font(.system(size: 15, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 10) {
                    LinkRow(symbol: "play.rectangle.fill", tint: Color(red: 1, green: 0.2, blue: 0.2), title: "YouTube – Rock FPV",
                            url: AboutLinks.youtube)
                    LinkRow(symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.accent, title: "GitHub – FoamMaster",
                            url: AboutLinks.github)
                }
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                Text("Click anywhere to start").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            }
            .padding(30)
            .frame(width: 400)
            .background(Theme.background.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .onTapGesture(perform: close)
        }
        .preferredColorScheme(.dark)
    }
}

private struct LinkRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var url: URL
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}
