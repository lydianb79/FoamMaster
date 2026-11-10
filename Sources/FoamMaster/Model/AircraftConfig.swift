import Foundation

let maxWingspan: Double = 600

enum AircraftKind: String, CaseIterable, Identifiable, Codable {
    case flyingWing, delta, twinBoom, trainer, aerobat, glider
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flyingWing: return "Flying Wing"
        case .delta: return "Delta Jet"
        case .twinBoom: return "Twin Boom Pusher"
        case .trainer: return "Park Trainer"
        case .aerobat: return "3D Profile"
        case .glider: return "Micro Glider"
        }
    }

    var subtitle: String {
        switch self {
        case .flyingWing: return "Swept wing · elevons · pusher"
        case .delta: return "High sweep · centre fin · pusher"
        case .twinBoom: return "Pod, carbon booms, twin fins · FPV cruiser"
        case .trainer: return "Dihedral · rudder & elevator"
        case .aerobat: return "Huge surfaces · 4 channels"
        case .glider: return "High aspect ratio · thermal"
        }
    }

    var symbol: String {
        switch self {
        case .flyingWing: return "chevron.up"
        case .delta: return "triangle"
        case .twinBoom: return "camera.fill"
        case .trainer: return "graduationcap"
        case .aerobat: return "arrow.triangle.2.circlepath"
        case .glider: return "wind"
        }
    }

    var isTailless: Bool { self == .flyingWing || self == .delta }
    var hasAilerons: Bool { self == .aerobat }
    var isPusher: Bool { isTailless || self == .twinBoom }
    var isTwinBoom: Bool { self == .twinBoom }
    /// Tailed aircraft with a full-length fuselage (fuselage structure option applies).
    var hasFuselage: Bool { !isTailless && !isTwinBoom }

    /// Minimum sensible thrust/weight ratio for the category.
    var minThrustToWeight: Double {
        switch self {
        case .glider: return 0.35
        case .trainer: return 0.55
        case .twinBoom: return 0.7
        case .flyingWing: return 0.6
        case .delta: return 0.8
        case .aerobat: return 1.1
        }
    }

    var defaults: AircraftConfig {
        var c = AircraftConfig(kind: self)
        switch self {
        case .flyingWing:
            c.wingspan = 560; c.rootChord = 200; c.tipChord = 110; c.sweep = 120; c.dihedral = 0
            c.controlChordPct = 0.22; c.wingletHeight = 60
            c.material = .depron6; c.motor = .m1104; c.battery = .s2_450; c.servo = .g37
        case .delta:
            c.wingspan = 460; c.rootChord = 330; c.tipChord = 70; c.sweep = 250; c.dihedral = 0
            c.controlChordPct = 0.2; c.wingletHeight = 90; c.sweep = 230
            c.material = .depron6; c.motor = .m1306; c.battery = .s2_450; c.servo = .g37
        case .twinBoom:
            c.wingspan = 580; c.rootChord = 150; c.tipChord = 120; c.sweep = 8; c.dihedral = 0
            c.fuselageLength = 300; c.fuselageHeight = 58; c.noseLength = 120; c.tailArm = 300
            c.hStabSpan = 230; c.hStabChord = 70; c.vStabHeight = 70; c.vStabChord = 70
            c.material = .depron5; c.motor = .m1306; c.battery = .s2_450; c.servo = .g25; c.fpv = .o4Lite
        case .trainer:
            c.wingspan = 600; c.rootChord = 130; c.tipChord = 105; c.sweep = 12; c.dihedral = 6
            c.fuselageLength = 480; c.fuselageHeight = 62; c.noseLength = 95; c.tailArm = 270
            c.hStabSpan = 200; c.hStabChord = 70; c.vStabHeight = 80; c.vStabChord = 75
            c.material = .depron5; c.motor = .m1104; c.battery = .s2_300; c.servo = .g25
        case .aerobat:
            c.wingspan = 560; c.rootChord = 190; c.tipChord = 150; c.sweep = 20; c.dihedral = 0
            c.controlChordPct = 0.32
            c.fuselageLength = 560; c.fuselageHeight = 90; c.noseLength = 110; c.tailArm = 290
            c.hStabSpan = 250; c.hStabChord = 110; c.vStabHeight = 120; c.vStabChord = 120
            c.material = .depron5; c.motor = .m1306; c.battery = .s2_450; c.servo = .g37
        case .glider:
            c.wingspan = 600; c.rootChord = 85; c.tipChord = 55; c.sweep = 15; c.dihedral = 8
            c.fuselageLength = 470; c.fuselageHeight = 56; c.noseLength = 62; c.tailArm = 280
            c.hStabSpan = 150; c.hStabChord = 50; c.vStabHeight = 65; c.vStabChord = 55
            c.material = .depron3; c.motor = .m1103; c.battery = .s1_300; c.servo = .g17
        }
        c.name = "My \(title)"
        c.batteryPosition = c.defaultBatteryPosition
        return c
    }
}

struct AircraftConfig: Codable, Equatable {
    var kind: AircraftKind
    var name: String = "Untitled"

