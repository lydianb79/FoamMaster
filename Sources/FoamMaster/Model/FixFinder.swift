import Foundation

/// A concrete change that makes an infeasible design work (or at least removes errors).
struct FixSuggestion: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var config: AircraftConfig
    var solvesAll: Bool
    var cost: Double
}

/// Searches the parameter space around a design for the smallest changes that clear its errors.
enum FixFinder {
    struct Param {
        var label: String
        var unit: String
        var key: WritableKeyPath<AircraftConfig, Double>
        var applies: (AircraftConfig) -> Bool = { _ in true }
    }

    static let params: [Param] = [
        Param(label: "Wingspan", unit: "mm", key: \.wingspan),
        Param(label: "Root chord", unit: "mm", key: \.rootChord),
        Param(label: "Tip chord", unit: "mm", key: \.tipChord, applies: { !$0.kind.isNutBall }),
        Param(label: "Sweep", unit: "mm", key: \.sweep, applies: { !$0.kind.isNutBall }),
        Param(label: "Control surface chord", unit: "%", key: \.controlChordPct, applies: { $0.kind.isTailless || $0.hasAilerons || $0.kind.isNutBall }),
        Param(label: "Winglet / fin height", unit: "mm", key: \.wingletHeight, applies: { $0.kind.isTailless || $0.tailWinglets }),
        Param(label: "Centre fin height", unit: "mm", key: \.centreFinHeight, applies: { $0.kind.isTailless && $0.taillessFins == .finAndWinglets }),
        Param(label: "Fin position", unit: "mm", key: \.finPosition, applies: { $0.hasCentreFin }),
        Param(label: "Nose length", unit: "mm", key: \.noseLength, applies: { !$0.kind.isTailless }),
        Param(label: "Fuselage height", unit: "mm", key: \.fuselageHeight, applies: { !$0.kind.isTailless }),
        Param(label: "Tail arm", unit: "mm", key: \.tailArm, applies: { $0.kind.hasTail }),
        Param(label: "Stab span", unit: "mm", key: \.hStabSpan, applies: { $0.kind.hasTail }),
        Param(label: "Stab chord", unit: "mm", key: \.hStabChord, applies: { $0.kind.hasTail }),
        Param(label: "Fin height", unit: "mm", key: \.vStabHeight, applies: { !$0.kind.isTailless }),
        Param(label: "Fin chord", unit: "mm", key: \.vStabChord, applies: { !$0.kind.isTailless }),
    ]

    /// Moves the battery to the balance point (clamped to where it fits) and evaluates.
    static func evaluate(_ input: AircraftConfig) -> (config: AircraftConfig, analysis: Analysis) {
        var c = input
        let first = Analysis(design: DesignBuilder.build(c))
        c.batteryPosition = Analysis.fittingPosition(first.bestBatteryPosition, c)
        return (c, Analysis(design: DesignBuilder.build(c)))
    }

    static func errors(_ a: Analysis) -> Set<String> {
        Set(a.checks.filter { $0.severity == .error }.map(\.title))
    }

    /// Single changes first; if none fixes everything, chains the best partial fix with a second change.
    static func suggestions(for config: AircraftConfig, limit: Int = 6) -> [FixSuggestion] {
        var list = singleSuggestions(for: config, limit: limit)
        if !list.contains(where: \.solvesAll) {
            var combos: [FixSuggestion] = []
            for first in list.prefix(3) {
                for second in singleSuggestions(for: first.config, limit: 3) where second.solvesAll {
                    combos.append(FixSuggestion(title: "\(first.title) + \(second.title.prefix(1).lowercased() + second.title.dropFirst())",
                                                detail: second.detail, config: second.config, solvesAll: true, cost: first.cost + second.cost))
                }
            }
            var seen = Set<String>()
            list = (combos.sorted { $0.cost < $1.cost }.filter { seen.insert($0.title).inserted }.prefix(3) + list).prefix(limit).map { $0 }
        }
        return list
    }

