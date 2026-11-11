import Foundation
import simd

enum Severity: Int, Comparable {
    case ok, info, warning, error
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct Check: Identifiable {
    let id = UUID()
    var severity: Severity
    var category: String
    var title: String
    var detail: String
}

extension AircraftConfig {
    /// Wing spar: one solid carbon rod in a groove under the wing along the 30 % chord line. The thinnest size
    /// that keeps the tip deflection at 3 g below 3 % of the half span for a typical weight of this wing
    /// (12 g/dm², at least 60 g); limited to what fits the foam (Ø ≤ thickness − 1 mm, ≥ 1 mm foam above it).
    var sparSpec: CarbonSpar {
        let fits = CarbonSpar.wingRods.filter { $0.widthMM <= material.thickness - 1 + 1e-9 }
        guard !fits.isEmpty else { return CarbonSpar.wingRods[0] }
        let areaDm2 = (kind.isNutBall ? .pi / 4 * rootChord * wingspan : (rootChord + tipChord) * semiSpan) / 1e4
        let mass = max(60, areaDm2 * 12)
        // Thinnest (= lightest) solid rod that is stiff enough, else the thickest that fits.
        return fits.first { StructureReport.wingDeflectionRatio(self, rod: $0, totalMass: mass) < 0.03 } ?? fits.last!
    }
    var sparLength: Double { kind.isNutBall ? wingspan * 0.8 : (wingspan * 0.9) / cos(atan2(sweep, semiSpan)) }
}

/// Mass, balance, aerodynamic and feasibility analysis of a design.
struct Analysis {
    var foamMass = 0.0
    var totalMass = 0.0
    var cg = SIMD3<Double>.zero
    var wingArea = 0.0          // mm²
    var aspectRatio = 0.0
    var mac = 0.0
    var macLE = 0.0             // z of MAC leading edge
    var macY = 0.0
    var neutralPoint = 0.0      // z
    var recommendedCG = 0.0     // z
    var cgRange: ClosedRange<Double> = 0...0
    var staticMargin = 0.0      // fraction of MAC
    var wingLoading = 0.0       // g/dm²
    var stallSpeed = 0.0        // km/h
    var thrust = 0.0            // g
    var thrustToWeight = 0.0
    var flightTime = 0.0        // minutes
    var tailVolumeH = 0.0
    var tailVolumeV = 0.0
    var requiredBatteryPosition = 0.0
    /// Smallest gap between the propeller(s) and the foam (mm).
    var propGap = 0.0
    var batteryLimits: ClosedRange<Double> = 0...0
    /// CG range the battery can produce when moved between its physical limits.
    var achievableCG: ClosedRange<Double> = 0...0
    var cgReachable: Bool { achievableCG.overlaps(cgRange) }
    /// Battery position closest to the target that is physically possible.
    var bestBatteryPosition: Double { min(max(requiredBatteryPosition, batteryLimits.lowerBound), batteryLimits.upperBound) }
    var checks: [Check] = []
    var structure: StructureReport?

    var feasible: Bool { !checks.contains { $0.severity == .error } }
    var worst: Severity { checks.map(\.severity).max() ?? .ok }
    var score: Int {
        let e = checks.filter { $0.severity == .error }.count, w = checks.filter { $0.severity == .warning }.count
        return max(0, 100 - e * 30 - w * 8)
    }

