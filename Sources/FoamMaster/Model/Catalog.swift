import Foundation

// MARK: - Foam

enum FoamFamily: String, Codable { case depron = "Depron", epp = "EPP" }

enum FoamMaterial: String, CaseIterable, Identifiable, Codable {
    case depron3, depron5, depron6, depron8, depron10, epp3, epp5, epp6, epp8, epp10
    var id: String { rawValue }

    var family: FoamFamily { rawValue.hasPrefix("depron") ? .depron : .epp }

    /// Sheet thickness in mm.
    var thickness: Double {
        switch self {
        case .depron3, .epp3: return 3
        case .depron5, .epp5: return 5
        case .depron6, .epp6: return 6
        case .depron8, .epp8: return 8
        case .depron10, .epp10: return 10
        }
    }

    /// kg/m³
    var density: Double { family == .depron ? 33 : 30 }

    var displayName: String { "\(family.rawValue) \(Int(thickness)) mm" }

    /// Commercially common sheet size (mm).
    var sheetSize: (w: Double, h: Double) { family == .depron ? (1000, 700) : (1000, 600) }

    var glue: String { family == .depron ? "UHU Por / foam-safe contact glue" : "Hot glue + foam-safe CA (UHU Por for large joints)" }

    /// Relative bending stiffness factor (Depron is far stiffer than EPP).
    var stiffness: Double { family == .depron ? 1.0 : 0.35 }
}

// MARK: - Electronics

enum MotorClass: String, CaseIterable, Identifiable, Codable {
    case m0802, m1103, m1104, m1204, m1306, m1404, m1806, m2204
    /// Slow-fly 1806 (≈ 1500 KV): turns a big 8" 2-blade slowly on 2S – much thrust per watt and a wide, slow slipstream
    /// over the tail for hovering. Only on a single tractor whose prop the pilot can choose (Park Trainer, 3D Plane, Micro
    /// Glider, NutBall) – the 8" prop does not fit pushers, jets or dual tractors.
    case m1806s
    var id: String { rawValue }
    var isSlowFly: Bool { self == .m1806s }
    /// Whether the motor can be fitted to this design.
    func fits(_ c: AircraftConfig) -> Bool { !isSlowFly || (c.kind.allowsPropChoice && !c.isDual) }
    static func options(for c: AircraftConfig) -> [MotorClass] { allCases.filter { $0.fits(c) } }
    /// Pitch-to-diameter ratio of the motor's prop for the cell count (the slow-fly prop is a little flatter: 8 × 4").
    func pitchRatio(cells: Int) -> Double { isSlowFly ? 0.5 : (cells <= 1 ? 0.6 : (cells == 2 ? 0.55 : 0.45)) }

