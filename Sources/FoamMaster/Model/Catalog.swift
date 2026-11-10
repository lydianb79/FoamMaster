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
    func propRecommendation(cells: Int, pusher: Bool, blades: Int = 2, pair: Bool = false) -> String {
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
    /// Motor bolt circle diameter (mm) and screw clearance diameter.
    var boltCircle: Double { [.m0802: 6.6, .m1103: 8.5, .m1104: 9, .m1306: 12, .m1806: 16, .m2204: 16][self]! }
    var screwHole: Double { [.m0802: 1.3, .m1103: 1.6, .m1104: 1.8, .m1306: 2.2, .m1806: 2.2, .m2204: 3.2][self]! }
    var screw: String { [.m0802: "M1.2", .m1103: "M1.4", .m1104: "M1.6", .m1306: "M2", .m1806: "M2", .m2204: "M3"][self]! }
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

    static let flat3x05 = CarbonSpar(name: "Carbon flat strip 3 × 0.5 mm", widthMM: 3, heightMM: 0.5, gramsPerMeter: 2.3)
    static let flat5x05 = CarbonSpar(name: "Carbon flat strip 5 × 0.5 mm", widthMM: 5, heightMM: 0.5, gramsPerMeter: 3.8)
    static let flat6x1 = CarbonSpar(name: "Carbon flat strip 6 × 1 mm", widthMM: 6, heightMM: 1, gramsPerMeter: 9.0)
    static let rod1 = CarbonSpar(name: "Carbon rod Ø1 mm", widthMM: 1, heightMM: 1, gramsPerMeter: 1.3)
    static let rod2 = CarbonSpar(name: "Carbon rod Ø2 mm", widthMM: 2, heightMM: 2, gramsPerMeter: 5.0)
}

// MARK: - All-in-one flight controller

/// Whoop/micro style AIO board: flight controller + receiver + 4-in-1 ESC on a 26 × 26 mm hole pattern.
enum AIOController {
    static let name = "AIO flight controller (FC + ELRS receiver + 4-in-1 ESC)"
    static let holeSpacing = 26.0
    static let boardSize = 32.0
    static let mass = 5.5
    static let amps = 12.0            // per motor, continuous
    static let cells: ClosedRange<Int> = 1...4
}

// MARK: - FPV

enum FPVSystem: String, CaseIterable, Identifiable, Codable {
    case none, analog, o4Lite, walksnail
    var id: String { rawValue }

    var name: String {
        switch self {
        case .none: return "No FPV"
        case .analog: return "Analog"
        case .o4Lite: return "DJI O4 Lite"
        case .walksnail: return "Walksnail"
        }
    }
    var detail: String {
        switch self {
        case .none: return "Line of sight"
        case .analog: return "Nano camera + 25–200 mW VTX"
        case .o4Lite: return "O4 Air Unit Lite, digital HD"
        case .walksnail: return "Avatar HD Mini 1S Lite kit"
        }
    }
    /// Approximate flying weights (g): camera, transmitter incl. antenna.
    var cameraMass: Double { [.none: 0, .analog: 2.5, .o4Lite: 3.5, .walksnail: 3.2][self]! }
    var vtxMass: Double { [.none: 0, .analog: 3.5, .o4Lite: 5.5, .walksnail: 5.0][self]! }
    var mass: Double { cameraMass + vtxMass }
    /// Average power draw (W) while flying.
    var power: Double { [.none: 0, .analog: 2.5, .o4Lite: 5.5, .walksnail: 4.5][self]! }
    /// Camera body width (mm) – all three use 14 mm class micro cameras here.
    var cameraWidth: Double { [.none: 0, .analog: 14, .o4Lite: 14, .walksnail: 14][self]! }
    /// Printed-mount fitting notes per system (camera bodies are 14 mm "nano" class for all three).
    var mountNote: String {
        switch self {
        case .none: return ""
        case .analog: return "nano 14 mm camera, M2 side screws"
        case .o4Lite: return "O4 Lite camera 14 mm, M2 side screws – check against your unit"
        case .walksnail: return "Avatar Mini 1S Lite camera 14 mm, M2 side screws – check against your unit"
        }
    }
    var vtxSize: (l: Double, w: Double, h: Double) { [.none: (0, 0, 0), .analog: (20, 14, 5), .o4Lite: (28, 20, 7), .walksnail: (25, 20, 7)][self]! }
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
