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
        let sM2 = wingArea * 1e-6
        wingLoading = totalMass / (wingArea * 1e-4)
        let clMax = c.kind.isTailless ? 0.65 : (c.kind.isNutBall ? 0.95 : 0.8)
        stallSpeed = sqrt(2 * totalMass / 1000 * 9.81 / (1.225 * sM2 * clMax)) * 3.6
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
            let vv = finArea * (c.rootChord * (1 - c.controlChordPct) - 0.4 * c.vStabChord - cgRange.upperBound) / (wingArea * c.wingspan)
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
        let st = StructureReport(c, totalMass: totalMass, stallSpeed: stallSpeed)
        structure = st
        let pct = st.wingDeflectionRatio * 100
        let wingFix = c.sparEnabled ? "Use thicker foam, a bigger spar or reduce span." : "Enable the carbon spar (top + bottom)."
        if pct >= 10 { add(.error, "Structure", "Wing far too flexible", "Tip bends \(f0(st.wingTipDeflection)) mm (\(f0(pct)) % of the half span) at 3 g. \(wingFix)") }
        else if pct >= 4 { add(.warning, "Structure", "Wing flexes noticeably", "Tip bends \(f0(st.wingTipDeflection)) mm (\(f1(pct)) %) at 3 g. \(wingFix)") }
        else { add(.ok, "Structure", "Wing stiffness OK", "Tip deflection \(f1(st.wingTipDeflection)) mm (\(f1(pct)) %) at 3 g\(c.sparEnabled ? " with spars top + bottom" : "").") }
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
                : "Increase fuselage height, use thicker/stiffer foam or shorten the tail arm."
            // Worst case: full rudder (or, without a rudder, an equally strong side gust on the fin) at twice the stall speed.
            let load = c.hasRudder ? "full rudder" : "a strong side gust"
            if twist >= 6 { add(.error, "Structure", "Fuselage twists too much", "\(f1(twist))° twist at \(load), \(speed) km/h – the tail will flutter\(c.hasRudder ? " and rudder input rolls the plane" : ""). \(twistFix)") }
            else if twist >= 3 { add(.warning, "Structure", "Fuselage is soft in torsion", "\(f1(twist))° twist at \(load), \(speed) km/h. \(twistFix)") }
            else { add(.ok, "Structure", "Torsion OK", "\(f1(twist))° twist at \(load), \(speed) km/h (\(c.kind.isTwinBoom ? "twin booms" : c.fuselageType.name)).") }
            let bendFix = c.kind.isTwinBoom ? "Shorten the tail arm or use a smaller stabiliser." : "Increase fuselage height or shorten the tail arm."
            if bend >= 3 { add(.error, "Structure", "Tail boom bends too much", "\(f1(bend))° tail deflection at full elevator. \(bendFix)") }
            else if bend >= 1 { add(.warning, "Structure", "Tail boom flexes", "\(f1(bend))° tail deflection at full elevator. \(bendFix)") }
            else { add(.ok, "Structure", "Boom bending OK", "\(String(format: "%.2f", bend))° tail deflection at full elevator.") }
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