    var name: String {
        switch self {
        case .m0802: return "0802 brushless (micro)"
        case .m1103: return "1103 brushless"
        case .m1104: return "1104 brushless"
        case .m1204: return "1204 brushless"
        case .m1404: return "1404 brushless"
        case .m1306: return "1306 brushless"
        case .m1806: return "1806 brushless"
        case .m2204: return "2204 brushless"
        case .m1806s: return "1806 slow-fly brushless (≈ 1500 KV)"
        }
    }
    /// grams
    var mass: Double {
        switch self {
        case .m0802: return 3.0
        case .m1103: return 4.5
        case .m1104: return 6.5
        case .m1204: return 7.5
        case .m1306: return 11
        case .m1404: return 8.8
        case .m1806: return 19
        case .m2204: return 25
        case .m1806s: return 18
        }
    }
    var escMass: Double {
        switch self {
        case .m0802: return 1.5
        case .m1103: return 2.0
        case .m1104: return 3.0
        case .m1204: return 4
        case .m1306: return 5
        case .m1404: return 4
        case .m1806: return 7
        case .m2204: return 9
        case .m1806s: return 4
        }
    }
    var allowedCells: ClosedRange<Int> {
        switch self {
        case .m0802: return 1...1
        case .m1103: return 1...2
        case .m1104: return 1...2
        case .m1204: return 2...3
        case .m1306: return 2...3
        case .m1404: return 2...3
        case .m1806: return 2...3
        case .m2204: return 2...3
        case .m1806s: return 2...2
        }
    }
    /// Static thrust in g for a given cell count (manufacturer typical values).
    func thrust(cells: Int) -> Double {
        guard allowedCells.contains(cells) else { return 0 }
        switch self {
        case .m0802: return 45
        case .m1103: return cells == 1 ? 70 : 130
        case .m1104: return cells == 1 ? 90 : 170
        case .m1204: return cells == 2 ? 200 : 270
        case .m1404: return cells == 2 ? 230 : 320
        case .m1306: return cells == 2 ? 260 : 360
        case .m1806: return cells == 2 ? 380 : 520
        case .m2204: return cells == 2 ? 450 : 620
        case .m1806s: return 330
        }
    }
    /// Recommended propeller (diameter × pitch in inches) – pitch drops with cell count to keep the current in range.
    func propRecommendation(cells: Int, pusher: Bool, blades: Int = 2, pair: Bool = false, diameter: Double? = nil, pitch given: Double? = nil) -> String {
        let propInches = diameter ?? self.propInches
        // A 3-blade absorbs more power at the same diameter – drop the pitch a little to keep the current in range.
        let ratio = pitchRatio(cells: cells) - (blades >= 3 ? 0.05 : 0)
        let pitch = given ?? (propInches * ratio * 2).rounded() / 2
        let fmt = { (x: Double) in x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.1f", x) }
        if pair { return "\(fmt(propInches)) × \(fmt(pitch))\" \(blades)-blade, counter-rotating pair (1 × CW, 1 × CCW)" }
        return "\(fmt(propInches)) × \(fmt(pitch))\" \(blades)-blade \(pusher ? "pusher (reverse rotation)" : "tractor")"
    }
    /// Typical maximum current per motor at full throttle (A).
    var maxCurrent: Double {
        switch self {
        case .m0802: return 3
        case .m1103: return 5
        case .m1104: return 6
        case .m1204: return 8
        case .m1306: return 10
        case .m1404: return 10
        case .m1806: return 14
        case .m2204: return 18
        case .m1806s: return 7
        }
    }
    var propInches: Double {
        switch self {
        case .m0802: return 2.5
        case .m1103: return 3
        case .m1104: return 4
        case .m1204: return 4
        case .m1306: return 5
        case .m1404: return 4
        case .m1806: return 6
        case .m2204: return 6
        case .m1806s: return 8
        }
    }
    /// Mounting pattern of the motor base (typical values of common motors of each size):
    /// 0802 3 × M1.4 on Ø6.6 · 1103 4 × M1.6 on Ø8.5 · 1104 / 1204 / 1404 4 × M2 9 × 9 · 1306 4 × M2 12 × 12 ·
    /// 1806 4 × M2 12 × 16 · 2204 4 × M3 16 × 19 (cross patterns give the distances between opposite holes).
    var pattern: MountPattern {
        switch self {
        case .m0802: return MountPattern(holes: 3, a: 6.6, b: 6.6, thread: 1.4)
        case .m1103: return MountPattern(holes: 4, a: 8.5, b: 8.5, thread: 1.6)
        case .m1104, .m1204, .m1404: return MountPattern(holes: 4, a: 9, b: 9, thread: 2)
        case .m1306: return MountPattern(holes: 4, a: 12, b: 12, thread: 2)
        case .m1806, .m1806s: return MountPattern(holes: 4, a: 12, b: 16, thread: 2)
        case .m2204: return MountPattern(holes: 4, a: 16, b: 19, thread: 3)
        }
    }
    /// Largest hole-to-hole distance of the pattern (sizes the firewall plate).
    var boltCircle: Double { max(pattern.a, pattern.b) }
    var screwHole: Double { pattern.clearance }
    var screw: String { pattern.screw }
    /// Shaft / circlip clearance hole in the middle of the firewall.
    var shaftClearance: Double { min(max(2.5, boltCircle * 0.28), min(pattern.a, pattern.b) / 2 - (pattern.headDiameter + 0.4) / 2 - 0.5) }
    var bellDiameter: Double {
        switch self {
        case .m0802: return 10
        case .m1103: return 14
        case .m1104: return 14
        case .m1204: return 16
        case .m1306: return 18
        case .m1404: return 18
        case .m1806: return 23
        case .m2204: return 28
        case .m1806s: return 23
        }
    }
}

enum BatteryPack: String, CaseIterable, Identifiable, Codable {
    case s1_300, s1_450, s2_300, s2_450, s2_650, s3_450, s3_850
    var id: String { rawValue }
    var cells: Int { Int(String(rawValue.dropFirst().prefix(1)))! }
    var capacity: Double { Double(rawValue.split(separator: "_")[1])! }
    var name: String { "\(cells)S \(Int(capacity)) mAh LiPo" }
    var mass: Double {
        switch self {
        case .s1_300: return 8.5
        case .s1_450: return 12
        case .s2_300: return 18
        case .s2_450: return 27
        case .s2_650: return 38
        case .s3_450: return 39
        case .s3_850: return 70
        }
    }
    var voltage: Double { Double(cells) * 3.7 }
    /// L x W x H (mm)
    var size: (l: Double, w: Double, h: Double) {
        switch self {
        case .s1_300: return (45, 17, 7)
        case .s1_450: return (52, 20, 8)
        case .s2_300: return (50, 17, 13)
        case .s2_450: return (57, 20, 14)
        case .s2_650: return (60, 30, 13)
        case .s3_450: return (57, 20, 20)
        case .s3_850: return (65, 30, 20)
        }
    }
}

enum ServoClass: String, CaseIterable, Identifiable, Codable {
    case g17, g25, g37, g5
    var id: String { rawValue }
    var name: String {
        switch self {
        case .g17: return "1.7 g micro servo"
        case .g25: return "2.5 g micro servo"
        case .g37: return "3.7 g micro servo"
        case .g5: return "5 g micro servo"
        }
    }
    var mass: Double {
        switch self {
        case .g17: return 1.7
        case .g25: return 2.5
        case .g37: return 3.7
        case .g5: return 5
        }
    }
    /// Body size without flanges: length, width, height (mm).
    var size: (l: Double, w: Double, h: Double) {
        switch self {
        case .g17: return (16, 7, 15)
        case .g25: return (18, 8, 17)
        case .g37: return (20, 8.5, 18)
        case .g5: return (22, 9, 20)
        }
    }
    var torque: Double {
        switch self {
        case .g17: return 0.12
        case .g25: return 0.25
        case .g37: return 0.4
        case .g5: return 0.6
        }
    } // kg·cm
    /// Mounting ears (flanges) like on every real micro servo: one at each end of the length, as wide as the body,
    /// sticking out `earLength`, `earThickness` thick, their mid-plane `earOffset` from the body centre towards the
    /// output shaft (a quarter of the height below the shaft face).
    var earLength: Double { (size.l * 0.2 * 2).rounded() / 2 }
    static let earThickness = 1.5
    var earOffset: Double { size.h * 0.25 }
    /// Servo arm (horn) as fitted: shaft → pushrod hole, the arm 2 mm off the case on the spline, 1.6 mm thick,
    /// 4 mm wide; the pushrod's Z-bend goes through the hole from the arm's OUTER side. Typical micro-servo arms.
    var armLength: Double {
        switch self {
        case .g17: return 11.0
        case .g25: return 12
        case .g37: return 13
        case .g5: return 14
        }
    }
    /// Half length of a double-ended arm (hub → each pushrod hole).
    var doubleArmHalf: Double {
        switch self {
        case .g17: return 10.0
        case .g25: return 11
        case .g37: return 12
        case .g5: return 13
        }
    }
    static let armGap = 2.0, armThickness = 1.6, armWidth = 4.0
    /// The pushrod lies outside the arm: offset of the rod axis from the case face (gap + arm + rod radius).
    static var rodOffset: Double { armGap + armThickness + 0.5 }
    /// Half length (along the sheet) of the pocket an arm needs where its hub sits in a foam sheet of thickness
    /// `sheet`: the arm swinging ±50° crosses the sheet over this distance either side of the hub.
    static func armSwingAlong(sheet: Double) -> Double {
        let th = 50.0 * .pi / 180
        return max(armWidth / 2 / cos(th) + (sheet / 2 + 1) * tan(th) + 1, 3.5)
    }
}

/// Carbon reinforcement options the generator picks from.
struct CarbonSpar {
    var name: String
    var widthMM: Double
    var heightMM: Double
    var gramsPerMeter: Double
    /// Inner diameter of a tube (0 for solid rods and strips).
    var innerMM: Double = 0

