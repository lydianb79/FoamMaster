import Foundation

extension AircraftKind {
    /// Thrust/weight aimed for when the power system is picked automatically (40 % above the minimum).
    var recommendedThrustToWeight: Double { minThrustToWeight * 1.4 }
}

/// Picks motor and battery (and with them ESC, prop size, pitch and blade count) for the best power-to-weight
/// ratio: the lightest feasible combination that reaches the recommended thrust/weight and at least 6 minutes of
/// flight; if none does, the one closest to it.
enum PowerOptimizer {
    static let minFlightTime = 6.0

    struct Result {
        var config: AircraftConfig
        var analysis: Analysis
    }

    static func best(for input: AircraftConfig) -> Result? {
        let target = input.kind.recommendedThrustToWeight
        var best: (key: (Int, Int, Double), result: Result)?
        for motor in MotorClass.allCases {
            for battery in BatteryPack.allCases where motor.allowedCells.contains(battery.cells) {
                var c = input
                c.motor = motor
                c.battery = battery
                let (balanced, a) = FixFinder.evaluate(c)
                guard a.feasible else { continue }
                let meets = a.thrustToWeight >= target && a.flightTime >= minFlightTime
                // Meeting the target first, then fewer warnings, then the lightest (or, if nothing meets it, the
                // one with the most thrust per weight).
                let key = (meets ? 0 : 1, -a.score, meets ? a.totalMass : -a.thrustToWeight)
                if best == nil || key < best!.key { best = (key, Result(config: balanced, analysis: a)) }
            }
        }
        return best?.result
    }
}

extension AircraftKind {
    private static let recommendedAll: [AircraftKind: AircraftConfig] = Dictionary(uniqueKeysWithValues: AircraftKind.allCases.map { k in
        (k, PowerOptimizer.best(for: k.defaults)?.config ?? FixFinder.evaluate(k.defaults).config)
    })
    /// The variant shown in the gallery and used to start a new model: default airframe with the automatically
    /// chosen power system (motor, ESC, prop, battery) and the battery at the balance point.
    var recommended: AircraftConfig { Self.recommendedAll[self]! }
}
