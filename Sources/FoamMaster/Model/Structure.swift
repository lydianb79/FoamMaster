import Foundation

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

    var loadSpeed = 0.0                // km/h
    var wingTipDeflection = 0.0        // mm at 3 g
    var wingDeflectionRatio = 0.0      // tip deflection / semi span
    var tailBendDeg: Double?           // tail rotation from elevator load
    var tailTwistDeg: Double?          // fuselage twist from rudder load
    var bendingStiffness: Double?      // EI of the tail boom (N·mm²)
    var torsionStiffness: Double?      // GJ of the tail boom (N·mm²)

    init(_ c: AircraftConfig, totalMass: Double, stallSpeed: Double) {
        let t = c.material.thickness
        let E = c.material.modulus, G = c.material.shearModulus
        let v = max(stallSpeed * 2, 30) / 3.6
        loadSpeed = v * 3.6
        let q = 0.5 * 1.225 * v * v * 1e-6          // N/mm²

        // Wing half as a cantilever plate + carbon strips top and bottom, uniform 3 g load.
        let L = c.semiSpan
        var EI = E * c.rootChord * t * t * t / 12
        if c.sparEnabled {
            let sp = c.sparSpec
            let d = t / 2 - sp.heightMM / 2
            EI += Self.carbonE * 2 * (sp.widthMM * sp.heightMM) * d * d
        }
        let F = 3 * totalMass * 9.81e-3 / 2
        wingTipDeflection = F * L * L * L / (8 * EI)
        wingDeflectionRatio = wingTipDeflection / L

        guard !c.kind.isTailless else { return }
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
        let chordArm = H / 2 - 1.5
        var EIv = E * tw * H * H * H / 12 + Self.carbonE * 4 * 1.5 * chordArm * chordArm
        // Torsion: open thin-walled section Σ b·t³/3 (laminated layers act as one thick web).
        var GJ = G * ((hu + hl) * tw * tw * tw / 3 + wp * t * t * t / 3)
        bendingStiffness = EIv
        torsionStiffness = GJ
        tailBendDeg = Fh * boom * boom / (2 * EIv) * 180 / .pi
        let zv = hBoom + c.vStabHeight / 2
        tailTwistDeg = Fv * zv * boom / GJ * 180 / .pi
    }
}