    init(design d: Design) {
        let c = d.config
        let s = c.semiSpan
        let t = c.material.thickness

        // --- Mass & balance
        var moment = SIMD3<Double>.zero
        for p in d.parts {
            for inst in p.instances {
                foamMass += p.massEach
                moment += inst.point(p.centroid2D) * p.massEach
            }
        }
        totalMass = foamMass
        for item in d.components { totalMass += item.mass; moment += item.position * item.mass }
        cg = totalMass > 0 ? moment / totalMass : .zero

        // --- Wing geometry
        let lambda = c.taper
        if c.kind.isNutBall {
            // Elliptic disc (length L = root chord): MAC = 8/(3π)·L centred on the disc, at 4/(3π) of the half span.
            wingArea = .pi / 4 * c.rootChord * c.wingspan
            mac = 8 / (3 * .pi) * c.rootChord
            macY = 4 * s / (3 * .pi)
            macLE = c.rootChord / 2 - mac / 2
        } else {
            wingArea = (c.rootChord + c.tipChord) * s
            mac = 2.0 / 3.0 * c.rootChord * (1 + lambda + lambda * lambda) / (1 + lambda)
            macY = s / 3 * (1 + 2 * lambda) / (1 + lambda)
            macLE = c.sweep * macY / s
        }
        aspectRatio = c.wingspan * c.wingspan / max(wingArea, 1)
        let xacW = macLE + 0.25 * mac
        let aw = 2 * .pi * aspectRatio / (2 + sqrt(aspectRatio * aspectRatio + 4))

        // --- Neutral point & recommended CG
        var targetSM = 0.08, smRange = 0.04...0.14
        if !c.kind.hasTail {
            // Tailless and NutBall: the wing (with its trailing-edge elevator / elevons) is the whole lifting surface.
            neutralPoint = xacW
        } else {
            targetSM = 0.12; smRange = 0.05...0.2
            let sh = c.hStabSpan * c.hStabChord * 0.9
            let lh = (c.tailArm + 0.25 * c.hStabChord) - xacW
            tailVolumeH = sh * lh / (wingArea * mac)
            let sv = c.vStabHeight * c.vStabChord * 1.1 * (c.kind.isTwinBoom ? 2 : 1)
            tailVolumeV = sv * (c.tailArm + c.hStabChord - 0.8 * c.vStabChord - xacW) / (wingArea * c.wingspan)
            let arH = c.hStabSpan * c.hStabSpan / sh
            let at = 2 * .pi * arH / (2 + sqrt(arH * arH + 4))
            let deda = min(0.6, 2 * aw / (.pi * aspectRatio))
            neutralPoint = xacW + mac * tailVolumeH * 0.9 * (at / aw) * (1 - deda)
        }
        recommendedCG = neutralPoint - targetSM * mac
        cgRange = (neutralPoint - smRange.upperBound * mac)...(neutralPoint - smRange.lowerBound * mac)
        staticMargin = (neutralPoint - cg.z) / mac

        let bat = d.components.first { $0.category == "Battery" }
        if let bat {
            let restMoment = cg.z * totalMass - bat.position.z * bat.mass
            requiredBatteryPosition = (recommendedCG * totalMass - restMoment) / bat.mass
        }

        // --- Performance
        wingLoading = totalMass / (wingArea * 1e-4)
        stallSpeed = Analysis.stallSpeed(c, totalMass: totalMass, wingArea: wingArea)
        // A prop smaller than the motor's standard size (jet) gives proportionally less static thrust.
        thrust = c.motor.thrust(cells: c.battery.cells) * Double(c.motorCount) * c.propInches / c.motor.propInches
        thrustToWeight = thrust / max(totalMass, 1)
        let wPerKg: Double = [.glider: 70, .trainer: 100, .twinBoom: 110, .jet: 150, .flyingWing: 120, .delta: 140, .aerobat: 170, .nutBall: 110][c.kind]!
        let current = wPerKg * totalMass / 1000 / c.battery.voltage
        flightTime = c.battery.capacity * 0.8 / 1000 / max(current, 0.01) * 60

        batteryLimits = Analysis.batteryLimits(c)
        if let bat {
            let rest = cg.z * totalMass - bat.position.z * bat.mass
            let a = (rest + bat.mass * batteryLimits.lowerBound) / totalMass, b = (rest + bat.mass * batteryLimits.upperBound) / totalMass
            achievableCG = min(a, b)...max(a, b)
        }
        runChecks(d, t: t)
    }

    static func stallSpeed(_ c: AircraftConfig, totalMass: Double, wingArea: Double) -> Double {
        let clMax = c.kind.isTailless ? 0.65 : (c.kind.isNutBall ? 0.95 : 0.8)
        return sqrt(2 * totalMass / 1000 * 9.81 / (1.225 * wingArea * 1e-6 * clMax)) * 3.6
    }