    /// Bending stiffness of a round rod / tube about its own axis (N·mm²).
    var roundEI: Double { StructureReport.carbonE * .pi / 64 * (pow(widthMM, 4) - pow(innerMM, 4)) }
    var roundArea: Double { .pi / 4 * (widthMM * widthMM - innerMM * innerMM) }

    /// Wing spar options: solid carbon rods only (cheaper and easier to get than tubes), smallest first.
    /// Mass from 1.55 g/cm³ pultruded carbon.
    static let wingRods: [CarbonSpar] = [1.5, 2, 2.5, 3, 4, 5].map { d in
        CarbonSpar(name: "Carbon rod Ø\(d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)) mm",
                   widthMM: d, heightMM: d, gramsPerMeter: (.pi / 4 * d * d * 1.55 * 10).rounded() / 10)
    }

    static let flat3x05 = CarbonSpar(name: "Carbon flat strip 3 × 0.5 mm", widthMM: 3, heightMM: 0.5, gramsPerMeter: 2.3)
    static let flat5x05 = CarbonSpar(name: "Carbon flat strip 5 × 0.5 mm", widthMM: 5, heightMM: 0.5, gramsPerMeter: 3.8)
    static let flat6x1 = CarbonSpar(name: "Carbon flat strip 6 × 1 mm", widthMM: 6, heightMM: 1, gramsPerMeter: 9.0)
    static let rod1 = CarbonSpar(name: "Carbon rod Ø1 mm", widthMM: 1, heightMM: 1, gramsPerMeter: 1.3)
    static let rod2 = CarbonSpar(name: "Carbon rod Ø2 mm", widthMM: 2, heightMM: 2, gramsPerMeter: 5.0)
}

/// Motor base hole pattern. 3-hole patterns sit on a circle of diameter `a`; 4-hole patterns form a cross with
/// `a` and `b` as the distances between opposite holes (a = b: square pattern).
struct MountPattern: Equatable {
    var holes: Int
    var a: Double
    var b: Double
    var thread: Double
    var screw: String { thread == thread.rounded() ? "M\(Int(thread))" : "M\(String(format: "%.1f", thread))" }
    /// Clearance hole for the screw in the printed firewall.
    var clearance: Double { thread + (thread >= 3 ? 0.3 : 0.25) }
    /// Screw head (cap / pan head) diameter and height – the firewall is counterbored so the heads sit flush.
    var headDiameter: Double { thread * 1.75 + 0.2 }
    var headHeight: Double { thread * 0.7 + 0.1 }
    /// Hole centres relative to the motor axis (firewall plane). Holes sit on the clamp axes, i.e. in the foam
    /// channels where possible; holes under a clamp jaw get an access bore through the jaw.
    var positions: [Vec2] {
        if holes == 3 {
            return (0..<3).map { k in let t = Double(k) * 2 * .pi / 3; return Vec2(cos(t), sin(t)) * (a / 2) }
        }
        return [Vec2(a / 2, 0), Vec2(-a / 2, 0), Vec2(0, b / 2), Vec2(0, -b / 2)]
    }
    var label: String {
        holes == 3 ? "3 × \(screw) on Ø\(fmt(a)) mm" : (a == b ? "4 × \(screw), \(fmt(a)) × \(fmt(a)) mm" : "4 × \(screw), \(fmt(a)) × \(fmt(b)) mm")
    }
    private func fmt(_ x: Double) -> String { x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.1f", x) }
}

// MARK: - Fuselage structure

/// Fuselage construction. Only the RC Factory style cross is offered: horizontal plate + single-layer
/// upper/lower halves + carbon chords & diagonals (kept as an enum so saved configs stay readable).
enum FuselageType: String, CaseIterable, Identifiable, Codable {
    case cross
    var id: String { rawValue }
    var name: String { "Cross" }
    var detail: String { "Horizontal plate + upper & lower halves, keyed with tabs" }
    var symbol: String { "plus" }
    var webLayers: Int { 1 }
}

extension CarbonSpar {
    static let tube4 = CarbonSpar(name: "Carbon tube Ø4 × 3 mm", widthMM: 4, heightMM: 4, gramsPerMeter: 7.5)
}
