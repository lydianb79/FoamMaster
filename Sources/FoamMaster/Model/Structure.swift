import Foundation
import simd

extension FoamMaterial {
    /// Young's modulus (N/mm² = MPa). Extruded polystyrene sheet (Depron) vs. expanded polypropylene.
    var modulus: Double { family == .depron ? 18 : 3 }
    /// Shear modulus (MPa), isotropic estimate E / 2.6.
    var shearModulus: Double { modulus / 2.6 }
}

/// Simple beam models for the airframe, evaluated at a demanding but realistic load case:
/// full control deflection at twice the stall speed (min. 30 km/h) and a 3 g pull for the wing.
struct StructureReport {
    static let carbonE = 110_000.0     // MPa, pultruded carbon
    static let carbonTubeG = 5_000.0   // MPa, pultruded tube in torsion

    // Limits used by the checks (and by the strut planner to decide when struts are needed).
    static let wingErrorPct = 10.0, wingWarnPct = 4.0
    static let twistErrorDeg = 6.0, twistWarnDeg = 3.0
    static let bendErrorDeg = 3.0, bendWarnDeg = 1.0
    /// Safety factor of a strut in compression against Euler buckling.
    static let strutBucklingSafety = 1.5

    var loadSpeed = 0.0                // km/h
    var wingTipDeflection = 0.0        // mm at 3 g
    var wingDeflectionRatio = 0.0      // tip deflection / semi span
    var tailBendDeg: Double?           // tail rotation from elevator load
    var tailTwistDeg: Double?          // fuselage twist from rudder load
    var bendingStiffness: Double?      // EI of the tail boom (N·mm²)
    var torsionStiffness: Double?      // GJ of the tail boom (N·mm²)
    /// Struts fitted (wing / tail) and whether any of them would buckle at the load case.
    var wingStruts = 0
    var tailStruts = 0
    var finStruts = 0
    var strutsBuckle = false
    /// Sideways tilt of the fin at full rudder (degrees): bare foam fin, and with the fin struts (nil without a fin).
    var finFlexBareDeg: Double?
    var finFlexDeg: Double?
    /// Largest axial strut force at the load case (N) and the matching buckling load.
    var maxStrutForce = 0.0

    /// Bending stiffness of the wing root section: foam plate plus an optional carbon rod whose bottom is flush with
    /// the underside (composite section, transformed about the common neutral axis). N·mm².
    static func wingEI(_ c: AircraftConfig, rod: CarbonSpar?) -> Double {
        let t = c.material.thickness, Ef = c.material.modulus
        // NutBall: the disc's mean chord over the half span (π/4 of its length) carries the bending.
        let b = c.rootChord * (c.kind.isNutBall ? .pi / 4 : 1)
        let Af = b * t, If = b * t * t * t / 12
        guard let rod else { return Ef * If }
        let Ac = rod.roundArea, Ic = rod.roundEI / carbonE
        let e = t / 2 - rod.widthMM / 2                    // rod centre below the foam centre
        let yNA = carbonE * Ac * e / (Ef * Af + carbonE * Ac)
        return Ef * (If + Af * yNA * yNA) + carbonE * (Ic + Ac * (e - yNA) * (e - yNA))
    }
    /// Tip deflection / half span at 3 g (uniform load on a cantilever half wing).
    static func wingDeflectionRatio(_ c: AircraftConfig, rod: CarbonSpar?, totalMass: Double) -> Double {
        wingDeflection(c, rod: rod, totalMass: totalMass, strutAt: 0, strutK: 0).ratio
    }

    /// Half wing as a cantilever (uniform 3 g load) propped by struts at station `a` with vertical spring stiffness
    /// `k` (N/mm): the strut reaction R follows from compatibility at a, the deflection from superposition.
    /// Returns the largest deflection / half span and the reaction (N).
    static func wingDeflection(_ c: AircraftConfig, rod: CarbonSpar?, totalMass: Double, strutAt a: Double, strutK k: Double)
        -> (ratio: Double, reaction: Double) {
        let L = c.semiSpan
        let F = 3 * totalMass * 9.81e-3 / 2, w = F / L
        let EI = wingEI(c, rod: rod)
        func uniform(_ x: Double) -> Double { w * x * x * (6 * L * L - 4 * L * x + x * x) / (24 * EI) }
        func unit(_ x: Double) -> Double { x <= a ? x * x * (3 * a - x) / (6 * EI) : a * a * (3 * x - a) / (6 * EI) }
        var R = 0.0
        if k > 0 && a > 0 && a < L { R = uniform(a) / (unit(a) + 1 / k) }
        var worst = 0.0
        for i in 1...40 {
            let x = L * Double(i) / 40
            worst = max(worst, abs(uniform(x) - R * unit(x)))
        }
        return (worst / L, R)
    }

