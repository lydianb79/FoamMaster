import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// App state: the selected configuration plus everything derived from it.
@MainActor
final class Project: ObservableObject {
    @Published var config: AircraftConfig? {
        didSet {
            // Keep the fuselage taller than the prop window (jet) – e.g. after a motor change.
            if let c = config, c.fuselageHeight < c.minFuselageHeight { config?.fuselageHeight = c.minFuselageHeight }
            // A change that narrows the battery's room (e.g. one aileron servo centred on the plate) moves the battery
            // to the nearest position where it still fits.
            if let c = config {
                let l = Analysis.batteryLimits(c)
                let clamped = min(max(c.batteryPosition, l.lowerBound.rounded(.up)), max(l.lowerBound.rounded(.up), l.upperBound.rounded(.down)))
                if clamped != c.batteryPosition { config?.batteryPosition = clamped }   // (no re-entry: observers do not fire for sets inside didSet)
            }
            if let c = config { lastConfig = c } else { fileURL = nil }
            if config != oldValue {
                rebuild()
                if let c = config, c.autoPower, Project.airframeChanged(oldValue, c) || oldValue?.autoPower == false { schedulePowerSearch() }
            }
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
    /// Credits splash – shown at start-up, closed with a click.
    @Published var showAbout = true
    /// Result of the last balance fix, shown in the CG panel until the design changes.
    @Published var balanceNote: String?

    func start(_ kind: AircraftKind, choice ch: SetupChoice) {
        start(kind, fins: ch.fins, ailerons: ch.layout.ailerons, rudder: ch.layout.rudder,
              aileronServos: ch.servos, motors: ch.motors, winglets: ch.winglets)
    }

    func start(_ kind: AircraftKind, fins: TaillessFins? = nil,
               ailerons: Bool? = nil, rudder: Bool? = nil, aileronServos: Int = 2, motors: MotorLayout = .single,
               winglets: Bool = false) {
        fileURL = nil                   // a new design – Save asks for a file
        var c = kind.recommended
        if let ailerons { c.ailerons = ailerons && kind.hasTail }
        if let rudder { c.rudder = rudder }
        c.aileronServos = kind.allowsSingleAileronServo ? aileronServos : 2
        if let fins { c.taillessFins = fins }
        c.motorLayout = kind.allowsDualMotors ? motors : .single
        c.tailWinglets = winglets && kind.offersWinglets
        if winglets && kind.offersWinglets { c.wingletHeight = kind.isNutBall ? 50 : 45 }
        config = Project.balanced(c)
        inspectorTab = .analysis
    }

    // MARK: Fix suggestions

    // MARK: Automatic power system

    @Published private(set) var findingPower = false
    private var powerToken = 0

    /// True when something that changes the weight or the drag changed (anything but the power system itself,
    /// the battery position and the name).
    static func airframeChanged(_ old: AircraftConfig?, _ new: AircraftConfig) -> Bool {
        guard var a = old else { return true }
        var b = new
        a.motor = b.motor; a.battery = b.battery; a.batteryPosition = b.batteryPosition; a.name = b.name; a.autoPower = b.autoPower
        b.autoPower = a.autoPower
        return a != b
    }

    private func schedulePowerSearch() {
        powerToken += 1
        let token = powerToken
        guard let c = config else { return }
        findingPower = true
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard await self.powerToken == token else { return }
            let result = PowerOptimizer.best(for: c)
            await MainActor.run {
                guard self.powerToken == token else { return }
                self.findingPower = false
                guard let r = result, var cur = self.config, cur.autoPower else { return }
                if cur.motor == r.config.motor && cur.battery == r.config.battery { return }
                cur.motor = r.config.motor
                cur.battery = r.config.battery
                cur.batteryPosition = r.config.batteryPosition
                self.config = cur         // only motor/battery changed → does not trigger another search
                self.flash("Power system: \(cur.motor.name.replacingOccurrences(of: " brushless", with: "")) + \(cur.battery.name) · T/W \(String(format: "%.2f", r.analysis.thrustToWeight))")
            }
        }
    }

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
    nonisolated static func balanced(_ input: AircraftConfig) -> AircraftConfig {
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

    /// Lightest servo class whose torque keeps the 40 % reserve on every surface.
    nonisolated static func lightestServo(_ input: AircraftConfig) -> AircraftConfig {
        var c = input
        for s in ServoClass.allCases.sorted(by: { $0.mass < $1.mass }) {
            c.servo = s
            let a = Analysis(design: DesignBuilder.build(c))
            if !a.checks.contains(where: { $0.category == "Servos" && $0.severity >= .warning }) { return c }
        }
        return c
    }

    /// A random variant of `current`'s type with its options (fuselage, surfaces, layout, struts) that passes every
    /// check with score 100: random airframe (spar always on) → quick screen with the current power system →
    /// lightest sufficient servo → automatic power system → balanced. Nil when none was found within `attempts`.
    /// Diagnostics for the self-test: candidates tried, passed the quick screen, power searches run.
    nonisolated(unsafe) static var randomStats = (candidates: 0, screened: 0, searches: 0)

    nonisolated static func randomVariant(like current: AircraftConfig, attempts: Int = 400, deadline: TimeInterval = 8) -> (AircraftConfig, Analysis)? {
        let t0 = Date()
        var powerSearches = 0
        for _ in 0..<attempts where Date().timeIntervalSince(t0) < deadline {
            var c = AircraftConfig.random(kind: current.kind)
            randomStats.candidates += 1
            c.fuselageType = current.fuselageType
            c.aileronServos = current.aileronServos
            c.ailerons = current.ailerons
            c.rudder = current.rudder
            c.taillessFins = current.taillessFins
            c.motorLayout = current.motorLayout
            c.tailWinglets = current.tailWinglets
            c.wingStruts = current.wingStruts; c.tailStruts = current.tailStruts; c.finStruts = current.finStruts
            c.autoPower = current.autoPower
            c.sparEnabled = true
            c.motor = current.motor; c.battery = current.battery; c.servo = current.servo
            // Quick screen: the airframe itself must be clean (geometry, structure, stability) – power, balance,
            // servos and flight performance are sorted out below.
            let d0 = DesignBuilder.build(c)
            guard d0.geometryIssues.isEmpty else { continue }
            let a0 = Analysis(design: d0)
            let airframeProblems = a0.checks.filter { $0.severity >= .warning && !["Power", "Balance", "Servos", "Performance"].contains($0.category) }
            guard airframeProblems.isEmpty else { continue }
            randomStats.screened += 1
            c = lightestServo(c)
            if c.autoPower, powerSearches < 12 {
                powerSearches += 1
                randomStats.searches += 1
                if let r = PowerOptimizer.best(for: c) { c.motor = r.config.motor; c.battery = r.config.battery }
                c = lightestServo(c)
            }
            c = Project.balanced(c)
            let a = Analysis(design: DesignBuilder.build(c))
            if a.feasible && a.score == 100 { return (c, a) }
        }
        return nil
    }

    @Published private(set) var randomizing = false

    /// Random variation of the current type that passes every check (score 100), found in the background.
    func randomize() {
        guard let current = config, !randomizing else { return }
        randomizing = true
        flash("Randomizing …")
        Task.detached(priority: .userInitiated) {
            let found = Project.randomVariant(like: current)
            await MainActor.run {
                self.randomizing = false
                if let (c, _) = found {
                    var c = c
                    c.name = current.name.hasPrefix("My ") ? c.name : c.name
                    self.config = c
                    self.fileURL = nil          // a new design – Save asks for a file
                    self.flash("Randomized – all checks passed (score 100)")
                } else { self.flash("No variant passing every check found this time – press Randomize again") }
            }
        }
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

    // MARK: Save / load designs

    /// File the current design was last saved to / opened from (Save writes there again).
    @Published private(set) var fileURL: URL?

    func saveDesign(as forceNew: Bool = false) {
        guard let c = config else { return }
        var url = forceNew ? nil : fileURL
        if url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [AircraftConfig.fileType]
            panel.nameFieldStringValue = "\(safeName).\(AircraftConfig.fileExtension)"
            panel.title = "Save Design"
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        guard let url else { return }
        do {
            try c.fileData().write(to: url, options: .atomic)
            fileURL = url
            flash("Design saved to \(url.lastPathComponent)")
        } catch { flash("Saving failed: \(error.localizedDescription)") }
    }

    func openDesign() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AircraftConfig.fileType, .json]
        panel.allowsMultipleSelection = false
        panel.title = "Open Design"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let c = try AircraftConfig.load(from: Data(contentsOf: url))
            config = c
            fileURL = url
            flash("Opened \(url.lastPathComponent)")
        } catch { flash("Could not open \(url.lastPathComponent): not a FoamMaster design") }
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