    static func singleSuggestions(for config: AircraftConfig, limit: Int = 6) -> [FixSuggestion] {
        let base = evaluate(config)
        let baseErrors = errors(base.analysis)
        guard !baseErrors.isEmpty else { return [] }
        var found: [FixSuggestion] = []

        func consider(_ c: AircraftConfig, title: String, cost: Double) {
            let r = evaluate(c)
            let errs = errors(r.analysis)
            guard errs.count < baseErrors.count, errs.isSubset(of: baseErrors) else { return }
            let fixed = baseErrors.subtracting(errs).sorted().joined(separator: ", ")
            found.append(FixSuggestion(title: title, detail: errs.isEmpty ? "Makes the design feasible (score \(r.analysis.score))." : "Fixes: \(fixed)",
                                       config: r.config, solvesAll: errs.isEmpty, cost: cost))
        }

        // Continuous parameters: walk outwards in 4 % steps of the slider range, both directions.
        for p in params where p.applies(config) {
            let range = AircraftConfig.range(p.key, kind: config.kind)
            let step = (range.upperBound - range.lowerBound) * 0.04
            let v0 = config[keyPath: p.key]
            for dir in [-1.0, 1.0] {
                var best: (AircraftConfig, Double, Bool)?
                for k in 1...25 {
                    let v = v0 + dir * step * Double(k)
                    guard range.contains(v) else { break }
                    var c = config
                    c[keyPath: p.key] = v
                    if p.key == \AircraftConfig.rootChord { c.tipChord = min(c.tipChord, v) }
                    let r = evaluate(c)
                    let errs = errors(r.analysis)
                    if errs.isEmpty { best = (c, Double(k), true); break }
                    if best == nil, errs.count < baseErrors.count, errs.isSubset(of: baseErrors) { best = (c, Double(k), false) }
                }
                if let (c, k, _) = best {
                    let nv = c[keyPath: p.key]
                    let fmt = p.unit == "%" ? { (x: Double) in String(format: "%.0f", x * 100) } : { (x: Double) in String(format: p.unit == "°" ? "%.1f" : "%.0f", x) }
                    consider(c, title: "\(dir > 0 ? "Increase" : "Reduce") \(p.label.lowercased()): \(fmt(v0)) → \(fmt(nv)) \(p.unit)", cost: k)
                }
            }
        }

        // Discrete options.
        if !config.sparEnabled { var c = config; c.sparEnabled = true; consider(c, title: "Enable the carbon spar", cost: 1) }
        if config.kind.hasFuselage {
            for f in FuselageType.allCases where f != config.fuselageType {
                var c = config; c.fuselageType = f
                consider(c, title: "Fuselage structure: \(f.name)", cost: 1.5)
            }
        }
        for m in FoamMaterial.allCases where m != config.material {
            var c = config; c.material = m
            consider(c, title: "Material: \(m.displayName)", cost: 2)
        }
        for b in BatteryPack.allCases where b != config.battery && config.motor.allowedCells.contains(b.cells) {
            var c = config; c.battery = b
            consider(c, title: "Battery: \(b.name)", cost: 2)
        }
        for m in MotorClass.allCases where m != config.motor {
            var c = config; c.motor = m
            if !m.allowedCells.contains(c.battery.cells) {
                guard let b = BatteryPack.allCases.filter({ m.allowedCells.contains($0.cells) }).min(by: { abs($0.mass - config.battery.mass) < abs($1.mass - config.battery.mass) }) else { continue }
                c.battery = b
            }
            consider(c, title: "Motor: \(m.name)\(c.battery != config.battery ? " + \(c.battery.name)" : "")", cost: 2.5)
        }
        for s in ServoClass.allCases where s != config.servo {
            var c = config; c.servo = s
            consider(c, title: "Servos: \(s.name)", cost: 2)
        }

        // Full fixes first, then cheapest; one suggestion per title.
        var seen = Set<String>()
        return found.sorted { ($0.solvesAll ? 0 : 1, $0.cost) < ($1.solvesAll ? 0 : 1, $1.cost) }
            .filter { seen.insert($0.title).inserted }
            .prefix(limit).map { $0 }
    }

    /// Lightest fuselage structure without structural warnings (falls back to the stiffest).
    static func recommendedStructure(for config: AircraftConfig) -> FuselageType {
        guard config.kind.hasFuselage else { return config.fuselageType }
        for f in FuselageType.allCases {
            var c = config; c.fuselageType = f
            let a = evaluate(c).analysis
            if !a.checks.contains(where: { $0.category == "Structure" && $0.severity >= .warning && $0.title.contains("uselage") || ($0.category == "Structure" && $0.severity >= .warning && $0.title.contains("boom")) }) { return f }
        }
        return .cross
    }
}
