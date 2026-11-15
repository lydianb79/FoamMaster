import Foundation

extension AircraftKind {
    /// Thrust/weight aimed for when the power system is picked automatically (40 % above the minimum).
    var recommendedThrustToWeight: Double { minThrustToWeight * 1.4 }
}

/// Picks motor and battery (and with them ESC, prop size, pitch and blade count) for the best power-to-weight
/// ratio: the lightest feasible combination that reaches the recommended thrust/weight and at least 6 minutes of
/// flight; if none does, the one closest to it. Dual tractors keep at least the single-motor version's motor and battery.
enum PowerOptimizer {
    static let minFlightTime = 6.0

    struct Result {
        var config: AircraftConfig
        var analysis: Analysis
    }

    static func best(for input: AircraftConfig) -> Result? {
        let target = input.kind.recommendedThrustToWeight
        var best: (key: (Int, Int, Int, Double), result: Result)?
        // Dual tractor: the single-motor version's power system ×2 – motors at least that size and a battery with at
        // least its cells and capacity – instead of two tiny motors on a small pack that cancel out the second motor,
        // ESC and mounts. So switching to dual always adds that hardware's weight.
        var minMotorMass = 0.0, minCells = 0, minCapacity = 0.0
        if input.isDual {
            var single = input
            single.motorLayout = .single
            if let s = PowerOptimizer.best(for: single)?.config {
                minMotorMass = s.motor.mass; minCells = s.battery.cells; minCapacity = s.battery.capacity
            }
        }
        var combos: [(MotorClass, BatteryPack)] = []
        for motor in MotorClass.options(for: input) where motor.mass >= minMotorMass {
            for battery in BatteryPack.allCases where motor.allowedCells.contains(battery.cells)
                && battery.cells >= minCells && battery.capacity >= minCapacity { combos.append((motor, battery)) }
        }
        // Every combination is a full build (struts planned, battery balanced). The airframe is the same for all, so
        // weight, thrust and flight time are first estimated without a build (the input's mass with its power system
        // swapped); the builds then run in parallel batches, most promising first, and stop once no combination left
        // can beat the best one found even with a few grams' and per cent's slack. Ties: the first in the list.
        guard !combos.isEmpty else { return nil }
        let inputMass = Analysis(design: DesignBuilder.build(input)).totalMass
        func optimistic(_ i: Int) -> (Int, Int, Int, Double) {
            var c = input; c.motor = combos[i].0; c.battery = combos[i].1
            let mass = inputMass - Analysis.powerMass(input) + Analysis.powerMass(c)
            let tw = Analysis.staticThrust(c) / max(mass, 1), time = Analysis.flightTime(c, totalMass: mass)
            let meets = tw * 1.04 >= target && time * 1.04 >= minFlightTime
            let style = input.kind.prefersSlowFly && !c.motor.isSlowFly ? 1 : 0
            return (meets ? 0 : 1, style, -100, meets ? mass - 4 : -tw * 1.04)
        }
        let bound = combos.indices.map(optimistic)
        let order = combos.indices.sorted { bound[$0] != bound[$1] ? bound[$0] < bound[$1] : $0 < $1 }
        var results = [(key: (Int, Int, Int, Double), result: Result)?](repeating: nil, count: combos.count)
        let lock = NSLock()
        let batch = max(ProcessInfo.processInfo.activeProcessorCount, 4)
        var next = 0
        while next < order.count {
            if let b = best, b.key < bound[order[next]] { break }
            let ids = Array(order[next..<min(next + batch, order.count)])
            next += ids.count
            DispatchQueue.concurrentPerform(iterations: ids.count) { j in
                let i = ids[j]
                var c = input
                c.motor = combos[i].0
                c.battery = combos[i].1
                let (balanced, a) = FixFinder.evaluate(c)
                guard a.feasible else { return }
                let meets = a.thrustToWeight >= target && a.flightTime >= minFlightTime
                // Meeting the target first, then (3D Plane) the slow-fly motor with its big prop, then fewer warnings,
                // then the lightest (or, if nothing meets it, the one with the most thrust per weight).
                let style = input.kind.prefersSlowFly && !c.motor.isSlowFly ? 1 : 0
                let key = (meets ? 0 : 1, style, -a.score, meets ? a.totalMass : -a.thrustToWeight)
                lock.lock(); results[i] = (key, Result(config: balanced, analysis: a)); lock.unlock()
            }
            // (in list order, so equal keys keep the first combination)
            best = nil
            for r in results { if let r, best == nil || r.key < best!.key { best = r } }
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
