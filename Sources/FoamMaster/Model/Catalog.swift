import Foundation

// MARK: - Foam

enum FoamFamily: String, Codable { case depron = "Depron", epp = "EPP" }

enum FoamMaterial: String, CaseIterable, Identifiable, Codable {
    case depron3, depron5, depron6, depron10, epp3, epp5, epp6, epp10
    var id: String { rawValue }

    var family: FoamFamily { rawValue.hasPrefix("depron") ? .depron : .epp }

    /// Sheet thickness in mm.
    var thickness: Double {
        switch self {
        case .depron3, .epp3: return 3
        case .depron5, .epp5: return 5
        case .depron6, .epp6: return 6
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
    case m0802, m1103, m1104, m1306, m1806, m2204
    var id: String { rawValue }

    var name: String {
        switch self {
        case .m0802: return "0802 brushless (micro)"
        case .m1103: return "1103 brushless"
        case .m1104: return "1104 brushless"
        case .m1306: return "1306 brushless"
        case .m1806: return "1806 brushless"
        case .m2204: return "2204 brushless"
        }
    }
    /// grams
    var mass: Double { [.m0802: 3.0, .m1103: 4.5, .m1104: 6.5, .m1306: 11, .m1806: 19, .m2204: 25][self]! }
    var escMass: Double { [.m0802: 1.5, .m1103: 2.0, .m1104: 3.0, .m1306: 5, .m1806: 7, .m2204: 9][self]! }
    var allowedCells: ClosedRange<Int> { [.m0802: 1...1, .m1103: 1...2, .m1104: 1...2, .m1306: 2...3, .m1806: 2...3, .m2204: 2...3][self]! }
    /// Static thrust in g for a given cell count (manufacturer typical values).
    func thrust(cells: Int) -> Double {
        guard allowedCells.contains(cells) else { return 0 }
        switch self {
        case .m0802: return 45
        case .m1103: return cells == 1 ? 70 : 130
        case .m1104: return cells == 1 ? 90 : 170
        case .m1306: return cells == 2 ? 260 : 360
        case .m1806: return cells == 2 ? 380 : 520
        case .m2204: return cells == 2 ? 450 : 620
        }
    }
    /// Recommended propeller (diameter × pitch in inches) – pitch drops with cell count to keep the current in range.
    func propRecommendation(cells: Int, pusher: Bool, blades: Int = 2, pair: Bool = false, diameter: Double? = nil) -> String {
        let propInches = diameter ?? self.propInches
        // A 3-blade absorbs more power at the same diameter – drop the pitch a little to keep the current in range.
        let ratio = (cells <= 1 ? 0.6 : (cells == 2 ? 0.55 : 0.45)) - (blades >= 3 ? 0.05 : 0)
        let pitch = (propInches * ratio * 2).rounded() / 2
        let fmt = { (x: Double) in x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.1f", x) }
        if pair { return "\(fmt(propInches)) × \(fmt(pitch))\" \(blades)-blade, counter-rotating pair (1 × CW, 1 × CCW)" }
        return "\(fmt(propInches)) × \(fmt(pitch))\" \(blades)-blade \(pusher ? "pusher (reverse rotation)" : "tractor")"
    }
    /// Typical maximum current per motor at full throttle (A).
    var maxCurrent: Double { [.m0802: 3, .m1103: 5, .m1104: 6, .m1306: 10, .m1806: 14, .m2204: 18][self]! }
    var propInches: Double { [.m0802: 2.5, .m1103: 3, .m1104: 4, .m1306: 5, .m1806: 6, .m2204: 6][self]! }
    /// Mounting pattern of the motor base (typical values of common motors of each size):
    /// 0802 3 × M1.4 on Ø6.6 · 1103 4 × M1.6 on Ø8.5 · 1104 4 × M2 9 × 9 · 1306 4 × M2 12 × 12 ·
    /// 1806 4 × M2 12 × 16 · 2204 4 × M3 16 × 19 (cross patterns give the distances between opposite holes).
    var pattern: MountPattern {
        switch self {
        case .m0802: return MountPattern(holes: 3, a: 6.6, b: 6.6, thread: 1.4)
        case .m1103: return MountPattern(holes: 4, a: 8.5, b: 8.5, thread: 1.6)
        case .m1104: return MountPattern(holes: 4, a: 9, b: 9, thread: 2)
        case .m1306: return MountPattern(holes: 4, a: 12, b: 12, thread: 2)
        case .m1806: return MountPattern(holes: 4, a: 12, b: 16, thread: 2)
        case .m2204: return MountPattern(holes: 4, a: 16, b: 19, thread: 3)
        }
    }
    /// Largest hole-to-hole distance of the pattern (sizes the firewall plate).
    var boltCircle: Double { max(pattern.a, pattern.b) }
    var screwHole: Double { pattern.clearance }
    var screw: String { pattern.screw }
    /// Shaft / circlip clearance hole in the middle of the firewall.
    var shaftClearance: Double { min(max(2.5, boltCircle * 0.28), min(pattern.a, pattern.b) / 2 - (pattern.headDiameter + 0.4) / 2 - 0.5) }
    var bellDiameter: Double { [.m0802: 10, .m1103: 14, .m1104: 14, .m1306: 18, .m1806: 23, .m2204: 28][self]! }
}

enum BatteryPack: String, CaseIterable, Identifiable, Codable {
    case s1_300, s1_450, s2_300, s2_450, s2_650, s3_450, s3_850
    var id: String { rawValue }
    var cells: Int { Int(String(rawValue.dropFirst().prefix(1)))! }
    var capacity: Double { Double(rawValue.split(separator: "_")[1])! }
    var name: String { "\(cells)S \(Int(capacity)) mAh LiPo" }
    var mass: Double { [.s1_300: 8.5, .s1_450: 12, .s2_300: 18, .s2_450: 27, .s2_650: 38, .s3_450: 39, .s3_850: 70][self]! }
    var voltage: Double { Double(cells) * 3.7 }
    /// L x W x H (mm)
    var size: (l: Double, w: Double, h: Double) {
        [.s1_300: (45, 17, 7), .s1_450: (52, 20, 8), .s2_300: (50, 17, 13), .s2_450: (57, 20, 14),
         .s2_650: (60, 30, 13), .s3_450: (57, 20, 20), .s3_850: (65, 30, 20)][self]!
    }
}

enum ServoClass: String, CaseIterable, Identifiable, Codable {
    case g17, g25, g37, g5
    var id: String { rawValue }
    var name: String { [.g17: "1.7 g micro servo", .g25: "2.5 g micro servo", .g37: "3.7 g micro servo", .g5: "5 g micro servo"][self]! }
    var mass: Double { [.g17: 1.7, .g25: 2.5, .g37: 3.7, .g5: 5][self]! }
    /// Body size without flanges: length, width, height (mm).
    var size: (l: Double, w: Double, h: Double) { [.g17: (16, 7, 15), .g25: (18, 8, 17), .g37: (20, 8.5, 18), .g5: (22, 9, 20)][self]! }
    var torque: Double { [.g17: 0.12, .g25: 0.25, .g37: 0.4, .g5: 0.6][self]! } // kg·cm
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
