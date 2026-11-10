import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// App state: the selected configuration plus everything derived from it.
@MainActor
final class Project: ObservableObject {
    @Published var config: AircraftConfig? {
        didSet {
            if let c = config { lastConfig = c }
            if config != oldValue { rebuild() }
        }
    }
    private(set) var lastConfig: AircraftConfig?
    @Published private(set) var design: Design?
    @Published private(set) var analysis: Analysis?
    @Published private(set) var revision = 0

    // Viewer options
    @Published var showCG = true
    @Published var autoRotate = false
    @Published var deflection: Double = 0   // control surface preview, -1…1

    @Published var statusMessage: String?

    func start(_ kind: AircraftKind) {
        var c = kind.defaults
        c.batteryPosition = balancedBatteryPosition(for: c)
        config = c
    }

    func rebuild() {
        guard let c = config else { design = nil; analysis = nil; return }
        let d = DesignBuilder.build(c)
        design = d
        analysis = Analysis(design: d)
        revision += 1
    }

    func balancedBatteryPosition(for c: AircraftConfig) -> Double {
        let a = Analysis(design: DesignBuilder.build(c))
        let r = AircraftConfig.range(\AircraftConfig.batteryPosition, kind: c.kind)
        return min(max(a.requiredBatteryPosition.rounded(), r.lowerBound), r.upperBound)
    }

    func autoBalance() {
        guard var c = config else { return }
        c.batteryPosition = balancedBatteryPosition(for: c)
        config = c
    }

    /// Random variation of the current type that passes all feasibility checks.
    func randomize() {
        guard let kind = config?.kind else { return }
        var best: AircraftConfig?
        var bestScore = -1
        for _ in 0..<120 {
            var c = AircraftConfig.random(kind: kind)
            c.batteryPosition = balancedBatteryPosition(for: c)
            let a = Analysis(design: DesignBuilder.build(c))
            if a.feasible && a.score > bestScore { best = c; bestScore = a.score }
            if bestScore >= 92 { break }
        }
        if let best { config = best; flash("Randomized – feasibility score \(bestScore)") }
        else { flash("No feasible random variant found – try again") }
    }

    func flash(_ msg: String) {
        statusMessage = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == msg { statusMessage = nil }
        }
    }

    var safeName: String {
        (config?.name ?? "FoamMaster").replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
    }

    // MARK: Export

    func exportPlans() {
        guard let d = design, let a = analysis else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(safeName)_plans.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PlanPDF.render(d, a).write(to: url)
            flash("Plans saved to \(url.lastPathComponent)")
            NSWorkspace.shared.open(url)
        } catch { flash("Export failed: \(error.localizedDescription)") }
    }

    func printPlans() {
        guard let d = design, let a = analysis, let doc = PDFDocument(data: PlanPDF.render(d, a)) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .clip; info.verticalPagination = .clip
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    func exportSTLs() {
        guard let d = design else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export STLs Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let folder = dir.appendingPathComponent("\(safeName)_printed_parts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let parts = PrintedParts.generate(d)
            var readme = "FoamMaster printed parts for \(d.config.name)\n\n"
            for p in parts {
                try p.mesh.stlData(name: p.name).write(to: folder.appendingPathComponent("\(p.fileName).stl"))
                readme += "\(p.fileName).stl  ×\(p.quantity)  – \(p.name), \(p.note), \(String(format: "%.1f", p.mass)) g\n"
            }
            readme += "\nSuggested: PETG or PLA, 0.2 mm layers, 100 % infill for horns, 4 perimeters.\n"
            try readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            flash("\(parts.count) STL files exported")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { flash("STL export failed: \(error.localizedDescription)") }
    }
}