    // Wing (mm / degrees)
    var wingspan: Double = 500
    var rootChord: Double = 150
    var tipChord: Double = 120
    var sweep: Double = 20          // leading edge offset of the tip
    var dihedral: Double = 0
    var controlChordPct: Double = 0.25
    var wingletHeight: Double = 60

    // Fuselage & tail (tailed aircraft only)
    var fuselageLength: Double = 480
    var fuselageHeight: Double = 65
    var noseLength: Double = 90      // distance motor face → wing leading edge
    var tailArm: Double = 260        // wing LE → stabiliser LE
    var hStabSpan: Double = 200
    var hStabChord: Double = 75
    var vStabHeight: Double = 80
    var vStabChord: Double = 80

    // Build
    var material: FoamMaterial = .depron6
    var sparEnabled: Bool = true
    var motor: MotorClass = .m1104
    var battery: BatteryPack = .s2_300
    var servo: ServoClass = .g25
    /// Battery centre position measured aft of the root leading edge (mm, negative = forward).
    var batteryPosition: Double = 0
    var fpv: FPVSystem = .none
    var fuselageType: FuselageType = .cross
    /// 1 = one central servo driving both ailerons via torque rods, 2 = one servo per aileron.
    var aileronServos: Int = 2

    init(kind: AircraftKind) { self.kind = kind }

    var semiSpan: Double { wingspan / 2 }
    var taper: Double { tipChord / max(rootChord, 1) }

    var defaultBatteryPosition: Double {
        kind.isTailless ? battery.size.l / 2 : -noseLength * 0.45
    }

    /// Ranges used both by the UI sliders and the randomiser.
    static func range(_ key: PartialKeyPath<AircraftConfig>, kind: AircraftKind) -> ClosedRange<Double> {
        switch key {
        case \AircraftConfig.wingspan: return 250...maxWingspan
        case \AircraftConfig.rootChord: return kind == .delta ? 180...420 : 60...260
        case \AircraftConfig.tipChord: return kind == .delta ? 30...140 : 35...240
        case \AircraftConfig.sweep: return kind.isTailless ? 0...320 : -20...80
        case \AircraftConfig.dihedral: return 0...12
        case \AircraftConfig.controlChordPct: return 0.12...0.4
        case \AircraftConfig.wingletHeight: return 0...140
        case \AircraftConfig.fuselageLength: return 280...600
        case \AircraftConfig.fuselageHeight: return 36...130
        case \AircraftConfig.noseLength: return kind.isTailless ? 30...200 : 45...200
        case \AircraftConfig.tailArm: return 140...380
        case \AircraftConfig.hStabSpan: return 90...320
        case \AircraftConfig.hStabChord: return 35...140
        case \AircraftConfig.vStabHeight: return 40...160
        case \AircraftConfig.vStabChord: return 35...150
        case \AircraftConfig.batteryPosition: return -200...200
        default: return 0...1
        }
    }

    /// Produces a random (but plausible) variation of the given kind.
    static func random(kind: AircraftKind) -> AircraftConfig {
        var c = kind.defaults
        func r(_ kp: WritableKeyPath<AircraftConfig, Double>, spread: Double) {
            let range = AircraftConfig.range(kp, kind: kind)
            let v = c[keyPath: kp] * (1 + Double.random(in: -spread...spread))
            c[keyPath: kp] = min(max(v, range.lowerBound), range.upperBound)
        }
        r(\.wingspan, spread: 0.2); r(\.rootChord, spread: 0.2); r(\.tipChord, spread: 0.25)
        r(\.sweep, spread: 0.3); r(\.controlChordPct, spread: 0.15)
        if !kind.isTailless {
            r(\.dihedral, spread: 0.5)
            r(\.fuselageHeight, spread: 0.15); r(\.noseLength, spread: 0.15); r(\.tailArm, spread: 0.15)
            r(\.hStabSpan, spread: 0.15); r(\.hStabChord, spread: 0.15)
            r(\.vStabHeight, spread: 0.15); r(\.vStabChord, spread: 0.15)
        } else {
            r(\.wingletHeight, spread: 0.3); r(\.noseLength, spread: 0.3)
        }
        c.tipChord = min(c.tipChord, c.rootChord)
        let foams: [FoamMaterial] = [.depron3, .depron5, .depron6, .epp5, .epp6, .depron10, .epp10]
        c.material = foams.filter { $0.thickness <= (kind == .glider ? 5 : 10) }.randomElement()!
        c.sparEnabled = Bool.random() || c.material.family == .epp
        c.motor = MotorClass.allCases.filter { $0 != .m2204 }.randomElement()!
        c.battery = BatteryPack.allCases.filter { c.motor.allowedCells.contains($0.cells) }.randomElement()!
        c.servo = ServoClass.allCases.randomElement()!
        c.name = ["Foamhawk", "Swift", "Cumulus", "Hornet", "Dart", "Pixie", "Zephyr", "Kestrel", "Bolt", "Nimbus"].randomElement()! + " " + String(Int.random(in: 10...99))
        return c
    }
}