    /// All-up mass (g) and stall speed (km/h) of a design – the inputs of the structure load case, without the
    /// rest of the analysis (used by the strut planner while the design is being built).
    static func massAndStall(_ d: Design) -> (mass: Double, stall: Double) {
        let c = d.config
        var m = d.components.reduce(0) { $0 + $1.mass }
        for p in d.parts { m += p.massEach * Double(p.instances.count) }
        let area = c.kind.isNutBall ? .pi / 4 * c.rootChord * c.wingspan : (c.rootChord + c.tipChord) * c.semiSpan
        return (m, stallSpeed(c, totalMass: m, wingArea: area))
    }

    static func batteryLimits(_ c: AircraftConfig) -> ClosedRange<Double> {
        if c.kind.isTailless {
            let front = c.battery.size.l / 2 - 8
            return front...max(front, c.rootChord * 0.55)
        }
        if c.kind.isNutBall { return (-c.noseLength + c.battery.size.l / 2 + 8)...(c.rootChord * 0.45) }
        if c.kind.isJet { return (-c.noseLength + c.battery.size.l / 2 + 15)...(c.rootChord * 0.35) }
        if c.kind.isTwinBoom { return (-c.noseLength + c.battery.size.l / 2 + 5)...(c.rootChord * 0.6) }
        // The central aileron servo pokes out of both sides of the lower fuselage half: the battery (on its side)
        // has to stay ahead of it.
        let aft = c.hasCentralAileronServo ? min(c.rootChord, c.centralAileronServoU - c.servo.size.l / 2 - 3 - c.battery.size.l / 2) : c.rootChord
        let front = -c.noseLength + c.battery.size.l / 2 + 5
        return front...max(front, aft)
    }

    private mutating func add(_ sev: Severity, _ cat: String, _ title: String, _ detail: String) {
        checks.append(Check(severity: sev, category: cat, title: title, detail: detail))
    }

