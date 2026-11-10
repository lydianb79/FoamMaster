import Foundation

let maxWingspan: Double = 600

/// Propulsion layout.
enum MotorLayout: String, CaseIterable, Identifiable, Codable {
    case single, dualTractor
    var id: String { rawValue }
    var name: String { self == .single ? "Single motor" : "Dual tractor" }
    var detail: String { self == .single ? "Standard position for this type" : "Two counter-rotating motors on the wing leading edge" }
}

/// Vertical stabilisation of tailless aircraft.
enum TaillessFins: String, CaseIterable, Identifiable, Codable {
    case winglets, centreFin, none
    var id: String { rawValue }
    var name: String { [.winglets: "Winglets", .centreFin: "Centre fin", .none: "No fins"][self]! }
    var detail: String {
        [.winglets: "Two fins at the wing tips", .centreFin: "One fin on the centre line – position adjustable",
         .none: "Plain tips – relies on sweep for yaw stability"][self]!
    }
}

enum AircraftKind: String, CaseIterable, Identifiable, Codable {
    case flyingWing, delta, twinBoom, jet, trainer, aerobat, glider
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flyingWing: return "Flying Wing"
        case .delta: return "Delta Jet"
        case .twinBoom: return "Twin Boom"
        case .jet: return "Sport Jet"
        case .trainer: return "Park Trainer"
        case .aerobat: return "3D Plane"
        case .glider: return "Micro Glider"
        }
    }

    var subtitle: String {
        switch self {
        case .flyingWing: return "Swept wing · elevons · pusher"
        case .delta: return "High sweep · centre fin · pusher"
        case .twinBoom: return "Pod, carbon booms, twin fins"
        case .jet: return "Swept wing · prop-slot pusher"
        case .trainer: return "Big flat wing · forgiving · ailerons"
        case .aerobat: return "Huge surfaces · 4 channels"
        case .glider: return "High aspect ratio · thermal"
        }
    }

    var symbol: String {
        switch self {
        case .flyingWing: return "chevron.up"
        case .delta: return "triangle"
        case .twinBoom: return "camera.fill"
        case .jet: return "airplane"
        case .trainer: return "graduationcap"
        case .aerobat: return "arrow.triangle.2.circlepath"
        case .glider: return "wind"
        }
    }

    var isTailless: Bool { self == .flyingWing || self == .delta }
    /// Default control layout for the type.
    /// Flat (no dihedral) wings need ailerons for roll control.
    var defaultAilerons: Bool { !isTailless }
    var defaultRudder: Bool { !isTailless }
    var isPusher: Bool { isTailless || self == .twinBoom || self == .jet }
    var isJet: Bool { self == .jet }
    /// The jet's single prop spins in a slot in the middle – no twin motor option there.
    var allowsDualMotors: Bool { !isJet }
    /// Recommended number of prop blades: 2 for efficiency where the diameter is free; 3 where the diameter
    /// is limited (prop slot / trailing-edge cutout) or for strong, smooth thrust in 3D flying.
    var propBlades: Int {
        switch self {
        case .trainer, .glider, .twinBoom: return 2
        case .aerobat, .jet, .flyingWing, .delta: return 3
        }
    }
    var propBladeReason: String {
        switch self {
        case .trainer, .glider, .twinBoom: return "2-blade – most efficient, longest flight time"
        case .aerobat: return "3-blade – more thrust and smoother response for 3D"
        case .jet: return "3-blade – diameter is limited by the prop slot"
        case .flyingWing, .delta: return "3-blade – diameter is limited by the trailing-edge cutout"
        }
    }

    /// FPV camera up-tilt: faster types fly flatter and need more tilt to look at the horizon.
    var cameraTilt: Double {
        switch self {
        case .trainer, .glider: return 10
        case .aerobat, .twinBoom: return 15
        case .flyingWing: return 20
        case .delta, .jet: return 25
        }
    }
    var isTwinBoom: Bool { self == .twinBoom }
    /// Tailed aircraft with a full-length fuselage (fuselage structure option applies).
    var hasFuselage: Bool { !isTailless && !isTwinBoom }

    /// Minimum sensible thrust/weight ratio for the category.
    var minThrustToWeight: Double {
        switch self {
        case .glider: return 0.35
        case .trainer: return 0.55
        case .twinBoom: return 0.7
        case .jet: return 1.0
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
            c.controlChordPct = 0.2; c.wingletHeight = 90; c.sweep = 230; c.finPosition = 50
            c.material = .depron6; c.motor = .m1306; c.battery = .s2_450; c.servo = .g37
        case .twinBoom:
            c.wingspan = 580; c.rootChord = 150; c.tipChord = 120; c.sweep = 8; c.dihedral = 0
            c.fuselageLength = 300; c.fuselageHeight = 58; c.noseLength = 120; c.tailArm = 300
            c.hStabSpan = 230; c.hStabChord = 70; c.vStabHeight = 70; c.vStabChord = 70
            c.material = .depron5; c.motor = .m1306; c.battery = .s2_450; c.servo = .g25; c.fpv = .o4Lite
        case .jet:
            c.wingspan = 540; c.rootChord = 230; c.tipChord = 85; c.sweep = 175; c.dihedral = 0
            c.controlChordPct = 0.24
            c.fuselageLength = 560; c.fuselageHeight = 92; c.noseLength = 190; c.tailArm = 330
            c.hStabSpan = 250; c.hStabChord = 92; c.vStabHeight = 95; c.vStabChord = 105
            c.material = .depron5; c.motor = .m1306; c.battery = .s2_450; c.servo = .g37
        case .trainer:
            c.wingspan = 600; c.rootChord = 130; c.tipChord = 105; c.sweep = 12; c.dihedral = 0
            c.fuselageLength = 480; c.fuselageHeight = 84; c.noseLength = 95; c.tailArm = 270
            c.hStabSpan = 200; c.hStabChord = 70; c.vStabHeight = 80; c.vStabChord = 75
            c.material = .depron5; c.motor = .m1104; c.battery = .s2_300; c.servo = .g25
        case .aerobat:
            c.wingspan = 560; c.rootChord = 190; c.tipChord = 150; c.sweep = 20; c.dihedral = 0
            c.controlChordPct = 0.32
            c.fuselageLength = 560; c.fuselageHeight = 135; c.noseLength = 110; c.tailArm = 290
            c.hStabSpan = 250; c.hStabChord = 110; c.vStabHeight = 120; c.vStabChord = 120
            c.material = .depron5; c.motor = .m1306; c.battery = .s2_450; c.servo = .g37
        case .glider:
            c.wingspan = 600; c.rootChord = 95; c.tipChord = 60; c.sweep = 15; c.dihedral = 0
            c.fuselageLength = 470; c.fuselageHeight = 92; c.noseLength = 62; c.tailArm = 265
            c.hStabSpan = 150; c.hStabChord = 50; c.vStabHeight = 65; c.vStabChord = 55
            c.material = .depron5; c.motor = .m1103; c.battery = .s1_300; c.servo = .g17
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
    /// Control layout (tailed aircraft). Tailless aircraft always use two elevons.
    var ailerons: Bool = false
    var rudder: Bool = true
    var hasAilerons: Bool { !kind.isTailless && ailerons }
    /// Tailless only: winglets or a centre fin, and the centre fin's leading-edge position (mm aft of the root LE).
    var taillessFins: TaillessFins = .winglets
    var finPosition: Double = 40
    var motorLayout: MotorLayout = .single
    /// Winglets on tailed aircraft (tailless types choose winglets / centre fin via `taillessFins`).
    var tailWinglets: Bool = false
    var hasWinglets: Bool { kind.isTailless ? taillessFins == .winglets : tailWinglets }
    /// All-in-one flight controller (receiver + ESCs on one 26 × 26 mm board) instead of separate ESC(s) and receiver.
    var aio: Bool = false
    var isDual: Bool { motorLayout == .dualTractor && kind.allowsDualMotors }
    var motorCount: Int { isDual ? 2 : 1 }
    /// Effective pusher configuration (dual layouts are always tractors).
    var isPusher: Bool { kind.isPusher && !isDual }
    var hasRudder: Bool { !kind.isTailless && rudder }

    init(kind: AircraftKind) {
        self.kind = kind
        ailerons = kind.defaultAilerons
        rudder = kind.defaultRudder
        taillessFins = kind == .delta ? .centreFin : .winglets
        fuselageType = .cross
    }

    var semiSpan: Double { wingspan / 2 }
    var taper: Double { tipChord / max(rootChord, 1) }

    var defaultBatteryPosition: Double {
        kind.isTailless ? battery.size.l / 2 : -noseLength * 0.45
    }

    /// Ranges used both by the UI sliders and the randomiser.
    static func range(_ key: PartialKeyPath<AircraftConfig>, kind: AircraftKind) -> ClosedRange<Double> {
        switch key {
        case \AircraftConfig.wingspan: return 250...maxWingspan
        case \AircraftConfig.rootChord: return kind == .delta ? 180...420 : (kind.isJet ? 150...320 : 60...260)
        case \AircraftConfig.tipChord: return kind == .delta ? 30...140 : 35...240
        case \AircraftConfig.sweep: return kind.isTailless ? 0...320 : (kind.isJet ? 60...260 : -20...80)
        case \AircraftConfig.dihedral: return 0...12
        case \AircraftConfig.controlChordPct: return 0.12...0.4
        case \AircraftConfig.wingletHeight: return 0...140
        case \AircraftConfig.fuselageLength: return 280...600
        case \AircraftConfig.fuselageHeight: return 36...130
        case \AircraftConfig.noseLength: return kind.isTailless ? 30...200 : (kind.isJet ? 100...280 : 45...200)
        case \AircraftConfig.tailArm: return 140...380
        case \AircraftConfig.hStabSpan: return 90...320
        case \AircraftConfig.hStabChord: return 35...140
        case \AircraftConfig.vStabHeight: return 40...160
        case \AircraftConfig.vStabChord: return 35...150
        case \AircraftConfig.batteryPosition: return -200...200
        case \AircraftConfig.finPosition: return 0...280
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
