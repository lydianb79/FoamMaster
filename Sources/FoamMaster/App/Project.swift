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
                let clamped = l.contains(c.batteryPosition) ? c.batteryPosition : Analysis.fittingPosition(c.batteryPosition, c)
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
    /// Motor running in the 3D view (spinning propellers).
    @Published var motorOn = false
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
        let d = kind.defaults
        let ch = SetupChoice(fins: fins ?? d.taillessFins, layout: ControlLayout(ailerons: ailerons ?? d.ailerons, rudder: rudder ?? d.rudder),
                             servos: aileronServos, motors: motors, winglets: winglets)
        fileURL = nil                   // a new design – Save asks for a file
        config = Project.feasibleSetup(kind, ch)
        inspectorTab = .analysis
    }

    /// The type's default airframe with the options picked in the setup sheet (before any sizing).
    nonisolated static func setupConfig(_ kind: AircraftKind, _ ch: SetupChoice) -> AircraftConfig {
        var c = kind.defaults
        c.ailerons = ch.layout.ailerons && kind.hasTail
        if !kind.isTailless && !kind.isNutBall && !kind.isTwinBoom { c.rudder = ch.layout.rudder }
        c.aileronServos = kind.allowsSingleAileronServo && c.ailerons ? ch.servos : 2
        if kind.isTailless {
            c.taillessFins = ch.fins
            // Centre fin and winglets share the yaw stability: both a bit smaller than either alone.
            if ch.fins == .finAndWinglets { c.centreFinHeight = (c.wingletHeight * 0.8).rounded(); c.wingletHeight = (c.wingletHeight * 0.6).rounded() }
        }
        c.motorLayout = kind.allowsDualMotors ? ch.motors : .single
        c.tailWinglets = ch.winglets && kind.offersWinglets
        if c.tailWinglets { c.wingletHeight = kind.isNutBall ? 50 : 45 }
        c.sparEnabled = true
        return c
    }

    /// Every combination the setup sheet offers for a type.
    nonisolated static func setupChoices(_ kind: AircraftKind) -> [SetupChoice] {
        let d = kind.defaults
        let fins = kind.isTailless ? TaillessFins.allCases : [d.taillessFins]
        let layouts: [ControlLayout] = kind.isTailless || kind.isNutBall || kind.isTwinBoom ? [ControlLayout(ailerons: d.ailerons, rudder: d.rudder)] : [.aileronElevator, .full]
        let wings = kind.offersWinglets ? [false, true] : [false]
        let motors = kind.allowsDualMotors ? MotorLayout.allCases : [.single]
        var out: [SetupChoice] = []
        for f in fins { for l in layouts { for w in wings { for m in motors {
            for s in (l.ailerons && kind.hasTail && kind.allowsSingleAileronServo ? [1, 2] : [2]) {
                out.append(SetupChoice(fins: f, layout: l, servos: s, motors: m, winglets: w))
            }
        } } } }
        return out
    }

    /// Cache of `feasibleSetup` results (gallery cards, setup-sheet previews and Start building show the same build).
    nonisolated(unsafe) private static var setupCache: [String: AircraftConfig] = [:]
    nonisolated private static let setupLock = NSLock()
    nonisolated static func setupKey(_ kind: AircraftKind, _ ch: SetupChoice) -> String {
        "\(kind.rawValue)-\(ch.fins.rawValue)-\(ch.layout.rawValue)-\(ch.servos)-\(ch.motors.rawValue)-\(ch.winglets)"
    }
    nonisolated(unsafe) private static var setupCacheLoaded = false
    nonisolated static func cachedSetup(_ kind: AircraftKind, _ ch: SetupChoice) -> AircraftConfig? {
        setupLock.lock(); defer { setupLock.unlock() }
        loadSetupCacheLocked()
        return setupCache[setupKey(kind, ch)]
    }

    /// Sized setups are kept on disk (Application Support/FoamMaster), tied to this build of the app, so the gallery
    /// and the setup sheet are instant after the first time.
    nonisolated private static var setupCacheFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FoamMaster/setups.json")
    }
    nonisolated private static var buildStamp: String {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int(date))-\(attrs?[.size] as? Int ?? 0)"
    }
    nonisolated private static func loadSetupCacheLocked() {
        guard !setupCacheLoaded else { return }
        setupCacheLoaded = true
        guard let url = setupCacheFile, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SetupCacheFile.self, from: data), file.build == buildStamp else { return }
        setupCache.merge(file.setups) { cur, _ in cur }
    }
    nonisolated private static func saveSetupCacheLocked() {
        guard let url = setupCacheFile, let data = try? JSONEncoder().encode(SetupCacheFile(build: buildStamp, setups: setupCache)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The build a new model starts with for these setup options – one that passes every check (score 100):
    /// spar on, struts on Auto, lightest sufficient servo, automatic power system, battery at the balance point; if
    /// that still leaves warnings, the smallest airframe changes (sizes, fuselage structure, foam, battery) that clear them.
    nonisolated static func feasibleSetup(_ kind: AircraftKind, _ ch: SetupChoice) -> AircraftConfig {
        if let c = cachedSetup(kind, ch) { return c }
        let c = sized(setupConfig(kind, ch))
        setupLock.lock(); setupCache[setupKey(kind, ch)] = c; saveSetupCacheLocked(); setupLock.unlock()
        return c
    }

    /// Sizes every setup of every type in the background (the defaults first), so picking any option is instant.
    nonisolated static func warmSetupCache() {
        Task.detached(priority: .background) {
            let all = AircraftKind.allCases.map { ($0, $0.defaultSetupChoice) } + AircraftKind.allCases.flatMap { k in setupChoices(k).map { (k, $0) } }
            for (k, ch) in all { _ = feasibleSetup(k, ch) }
        }
    }

    nonisolated static func perfect(_ c: AircraftConfig) -> Bool {
        let d = DesignBuilder.build(c)
        let a = Analysis(design: d)
        return d.geometryIssues.isEmpty && a.feasible && a.score == 100
    }

    /// Servo, power system and balance for an airframe.
    nonisolated static func powered(_ input: AircraftConfig) -> AircraftConfig {
        var c = lightestServo(input)
        if c.autoPower, let r = PowerOptimizer.best(for: c) { c.motor = r.config.motor; c.battery = r.config.battery; c = lightestServo(c) }
        return balanced(c)
    }

    /// Airframe passes every check apart from power and flight performance (those follow from the power system).
    nonisolated static func airframeClean(_ c: AircraftConfig) -> Bool {
        let d = DesignBuilder.build(c)
        guard d.geometryIssues.isEmpty else { return false }
        let a = Analysis(design: d)
        return a.feasible && !a.checks.contains { $0.severity >= .warning && !["Power", "Performance"].contains($0.category) }
    }

    /// Weighted count of the airframe's problems (power and flight performance left out): 0 = clean.
    nonisolated static func airframePenalty(_ c: AircraftConfig) -> Double {
        let d = DesignBuilder.build(c)
        let a = Analysis(design: d)
        return a.checks.filter { !["Power", "Performance"].contains($0.category) }
            .reduce(Double(d.geometryIssues.count) * 2) { $0 + ($1.severity == .error ? 3 : ($1.severity == .warning ? 1 : 0)) }
    }

    /// Single airframe changes around `base`, cheapest first: every slider ±1…`maxSteps` steps (4 % of its range),
    /// fuselage structure, foam and battery swaps.
    nonisolated static func airframeTrials(_ base: AircraftConfig, maxSteps: Int) -> [(cost: Double, label: String, config: AircraftConfig)] {
        var trials: [(cost: Double, label: String, config: AircraftConfig)] = []
        for p in FixFinder.params where p.applies(base) {
            let range = AircraftConfig.range(p.key, kind: base.kind)
            let step = (range.upperBound - range.lowerBound) * 0.04
            for dir in [-1.0, 1.0] {
                for k in 1...maxSteps {
                    let v = base[keyPath: p.key] + dir * step * Double(k)
                    guard range.contains(v) else { break }
                    var c = base
                    c[keyPath: p.key] = v
                    if p.key == \AircraftConfig.rootChord { c.tipChord = min(c.tipChord, v) }
                    trials.append((Double(k), p.label, c))
                }
            }
        }
        if base.kind.hasFuselage {
            for f in FuselageType.allCases where f != base.fuselageType { var c = base; c.fuselageType = f; trials.append((1.5, "structure", c)) }
        }
        for m in FoamMaterial.allCases where m != base.material && (base.kind != .glider || m.thickness <= 5) { var c = base; c.material = m; trials.append((2, "foam", c)) }
        for b in BatteryPack.allCases where b != base.battery && base.motor.allowedCells.contains(b.cells) { var c = base; c.battery = b; trials.append((2, "battery", c)) }
        return trials.enumerated().sorted { ($0.element.cost, $0.offset) < ($1.element.cost, $1.offset) }.map(\.element)
    }

    /// Screens trials in parallel (strongest servo, balanced) and returns them with their airframe penalty, in order.
    nonisolated static func screen(_ trials: [AircraftConfig]) -> [(config: AircraftConfig, penalty: Double)] {
        let strongest = ServoClass.allCases.max { $0.torque < $1.torque }!
        var out = [(config: AircraftConfig, penalty: Double)?](repeating: nil, count: trials.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: trials.count) { i in
            var q = trials[i]
            q.servo = strongest
            q = balanced(q)
            let pen = airframePenalty(q)
            lock.lock(); out[i] = (q, pen); lock.unlock()
        }
        return out.map { $0! }
    }

    /// Re-sizes a clean airframe (servo, power, balance) and checks it in full.
    nonisolated static func finished(_ q: AircraftConfig) -> AircraftConfig? {
        let s = balanced(lightestServo(q))
        guard airframePenalty(s) == 0 else { return nil }
        let f = powered(s)
        return perfect(f) ? f : nil
    }

    nonisolated static func sized(_ input: AircraftConfig, deadline: TimeInterval = 40) -> AircraftConfig {
        let base = powered(input)
        if perfect(base) { return base }
        let t0 = Date()
        let basePenalty = airframePenalty(base)
        // Stage 1: one change (smallest first). Stage 2: a second change on top of the most promising first ones.
        var promising: [(label: String, config: AircraftConfig, penalty: Double)] = []
        let singles = airframeTrials(base, maxSteps: 15)
        for chunk in stride(from: 0, to: singles.count, by: 32).map({ Array(singles[$0..<min($0 + 32, singles.count)]) }) {
            guard Date().timeIntervalSince(t0) < deadline else { break }
            let screened = screen(chunk.map(\.config))
            for (t, r) in zip(chunk, screened) {
                if r.penalty == 0, let f = finished(r.config) { return f }
                if r.penalty < basePenalty { promising.append((t.label, r.config, r.penalty)) }
            }
        }
        var seen = Set<String>()
        let firsts = promising.sorted { $0.penalty < $1.penalty }.filter { seen.insert($0.label).inserted }.prefix(4)
        for first in firsts {
            let seconds = airframeTrials(first.config, maxSteps: 8).filter { $0.label != first.label }
            for chunk in stride(from: 0, to: seconds.count, by: 32).map({ Array(seconds[$0..<min($0 + 32, seconds.count)]) }) {
                guard Date().timeIntervalSince(t0) < deadline else { break }
                for r in screen(chunk.map(\.config)) where r.penalty == 0 {
                    if let f = finished(r.config) { return f }
                }
            }
        }
        // Last resort: a random airframe of the same type and options that passes everything.
        if let (c, _) = randomVariant(like: base, deadline: 20) { var c = c; c.name = base.name; return c }
        return base
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
            c.batteryPosition = Analysis.fittingPosition(a.bestBatteryPosition, c)
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

    /// A random variant of `current`'s type with its options (fuselage, surfaces, layout, struts): random airframe
    /// (spar on) → lightest sufficient servo → automatic power system → balanced. No score requirement – it may come
    /// with warnings or errors; only airframes whose parts collide (geometry conflicts) are skipped so it can be built.
    nonisolated static func randomDesign(like current: AircraftConfig, attempts: Int = 200) -> AircraftConfig {
        var c = current
        for _ in 0..<attempts {
            c = AircraftConfig.random(kind: current.kind)
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
            if DesignBuilder.build(c).geometryIssues.isEmpty { break }
        }
        return powered(c)
    }

    @Published private(set) var randomizing = false

    /// Random variation of the current type (any score), made in the background.
    func randomize() {
        guard let current = config, !randomizing else { return }
        randomizing = true
        flash("Randomizing …")
        Task.detached(priority: .userInitiated) {
            let c = Project.randomDesign(like: current)
            let a = Analysis(design: DesignBuilder.build(c))
            await MainActor.run {
                self.randomizing = false
                self.config = c
                self.fileURL = nil          // a new design – Save asks for a file
                let errors = a.checks.filter { $0.severity == .error }.count, warnings = a.checks.filter { $0.severity == .warning }.count
                self.flash(a.feasible && a.score == 100 ? "Randomized – all checks passed (score 100)"
                           : "Randomized – score \(a.score)" + (errors > 0 ? ", \(errors) error\(errors == 1 ? "" : "s")" : "") + (warnings > 0 ? ", \(warnings) warning\(warnings == 1 ? "" : "s")" : ""))
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

extension AircraftKind {
    /// What the setup sheet preselects for this type.
    var defaultSetupChoice: SetupChoice {
        let d = defaults
        return SetupChoice(fins: d.taillessFins, layout: ControlLayout(ailerons: d.ailerons, rudder: d.rudder), servos: 2, motors: .single, winglets: false)
    }
}

/// On-disk cache of sized setups (see `Project.feasibleSetup`).
private struct SetupCacheFile: Codable { var build: String; var setups: [String: AircraftConfig] }