    private mutating func runChecks(_ d: Design, t: Double) {
        let c = d.config
        let f1 = { (v: Double) in String(format: "%.1f", v) }
        let f0 = { (v: Double) in String(format: "%.0f", v) }

        // Geometry
        if c.wingspan > maxWingspan + 0.5 { add(.error, "Geometry", "Wingspan exceeds \(Int(maxWingspan)) mm", "FoamMaster designs micro models up to \(Int(maxWingspan)) mm span.") }
        for issue in d.geometryIssues { add(.error, "Geometry", "Geometry conflict", issue) }
        for p in d.parts where !Poly.isSimple(p.outline) { add(.error, "Geometry", "\(p.name) outline is self-intersecting", "Reduce sweep or adjust chord lengths.") }
        if c.tipChord < 25 && !c.kind.isNutBall { add(.error, "Geometry", "Tip chord too small", "\(f0(c.tipChord)) mm – minimum 25 mm to keep the tip buildable.") }
        if c.taper < 0.2 && c.kind != .delta && !c.kind.isNutBall { add(.warning, "Aero", "Strong taper (λ = \(String(format: "%.2f", c.taper)))", "Tapers below 0.2 tend to tip-stall on flat foam wings.") }
        let arRange: ClosedRange<Double> = c.kind.isNutBall ? 0.9...2.2 : (c.kind == .delta ? 1.2...4 : (c.kind.isTailless ? 2.5...8 : 3...11))
        if !arRange.contains(aspectRatio) { add(.warning, "Aero", "Aspect ratio \(f1(aspectRatio)) unusual", "Typical range for a \(c.kind.title): \(f1(arRange.lowerBound))–\(f1(arRange.upperBound)).") }
        else { add(.ok, "Aero", "Aspect ratio \(f1(aspectRatio))", "Within the typical range for a \(c.kind.title).") }
        if c.controlChordPct * c.tipChord < 10 && (c.kind.isTailless || c.hasAilerons) && !c.kind.isNutBall { add(.warning, "Geometry", "Control surfaces very narrow at the tip", "Less than 10 mm chord – hard to hinge cleanly.") }

        // Loading & power
        switch wingLoading {
        case ..<12: add(.ok, "Performance", "Wing loading \(f1(wingLoading)) g/dm²", "Very light – slow and floaty, ideal for indoor/park.")
        case ..<20: add(.ok, "Performance", "Wing loading \(f1(wingLoading)) g/dm²", "Good park-flyer loading.")
        case ..<28: add(.warning, "Performance", "Wing loading \(f1(wingLoading)) g/dm²", "On the heavy side for flat foam – expect a fast stall (\(f0(stallSpeed)) km/h).")
        default: add(.error, "Performance", "Wing loading \(f1(wingLoading)) g/dm²", "Too heavy for a flat foam wing. Increase area, lighter battery or thinner foam.")
        }
        if !c.motor.allowedCells.contains(c.battery.cells) {
            add(.error, "Power", "Battery not compatible with motor", "\(c.motor.name) runs on \(c.motor.allowedCells.lowerBound)–\(c.motor.allowedCells.upperBound)S, selected \(c.battery.cells)S.")
        } else if thrustToWeight < c.kind.minThrustToWeight * 0.7 {
            add(.error, "Power", "Thrust/weight \(f1(thrustToWeight))", "Far below the \(f1(c.kind.minThrustToWeight)) needed – it will not climb.")
        } else if thrustToWeight < c.kind.minThrustToWeight {
            add(.warning, "Power", "Thrust/weight \(f1(thrustToWeight))", "Below the recommended \(f1(c.kind.minThrustToWeight)) for this type.")
        } else {
            add(.ok, "Power", "Thrust/weight \(f1(thrustToWeight))", "\(f0(thrust)) g static thrust for \(f0(totalMass)) g.")
        }
        // Typical flat-foam weights grow with the span squared: ~250 g at 600 mm, ~450 g at 800 mm.
        let heavy = max(260, 260 * pow(c.wingspan / 600, 2))
        if totalMass > heavy { add(.warning, "Performance", "Heavy for a micro model", "\(f0(totalMass)) g – most \(f0(c.wingspan)) mm flat foamies are below \(f0(heavy - 10)) g.") }

        // Balance
        let cgNow = cg.z
        if cgRange.contains(cgNow) {
            add(.ok, "Balance", "CG in range", "CG \(f1(cgNow)) mm behind LE, static margin \(f0(staticMargin * 100)) %.")
        } else {
            add(.warning, "Balance", "CG out of range (\(f1(cgNow)) mm)", "Recommended \(f1(cgRange.lowerBound))–\(f1(cgRange.upperBound)) mm. Move battery to \(f0(requiredBatteryPosition)) mm.")
        }
        let batLimits = Analysis.batteryLimits(c)
        if !cgReachable {
            add(.error, "Balance", "CG cannot be reached with the battery",
                "Battery would have to sit at \(f0(requiredBatteryPosition)) mm (allowed \(f0(batLimits.lowerBound))…\(f0(batLimits.upperBound))). " +
                (requiredBatteryPosition < batLimits.lowerBound
                    ? (c.kind.isTailless ? "Use “Fix with bigger battery” or reduce sweep." : "Use “Fix with bigger battery”, lengthen the nose or shorten the tail.")
                    : "Use a lighter battery, shorten the nose or move mass aft."))
        }
        if staticMargin < 0 { add(.warning, "Balance", "Currently tail-heavy (unstable)", "Negative static margin with the current battery position.") }

        if c.kind.isTailless && c.taillessFins == .none {
            let sweepRatio = c.sweep / max(c.semiSpan, 1)
            if sweepRatio < 0.35 { add(.warning, "Stability", "No fins and little sweep", "Without winglets or a fin the wing needs more sweep for yaw stability (sweep ≥ 35 % of the half span).") }
            else { add(.info, "Stability", "Finless wing", "Yaw stability comes from the sweep only – expect some wag in turbulence.") }
        }
        if c.kind.isNutBall {
            if !c.hasRudder { add(.warning, "Controls", "No rudder", "A NutBall turns with the rudder – elevator only gives no roll or yaw control.") }
            let finArea = c.vStabHeight * c.vStabChord * 0.75
            var vv = finArea * (c.rootChord * (1 - c.controlChordPct) - 0.4 * c.vStabChord - cgRange.upperBound) / (wingArea * c.wingspan)
            if c.tailWinglets && c.wingletHeight > 5 {
                // Both top winglets add fin area aft of the CG.
                let w = c.nutBallWinglet
                vv += 2 * c.wingletHeight * w.chord * 0.8 * max(0, w.u0 + w.chord * 0.4 - cgRange.upperBound) / (wingArea * c.wingspan)
            }
            if vv < 0.012 { add(.warning, "Stability", "Small fin for the disc", "Fin volume \(String(format: "%.3f", vv)) – the NutBall will wander in yaw. Make the fin taller or longer.") }
            else { add(.ok, "Stability", "Fin size OK", "Fin volume \(String(format: "%.3f", vv)) – rudder turns the disc through its natural roll coupling.") }
        } else if !c.kind.isTailless && !c.hasAilerons {
            add(.warning, "Controls", "No ailerons on a flat wing", "Without dihedral, rudder-only planes roll very slowly. Choose a layout with ailerons.")
        }
        // Tail
        if c.kind.hasTail {
            if tailVolumeH < 0.3 { add(.warning, "Stability", "Horizontal tail volume \(String(format: "%.2f", tailVolumeH))", "Below 0.30 – pitch will be twitchy. Bigger stab or longer tail arm.") }
            else if tailVolumeH > 0.9 { add(.warning, "Stability", "Horizontal tail volume \(String(format: "%.2f", tailVolumeH))", "Very large – heavy tail, sluggish pitch.") }
            else { add(.ok, "Stability", "Horizontal tail volume \(String(format: "%.2f", tailVolumeH))", "Good pitch stability.") }
            if tailVolumeV < 0.02 { add(.warning, "Stability", "Vertical tail volume \(String(format: "%.3f", tailVolumeV))", "Below 0.020 – weak yaw stability, enlarge the fin.") }
            else { add(.ok, "Stability", "Vertical tail volume \(String(format: "%.3f", tailVolumeV))", "Adequate yaw stability.") }
        }

        // Structure – beam physics (see StructureReport)
        let st = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed, struts: d.struts)
        structure = st
        let pct = st.wingDeflectionRatio * 100
        // Strut hints per group (the warnings can be cleared by switching that group On in the editor).
        func strutHint(_ mode: StrutMode, fitted: Int, group: String) -> String {
            if fitted > 0 { return "" }
            switch mode {
            case .always: return " (No \(group.lowercased()) struts fit this layout.)"
            case .off: return " Or switch \(group) struts on (Auto / On)."
            case .auto: return " Or set \(group) struts to On to brace it."
            }
        }
        let wingHint = strutHint(c.wingStruts, fitted: st.wingStruts, group: "Wing")
        let tailHint = c.offersTailStruts ? strutHint(c.tailStruts, fitted: st.tailStruts, group: "Tail") : ""
        let wingFix = (c.sparEnabled ? "Use thicker foam, a bigger spar or reduce span." : "Enable the carbon spar.") + wingHint
        let wingWith = (c.sparEnabled ? " with the \(c.sparSpec.name) spar" : "") + (st.wingStruts > 0 ? " and \(st.wingStruts) carbon struts" : "")
        if pct >= StructureReport.wingErrorPct { add(.error, "Structure", "Wing far too flexible", "Tip bends \(f0(st.wingTipDeflection)) mm (\(f0(pct)) % of the half span) at 3 g\(wingWith). \(wingFix)") }
        else if pct >= StructureReport.wingWarnPct { add(.warning, "Structure", "Wing flexes noticeably", "Tip bends \(f0(st.wingTipDeflection)) mm (\(f1(pct)) %) at 3 g\(wingWith). \(wingFix)") }
        else { add(.ok, "Structure", "Wing stiffness OK", "Tip deflection \(f1(st.wingTipDeflection)) mm (\(f1(pct)) %) at 3 g\(wingWith).") }
        if !d.struts.isEmpty {
            let rods = Dictionary(grouping: d.struts, by: \.diameter).sorted { $0.key < $1.key }
                .map { "\($0.value.count) × \(CarbonSpar.strutRod($0.key).name)" }.joined(separator: ", ")
            let saddles = d.struts.filter { $0.b.saddle != nil }.count / 2
            let doubles = d.struts.filter { $0.a.shared != nil }.count / 2
            let anchors = d.struts.count * 2 - saddles * 2 - doubles * 2
            let mounts = [anchors > 0 ? "\(anchors) printed anchors" : nil, doubles > 0 ? "\(doubles) double anchors on the wing" : nil,
                          saddles > 0 ? "\(saddles) one-piece saddle\(saddles > 1 ? "s" : "") under the fuselage" : nil]
                .compactMap { $0 }.joined(separator: " + ")
            // Per group: fitted on request (On) or because that part would otherwise fail (Auto).
            let groups: [(Int, StrutMode, String, String)] = [(st.wingStruts, c.wingStruts, "wing", "the wing would be too flexible"),
                                                               (st.tailStruts, c.tailStruts, "tail", "the fuselage would twist / bend too much"),
                                                               (st.finStruts, c.finStruts, "fin", "they brace the fin with the other struts")]
            let why = groups.filter { $0.0 > 0 }.map { "\($0.2): \($0.1 == .always ? "on request" : $0.3)" }.joined(separator: "; ")
            add(.info, "Structure", "Carbon struts", "\(rods) (\(why)), \(mounts) – marked S1… on the plans. They keep clear of servos, pushrods, horns, battery, control-surface travel and the prop.")
            if st.finStruts > 0, let bare = st.finFlexBareDeg, let braced = st.finFlexDeg {
                add(.ok, "Structure", "Fin braced", "\(st.finStruts) fin struts from the stabiliser: the fin tilts \(String(format: "%.2f", braced))° instead of \(f1(bare))° at \(c.hasRudder ? "full rudder" : "a strong side gust"), \(f0(st.loadSpeed)) km/h. They keep clear of elevator and rudder travel (±\(Int(c.kind.maxSurfaceThrow))°).")
            }
            for note in d.strutNotes { add(.warning, "Structure", "Fin not braced", note + " Lengthen the nose or use a heavier battery – the fin struts are then added automatically.") }
            if st.strutsBuckle { add(.warning, "Structure", "Strut may buckle", "Up to \(f1(st.maxStrutForce)) N in a strut at the load case – too close to its buckling load. Use a thicker foam or smaller tail surfaces.") }
        }
        if c.material.thickness >= 8 && c.wingspan < 350 { add(.info, "Structure", "Thick foam on a small model", "\(Int(c.material.thickness)) mm sheet adds weight – 5/6 mm is usually enough.") }