    init(_ c: AircraftConfig, totalMass: Double, stallSpeed: Double, struts: [Strut] = []) {
        let t = c.material.thickness
        let E = c.material.modulus, G = c.material.shearModulus
        let v = max(stallSpeed * 2, 30) / 3.6
        loadSpeed = v * 3.6
        let q = 0.5 * 1.225 * v * v * 1e-6          // N/mm²

        // Wing half as a cantilever plate + carbon rod spar in a groove underneath, uniform 3 g load.
        let L = c.semiSpan
        // Wing struts on one side (right): vertical spring stiffness Σ k·(e·ŷ)² at their mean station, k = rod in
        // series with its two anchors on the foam (Strut.stiffness).
        let wingRight = struts.filter { $0.group == .wing && $0.a.surface.x > 0 }
        wingStruts = struts.filter { $0.group == .wing }.count
        var kWing = 0.0, station = 0.0
        for st in wingRight {
            let ey = st.direction.y
            kWing += st.stiffness(c.material) * ey * ey
            station += abs(st.a.rodEnd.x) / Double(wingRight.count)
        }
        let wd = Self.wingDeflection(c, rod: c.sparEnabled ? c.sparSpec : nil, totalMass: totalMass, strutAt: station, strutK: kWing)
        wingDeflectionRatio = wd.ratio
        wingTipDeflection = wingDeflectionRatio * L
        for st in wingRight where kWing > 0 {
            // Share of the reaction by stiffness; rods above the wing are in compression under positive g.
            let ey = st.direction.y
            let share = st.stiffness(c.material) * ey * ey / kWing * wd.reaction
            let force = share / max(abs(ey), 1e-3)
            maxStrutForce = max(maxStrutForce, force)
            if st.b.rodEnd.y > st.a.rodEnd.y && force * Self.strutBucklingSafety > st.bucklingLoad { strutsBuckle = true }
        }
        _ = (t, E)

        // Fin bracing: the fin is a foam plate cantilevered from the stabiliser/plate; full rudder (0.7·q·S) at half
        // its height tilts it sideways about its root line (bare k = 2EI/h, I = chord·t³/12 of the fin web).
        // Fin struts from the fixed stabiliser up to the fin side add k·((ẑ × r)·e)² each (r from the root line to
        // the rod's fin end), like the tail struts on the boom.
        if !c.kind.isTailless && !c.kind.isTwinBoom && c.vStabHeight > 5 {
            let h = c.vStabHeight, fc = c.vStabChord
            let tf = t * Double(c.fuselageType.webLayers)
            let kBare = 2 * E * fc * tf * tf * tf / 12 / h
            let fin = struts.filter { $0.group == .fin }
            finStruts = fin.count
            let root = SIMD3<Double>(0, fin.first.map { $0.a.surface.y } ?? t / 2, 0)
            let lever = { (st: Strut) in simd_dot(simd_cross([0, 0, 1], st.b.rodEnd - root), st.direction) }
            let kFin = kBare + fin.reduce(0) { $0 + $1.stiffness(c.material) * lever($1) * lever($1) }
            let Mf = 0.7 * q * h * fc * h / 2
            finFlexBareDeg = Mf / kBare * 180 / .pi
            let th = Mf / kFin
            finFlexDeg = th * 180 / .pi
            for st in fin {
                let force = st.stiffness(c.material) * abs(lever(st) * th)
                maxStrutForce = max(maxStrutForce, force)
                if force * Self.strutBucklingSafety > st.bucklingLoad { strutsBuckle = true }
            }
        }

        guard c.kind.hasTail else { return }
        let Sh = c.hStabSpan * c.hStabChord, Sv = c.vStabHeight * c.vStabChord * (c.kind.isTwinBoom ? 2 : 1)
        let Fh = 0.7 * q * Sh, Fv = 0.7 * q * Sv
        let boom = c.tailArm + 0.25 * c.hStabChord - c.rootChord

        if c.kind.isTwinBoom {
            let tube = CarbonSpar.tube4
            let D = tube.widthMM, d = D - 1
            let I = Double.pi / 64 * (pow(D, 4) - pow(d, 4)), J = Double.pi / 32 * (pow(D, 4) - pow(d, 4))
            let EIb = 2 * Self.carbonE * I
            bendingStiffness = EIb
            tailBendDeg = Fh * boom * boom / (2 * EIb) * 180 / .pi
            // Rudder side load on the fins rolls the tail: resisted by differential boom bending + tube torsion.
            let kRot = 2 * (3 * Self.carbonE * I / pow(boom, 3)) * c.boomX * c.boomX + 2 * Self.carbonTubeG * J / boom
            torsionStiffness = kRot * boom
            tailTwistDeg = Fv * (c.vStabHeight / 2) / kRot * 180 / .pi
            return
        }

        // Cross fuselage at mid boom: vertical web (upper + plate + lower) and horizontal plate.
        let fh = c.fuselageHeight
        let tw = t * Double(c.fuselageType.webLayers)
        let hWing = fh * 0.5 - t / 2, hBoom = c.boomTopHeight
        let hu = (hWing * 0.9 + hBoom) / 2
        let hl = (hWing + c.lowerTailHeight) / 2
        let H = hu + t + hl
        let W = c.fuselagePlateWidth, wb = c.plateTailWidth, wp = (W + wb) / 2
        // Bending: foam web + 4 carbon chords (top/bottom edge, both sides) + optional tube near the axis.
        // Foam only – the fuselage carries no carbon (only the wing spar is carbon).
        let EIv = E * tw * H * H * H / 12 + E * wp * t * t * t / 12
        // Torsion: open thin-walled section Σ b·t³/3 (laminated layers act as one thick web).
        let GJ = G * ((hu + hl) * tw * tw * tw / 3 + wp * t * t * t / 3)
        bendingStiffness = EIv
        torsionStiffness = GJ
        // Rotational stiffness of the boom (N·mm/rad) – tail rotation = moment / stiffness:
        // bending θ = F·boom²/(2EI) → k = 2EI/boom, torsion θ = M·boom/GJ → k = GJ/boom.
        // Tail struts tie the tail to the wing: a rigid-body rotation ω of the tail stretches each rod by
        // (ω × r)·e, so each adds k·((ω × r)·e)² (r from the rotation axis to the rod's tail end, k = rod in series
        // with its anchors on the foam).
        let tail = struts.filter { $0.group == .tail }
        tailStruts = tail.count
        let pivot = SIMD3<Double>(0, 0, c.rootChord)
        func strutK(_ omega: SIMD3<Double>, about p0: SIMD3<Double>) -> Double {
            tail.reduce(0) { k, st in
                let lever = simd_dot(simd_cross(omega, st.b.rodEnd - p0), st.direction)
                return k + st.stiffness(c.material) * lever * lever
            }
        }
        let kBend = 2 * EIv / boom + strutK([1, 0, 0], about: pivot)
        let kTwist = GJ / boom + strutK([0, 0, 1], about: .zero)
        let Mb = Fh * boom, zv = hBoom + c.vStabHeight / 2, Mt = Fv * zv
        let thB = Mb / kBend, thT = Mt / kTwist
        tailBendDeg = thB * 180 / .pi
        tailTwistDeg = thT * 180 / .pi
        // Rod forces: either rod of a pair can be the compressed one when the load reverses.
        for st in tail {
            let lb = simd_dot(simd_cross([1, 0, 0], st.b.rodEnd - pivot), st.direction)
            let lt = simd_dot(simd_cross([0, 0, 1], st.b.rodEnd), st.direction)
            let force = st.stiffness(c.material) * (abs(lb * thB) + abs(lt * thT))
            maxStrutForce = max(maxStrutForce, force)
            if force * Self.strutBucklingSafety > st.bucklingLoad { strutsBuckle = true }
        }
    }
}
