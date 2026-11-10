import SwiftUI
import AppKit

enum AboutLinks {
    static let youtube = URL(string: "https://www.youtube.com/@RockFPV")!
    static let github = URL(string: "https://github.com/lydianb79/FoamMaster")!
}

/// Credits: designer, YouTube channel (with its logo) and the GitHub repository.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Channel logo bundled with the app (Assets/RockFPV_logo.png, copied by build_app.sh).
    private var logo: NSImage? {
        Bundle.main.url(forResource: "RockFPV_logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        VStack(spacing: 18) {
            Group {
                if let logo {
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(red: 0.9, green: 0.1, blue: 0.12)
                        Image(systemName: "play.fill").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

            VStack(spacing: 6) {
                Text("FoamMaster").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accentGradient)
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

            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 380)
        .background(Theme.background)
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

/// Round "i" button that opens the credits.
struct InfoButton: View {
    @EnvironmentObject var project: Project
    @State private var hover = false
    var body: some View {
        Button { project.showAbout = true } label: {
            Image(systemName: "info")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(hover ? 1 : 0.22), in: Circle())
                .foregroundStyle(hover ? .black : .white)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("About FoamMaster")
    }
}