        // Servos: hinge moment H = Ch · q · S · c at ~2.5 × stall speed (min 30 km/h), Ch ≈ 0.4 at full throw.
        let vMax = max(stallSpeed * 2.5, 30) / 3.6
        let q = 0.5 * 1.225 * vMax * vMax
        var servoOK = true
        var loads: [String: Double] = [:]
        for ctrl in d.controls {
            loads[ctrl.servoID, default: 0] += 0.4 * q * (ctrl.area * 1e-6) * (ctrl.chord * 1e-3) * 10.2   // kg·cm
        }
        for (servo, hinge) in loads.sorted(by: { $0.key < $1.key }) where hinge > c.servo.torque * 0.6 {
            servoOK = false
            add(.warning, "Servos", "\(servo): servo marginal", "Hinge moment ≈\(String(format: "%.2f", hinge)) kg·cm at \(f0(vMax * 3.6)) km/h vs \(c.servo.torque) kg·cm servo (want 40 % reserve).")
        }
        if servoOK { add(.ok, "Servos", "Servo torque sufficient", "\(loads.count) × \(c.servo.name) with ≥40 % reserve.") }

        // Fuselage / tail boom stiffness
        if let bend = st.tailBendDeg, let twist = st.tailTwistDeg {
            let speed = f0(st.loadSpeed)
            let twistFix = c.kind.isTwinBoom ? "Increase the boom spacing (stab span) or shorten the tail arm."
                : "Increase fuselage height, use thicker/stiffer foam or shorten the tail arm." + tailHint
            let braced = st.tailStruts > 0 ? ", \(st.tailStruts) tail struts" : ""
            // Worst case: full rudder (or, without a rudder, an equally strong side gust on the fin) at twice the stall speed.
            let load = c.hasRudder ? "full rudder" : "a strong side gust"
            if twist >= StructureReport.twistErrorDeg { add(.error, "Structure", "Fuselage twists too much", "\(f1(twist))° twist at \(load), \(speed) km/h\(braced) – the tail will flutter\(c.hasRudder ? " and rudder input rolls the plane" : ""). \(twistFix)") }
            else if twist >= StructureReport.twistWarnDeg { add(.warning, "Structure", "Fuselage is soft in torsion", "\(f1(twist))° twist at \(load), \(speed) km/h\(braced). \(twistFix)") }
            else { add(.ok, "Structure", "Torsion OK", "\(f1(twist))° twist at \(load), \(speed) km/h (\(c.kind.isTwinBoom ? "twin booms" : c.fuselageType.name)\(braced)).") }
            let bendFix = (c.kind.isTwinBoom ? "Shorten the tail arm or use a smaller stabiliser." : "Increase fuselage height or shorten the tail arm.") + (c.kind.isTwinBoom ? "" : tailHint)
            if bend >= StructureReport.bendErrorDeg { add(.error, "Structure", "Tail boom bends too much", "\(f1(bend))° tail deflection at full elevator\(braced). \(bendFix)") }
            else if bend >= StructureReport.bendWarnDeg { add(.warning, "Structure", "Tail boom flexes", "\(f1(bend))° tail deflection at full elevator\(braced). \(bendFix)") }
            else { add(.ok, "Structure", "Boom bending OK", "\(String(format: "%.2f", bend))° tail deflection at full elevator\(braced).") }
        }

