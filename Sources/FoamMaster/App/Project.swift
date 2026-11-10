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
    /// Result of the last balance fix, shown in the CG panel until the design changes.
    @Published var balanceNote: String?

    func start(_ kind: AircraftKind, choice ch: SetupChoice) {
        start(kind, fins: ch.fins, ailerons: ch.layout.ailerons, rudder: ch.layout.rudder,
              aileronServos: ch.servos, motors: ch.motors, winglets: ch.winglets)
    }

    func start(_ kind: AircraftKind, fins: TaillessFins? = nil,
               ailerons: Bool? = nil, rudder: Bool? = nil, aileronServos: Int = 2, motors: MotorLayout = .single,
               winglets: Bool = false) {
        var c = kind.defaults
        if let ailerons { c.ailerons = ailerons && kind.hasTail }
        if let rudder { c.rudder = rudder }
        c.aileronServos = kind.isTwinBoom ? 2 : aileronServos
        if let fins { c.taillessFins = fins }
        c.motorLayout = kind.allowsDualMotors ? motors : .single
        c.tailWinglets = winglets && kind.hasTail
        if winglets && kind.hasTail { c.wingletHeight = 45 }
        config = Project.balanced(c)
        inspectorTab = .analysis
    }

    // MARK: Fix suggestions

    @Published var inspectorTab: InspectorTab = .analysis
    @Published private(set) var fixes: [FixSuggestion] = []
    @Published private(set) var findingFixes = false
    private var fixToken = 0

    private func scheduleFixSearch() {
        fixToken += 1
        let token = fixToken
        fixes = []
        guard let c = config, let a = analysis, !a.feasible else { findingFixes = false; return }
        findingFixes = true
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard await self.fixToken == token else { return }
            let result = FixFinder.suggestions(for: c)
            await MainActor.run {
                guard self.fixToken == token else { return }
                self.fixes = result
                self.findingFixes = false
            }
        }
    }

    func apply(_ fix: FixSuggestion) {
        config = fix.config
        flash(fix.title)
    }

    /// Puts the battery where the CG lands on target; if that is impossible, tries heavier
    /// (or lighter) compatible packs until the CG can be reached.
    static func balanced(_ input: AircraftConfig) -> AircraftConfig {
        var c = input
        func place(_ c: inout AircraftConfig) -> Bool {
            let a = Analysis(design: DesignBuilder.build(c))
            c.batteryPosition = a.bestBatteryPosition.rounded()
            return a.cgReachable
        }
        if place(&c) { return c }
        let tooFarForward = Analysis(design: DesignBuilder.build(c)).requiredBatteryPosition < Analysis.batteryLimits(c).lowerBound
        let packs = BatteryPack.allCases
            .filter { c.motor.allowedCells.contains($0.cells) }
            .sorted { tooFarForward ? $0.mass < $1.mass : $0.mass > $1.mass }
            .filter { tooFarForward ? $0.mass > input.battery.mass : $0.mass < input.battery.mass }
        for pack in packs {
            var t = c
            t.battery = pack
            if place(&t) { return t }
        }
        return c
    }

    /// Keeps the battery but moves it to the balance point (clamped to where it physically fits).
    func autoBalance() {
        guard var c = config else { return }
        c.batteryPosition = balancedBatteryPosition(for: c)
        config = c
    }

    /// Swaps to the lightest battery that lets the CG be reached and balances it.
    func fixBalanceWithBattery() {
        guard let c = config else { return }
        let fixed = Project.balanced(c)
        config = fixed
        let reachable = analysis?.cgReachable ?? true
        let note: String
        if fixed.battery != c.battery {
            note = reachable ? "Battery changed to \(fixed.battery.name) and moved to the balance point."
                             : "Changed to \(fixed.battery.name) – still not enough. Adjust the geometry."
        } else if !reachable {
            note = "\(c.battery.name) is already the biggest pack this motor supports (\(c.motor.allowedCells.lowerBound)–\(c.motor.allowedCells.upperBound)S). Reduce sweep, move mass forward or choose a motor that takes bigger packs."
        } else {
            note = "Battery moved to the balance point."
        }
        balanceNote = note
    }

    func rebuild() {
        balanceNote = nil
        guard let c = config else { design = nil; analysis = nil; return }
        let d = DesignBuilder.build(c)
        design = d
        analysis = Analysis(design: d)
        revision += 1
        scheduleFixSearch()
    }

    func balancedBatteryPosition(for c: AircraftConfig) -> Double {
        let a = Analysis(design: DesignBuilder.build(c))
        let r = AircraftConfig.range(\AircraftConfig.batteryPosition, kind: c.kind)
        return min(max(a.requiredBatteryPosition.rounded(), r.lowerBound), r.upperBound)
    }

    /// Random variation of the current type that passes all feasibility checks.
    func randomize() {
        guard let current = config else { return }
        let kind = current.kind
        var best: AircraftConfig?
        var bestScore = -1
        for _ in 0..<120 {
            var c = AircraftConfig.random(kind: kind)
            c.fuselageType = current.fuselageType
            c.aileronServos = current.aileronServos
            c.ailerons = current.ailerons
            c.rudder = current.rudder
            c.taillessFins = current.taillessFins
            c.motorLayout = current.motorLayout
            c.tailWinglets = current.tailWinglets
            c = Project.balanced(c)
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