        // Propeller clearance
        let r = c.propRadius
        if c.isDual {
            let clear = c.dualMotorX - r - c.dualBodyHalfWidth
            if clear < AircraftConfig.propClearance - 0.5 { add(.error, "Geometry", "Props hit the fuselage", "Dual motors at ±\(f0(c.dualMotorX)) mm leave \(f1(clear)) mm prop clearance – use smaller props.") }
            else { add(.ok, "Geometry", "Dual tractor layout", "Motors at ±\(f0(c.dualMotorX)) mm (\(f0(c.dualMotorX * 2)) mm apart) – as far inboard as the \(f1(clear)) mm prop clearance allows, counter-rotating.") }
        } else if c.kind.isTailless {
            let clear = c.motorNotchHalfWidth - r
            add(.ok, "Geometry", "Motor sits in the trailing-edge cutout", "\(f0(c.motorNotchHalfWidth * 2)) × \(f0(c.motorNotchDepth)) mm cutout up to the elevons, \(f1(clear)) mm prop clearance each side.")
            if c.battery.size.l > c.rootChord * 0.7 { add(.warning, "Geometry", "Battery long for the centre section", "Battery \(f0(c.battery.size.l)) mm vs root chord \(f0(c.rootChord)) mm.") }
        } else if r > c.noseLength * 1.6 {
            add(.info, "Geometry", "Large prop on a short nose", "Hand-launch carefully, keep fingers clear.")
        }
        if c.mountStandoff > 25 {
            add(.info, "Geometry", "Long motor standoff (\(f0(c.mountStandoff)) mm)", "The swept leading edge needs the motors \(f0(c.mountStandoff)) mm ahead of the clamp – print the mounts with 4+ walls / 100 % infill.")
        }
        // Measured gap between the spinning prop (tips, blade faces, spinner) and every foam part.
        let pc = PropClearance.evaluate(d)
        propGap = pc.gap
        let need = AircraftConfig.propClearance
        if pc.gap < 1 {
            add(.error, "Geometry", "Propeller hits the \(pc.part.lowercased())",
                "The spinning prop reaches into the \(pc.part.lowercased()) (gap \(f1(pc.gap)) mm) and would cut it. Use a smaller prop or move the motor away from it.")
        } else if pc.gap < need - 0.5 {
            add(.warning, "Geometry", "Propeller close to the \(pc.part.lowercased())",
                "Only \(f1(pc.gap)) mm between the prop and the \(pc.part.lowercased()) – \(f0(need)) mm recommended so flex and vibration never let it touch.")
        } else {
            add(.ok, "Geometry", "Propeller clearance \(f1(min(pc.gap, 99))) mm", "Closest foam part: \(pc.part.isEmpty ? "none nearby" : pc.part.lowercased()) (\(f0(need)) mm required).")
        }
        add(.info, "Performance", "Estimated flight time \(f0(flightTime)) min", "Stall ≈ \(f0(stallSpeed)) km/h, AUW \(f0(totalMass)) g.")
        checks.sort { $0.severity > $1.severity }
    }
}
