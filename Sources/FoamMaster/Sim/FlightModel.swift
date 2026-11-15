import Foundation
import simd

/// Pilot inputs: sticks −1…1 (roll right, pitch back = nose up, yaw right positive), throttle 0…1.
struct StickInput: Equatable {
    var roll = 0.0, pitch = 0.0, yaw = 0.0, throttle = 0.0
}

/// Aerodynamic and mass properties of a design for the flight simulator, derived from its geometry and analysis.
/// Body frame = the model frame: x right, y up, z aft (forward is −z). Coefficients use the usual non-dimensional
/// definitions; moments are taken about the CG.
struct FlightModel {
    var mass: Double            // kg
    var inertia: SIMD3<Double>  // about x (pitch), y (yaw), z (roll), kg·m²
    var S: Double               // wing area m²
    var b: Double               // span m
    var cbar: Double            // MAC m
    var AR: Double
    var CLa: Double             // lift slope /rad
    var alphaStall: Double      // rad
    var CD0: Double
    var k: Double               // induced drag factor 1/(π e AR)
    var Cma: Double             // pitch stiffness (− = stable)
    var Cmq: Double, Cmde: Double, Cm0: Double
    var Clb: Double, Clp: Double, Clda: Double, Clr: Double
    var Cnb: Double, Cnr: Double, Cndr: Double, Cnda: Double
    var CYb: Double
    var staticThrust: Double    // N at full throttle
    var pitchSpeed: Double      // m/s where the thrust has fallen to 0
    /// Throws as flown at full stick (the radio's end points – a typical setup for the type, smaller than the most
    /// the hinges allow), rad: aileron / elevon roll, elevator / elevon pitch, rudder.
    var rollThrow: Double, pitchThrow: Double, yawThrow: Double
    /// Effectiveness of the aileron / elevon chord (flap theory, flat foam with a tape hinge).
    var ailTau: Double = 0
    /// Horizontal tail: volume, lift slope, share of the wing's angle it sees (1 − downwash gradient), arm (m),
    /// stall angle (rad) – the tail stalls on its own when the elevator and the pitch rate ask too much of it.
    var tailVH = 0.0, tailCLa = 0.0, tailAlphaShare = 0.5, tailArm = 0.2, tailStall = 15 * Double.pi / 180
    var hasAilerons: Bool, hasRudder: Bool, tailless: Bool
    var stallSpeed: Double      // m/s (from the analysis)
    /// Lowest point of the airframe below the CG (m) – touches the ground first.
    var groundClearance: Double
    /// Wing strips (right half; the left half mirrors it): span station y (m), area (m²), aileron / elevon on it.
    var stripY: [Double] = [], stripS: [Double] = []
    /// Share of each strip covered by the aileron / elevon, and lying in the prop's slipstream (tractors).
    var stripAileron: [Double] = [], stripWash: [Double] = []
    /// Aileron: change of strip lift coefficient per radian of aileron (calibrated to the roll power Clda).
    var aileronDCL: Double = 0
    /// Share of the elevator / rudder inside the prop's slipstream, total disc area (m²).
    var washElevator: Double = 0, washRudder: Double = 0, discArea: Double = 0.01
    /// The rudder's share in the slipstream above the thrust line less the share below it: the swirl turns the other
    /// way below the axis, so a rudder reaching down through the elevator catches little net swirl.
    var washSwirl: Double = 0
    /// Hanging on the prop, a sideways slide blows across everything in the slipstream: lift per radian × arm behind
    /// the CG (m³, negative ahead of it) of the vertical keel (fuselage halves, fin, rudder) and of the horizontal
    /// slab (plate, wing, stabiliser, elevator) inside it.
    var blownKeelMoment = 0.0, blownPlateMoment = 0.0
    /// Motor torque (N·m per N of thrust; + rolls left as seen from behind) and the prop's angular momentum per
    /// throttle (kg·m²/s along +z body; tractor props spin clockwise from behind → H points forward, −z).
    var torquePerThrust: Double = 0, propH: Double = 0
    /// A centre-line fin in the slipstream (its swirl yaws the model); share of the motor torque a wing behind the
    /// prop takes back by straightening the swirl.
    var swirlFin = false, swirlRecovery = 0.0

    init(_ d: Design, _ a: Analysis) {
        let c = d.config
        mass = max(a.totalMass, 10) / 1000
        S = max(a.wingArea, 1) * 1e-6
        b = c.wingspan / 1000
        cbar = max(a.mac, 10) / 1000
        AR = max(a.aspectRatio, 0.5)
        CLa = 2 * .pi * AR / (2 + (AR * AR + 4).squareRoot())
        // Flat foam stalls early on a slender wing, late on a delta / disc (vortex lift).
        alphaStall = (12 + 16 * max(0, min(1, (4 - AR) / 3))) * .pi / 180
        CD0 = 0.035 + (c.kind.hasFuselage ? 0.012 : 0.006)
        k = 1 / (.pi * 0.75 * AR)
        tailless = c.kind.isTailless || c.kind.isNutBall
        hasAilerons = c.hasAilerons || c.kind.isTailless
        hasRudder = c.hasRudder
        let th = Self.flightThrows(c.kind)
        rollThrow = th.roll * .pi / 180; pitchThrow = th.pitch * .pi / 180; yawThrow = th.yaw * .pi / 180
        // Pitch: static margin at the actual CG (− Cmα), control power and damping from the tail.
        let sm = min(max(a.staticMargin, -0.3), 0.4)
        Cma = -CLa * sm
        let tauE = (min(max(c.controlChordPct, 0.15), 0.5) / 0.5).squareRoot() * 0.65
        let lt = max(c.tailArm / 1000, cbar * 2)
        if c.kind.hasTail {
            let arH = max(c.hStabSpan * c.hStabSpan / max(c.hStabSpan * c.hStabChord, 1), 1)
            let CLat = 2 * .pi * arH / (2 + (arH * arH + 4).squareRoot())
            Cmde = a.tailVolumeH * CLat * tauE              // per radian of elevator
            Cmq = -2 * a.tailVolumeH * CLat * lt / cbar
            tailVH = a.tailVolumeH; tailCLa = CLat; tailArm = lt
            tailAlphaShare = 1 - min(max(2 * CLa / (.pi * AR), 0), 0.6)
        } else if c.kind.isNutBall {
            // The NutBall's elevator is the rear edge of the disc: a flap about half the chord behind the CG.
            Cmde = CLa * Self.flapTau(c.controlChordPct) * 0.6 * 0.55
            Cmq = -0.25 * CLa - 0.4
        } else {
            Cmde = CLa * tauE * c.controlChordPct * 0.5     // elevons: lever about half the MAC behind the CG
            Cmq = -0.25 * CLa - 0.4
        }
        // No built-in trim: the model flies as designed – flat wing and flat stabiliser in one plane, no incidence
        // difference, so no pitching moment of its own (Cm0 = 0). With the CG ahead of the neutral point it trims to
        // almost no lift and dives until the pilot trims nose up (T / G in the simulator); the CG is the design's own.
        Cm0 = 0
        // Roll: ailerons / elevons on the wing strips they cover (`ailTau`), damping of the wing, dihedral effect (flat
        // foam: little).
        ailTau = hasAilerons ? Self.flapTau(c.controlChordPct) : 0
        Clda = 0
        Clp = -CLa / 4
        Clb = -0.03 - 0.0015 * c.dihedral - (c.kind.isTailless ? 0.4 * c.sweep / max(c.semiSpan, 1) * 0.1 : 0)
              - (c.kind.isNutBall ? 0.06 : 0)
        Clr = 0.05
        // Yaw: weathercock from the fin(s), rudder power and damping.
        let vv = max(a.tailVolumeV, 0)
        let CLav = 2.5
        Cnb = c.kind.hasTail ? vv * CLav : (c.kind.isNutBall ? 0.05 : 0.02 + 0.06 * min(c.sweep / max(c.semiSpan, 1), 1) + (c.taillessFins == .none ? 0 : 0.03))
        Cndr = hasRudder ? max(vv, 0.02) * CLav * 0.55 : 0
        Cnr = -0.08 - 2 * vv * CLav * 0.5
        Cnda = -0.01
        CYb = -0.35
        staticThrust = a.thrust * 9.81 / 1000
        stallSpeed = a.stallSpeed / 3.6
        pitchSpeed = max(10, 3.2 * stallSpeed + 4) * (c.customProp ? c.propModel.speed : 1)   // a lower-pitch prop runs out of thrust sooner
        // Inertia: wing mass spread over the span, the rest along the fuselage.
        let L = max(d.overallLength / 1000, b * 0.5)
        let mw = mass * 0.45
        let Iroll = mw * b * b / 12 + mass * 0.0004
        let Ipitch = mass * L * L / 18 + mass * cbar * cbar / 12
        inertia = [Ipitch, Iroll + Ipitch, Iroll]
        groundClearance = max(c.fuselageHeight * 0.5, 15) / 1000

        // Wing strips: 8 per half, chord tapering root → tip (an ellipse on the NutBall's disc), areas adding up to
        // half the wing area. Each strip knows how much of it the aileron / elevon covers (where the builder puts them)
        // and how much lies in the slipstream of a tractor prop (core radius ≈ 0.45 D right behind the prop; the
        // dual tractor's props sit outboard; pusher props blow over no wing).
        let n = 8, semi = b / 2
        var ys: [Double] = [], ws: [Double] = []
        for k in 0..<n {
            let f = (Double(k) + 0.5) / Double(n)
            let chord = c.kind.isNutBall ? (1 - f * f).squareRoot() : 1 + (c.tipChord / max(c.rootChord, 1) - 1) * f
            ys.append(f * semi); ws.append(max(chord, 0.05))
        }
        let wsum = ws.reduce(0, +)
        stripY = ys
        stripS = ws.map { $0 / wsum * S / 2 }
        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double { max(0, min(a1, b1) - max(a0, b0)) }
        let dy = semi / Double(n)
        let ail = c.aileronStations.map { ($0.lowerBound / 1000)...($0.upperBound / 1000) }
        stripAileron = (0..<n).map { k in
            guard let ail, hasAilerons else { return 0 }
            let y0 = Double(k) * dy
            return overlap(y0, y0 + dy, ail.lowerBound, ail.upperBound) / dy
        }
        let washR = 0.45 * c.propInches * 0.0254
        let propXs: [Double] = c.isPusher ? [] : (c.isDual ? [c.dualMotorX / 1000] : [0])
        stripWash = (0..<n).map { k in
            let y0 = Double(k) * dy
            return min(1, propXs.reduce(0) { $0 + overlap(y0, y0 + dy, $1 - washR, $1 + washR) } / dy)
        }
        // Lift change of a strip per radian of aileron: the flap's effectiveness on the wing's lift slope, less the
        // induced flow of the antisymmetric (rolling) load. The roll power then follows from where the ailerons are and
        // how much span they cover.
        aileronDCL = CLa * ailTau * Self.antisymmetricShare
        let armArea = (0..<n).reduce(0.0) { $0 + stripY[$1] * stripS[$1] * stripAileron[$1] }
        Clda = 2 * armArea * aileronDCL / (S * b)

        // Prop wash over the tail: a tractor (or the twin boom's / jet's prop ahead of the tail) blows over the part
        // of the elevator and rudder inside its disc; outboard dual tractors only touch the elevator's ends; the
        // tailless pushers blow over nothing.
        let D = c.propInches * 0.0254
        discArea = Double(c.motorCount) * .pi * D * D / 4
        let blowsTail = !(c.kind.isTailless)
        if blowsTail {
            let elevSpan = c.kind.isNutBall ? 0.6 * c.wingspan / 1000 : c.hStabSpan / 1000
            // At the tail the slipstream has mixed out to about the prop's diameter (with v² = u² + T / (ρA) that carries
            // the thrust's momentum). The elevator: the part of its outline inside it, where the builder stores one.
            let tube = D / 2 * 1000
            if let e = d.controls.first(where: { $0.name == "Elevator" }), e.outline.count >= 3, !c.isDual {
                let bb = Poly.bounds(e.outline)
                washElevator = min(1, Poly.area(Poly.clip(e.outline, to: Poly.rect(minU: bb.min.x - 1, maxU: bb.max.x + 1, minV: -tube, maxV: tube))) / max(Poly.area(e.outline), 1))
            } else {
                washElevator = min(1, D / max(elevSpan, 0.05)) * (c.isDual ? 0.3 : 1)
            }
            // The rudder: the part of its outline inside the slipstream (radius D / 2 about the thrust line, at the
            // plate) – above the plate from just over it (less the cut-out the elevator swings up into) to the fin top;
            // on the 3D Plane and the NutBall also below the plate, where it reaches down through the elevator.
            // Not behind the dual tractor's outboard props, nor on the twin boom's fins out on the booms.
            if let r = d.controls.first(where: { $0.name == "Rudder" }), r.outline.count >= 3, !c.isDual {
                let core = tube, half = c.material.thickness / 2     // outline v is above the plate top
                let bb = Poly.bounds(r.outline)
                func inBand(_ lo: Double, _ hi: Double) -> Double {
                    hi > bb.min.y ? Poly.area(Poly.clip(r.outline, to: Poly.rect(minU: bb.min.x - 1, maxU: bb.max.x + 1, minV: lo, maxV: hi))) : 0
                }
                let above = inBand(-half, core - half), below = inBand(-core - half, -half), area = max(Poly.area(r.outline), 1)
                washRudder = min(1, (above + below) / area)
                washSwirl = (above - below) / area
            } else if c.kind.isTwinBoom {
                washRudder = c.boomX / 1000 < 0.5 * D ? 0.3 : 0
                washSwirl = washRudder
            } else {
                washRudder = c.isDual ? 0 : min(1, 0.5 * D / max(c.vStabHeight / 1000, 0.02))
                washSwirl = washRudder
            }
            // The keel and the plate in the slipstream, from the parts – a single tractor's slipstream on the centre line
            // (not the dual tractors' outboard ones, nor the pushers'). Both are flat slabs, long against their height /
            // width inside the slipstream: slender-body theory puts their side force where that height or width grows
            // (dF = π/2 · q · β · d(h²)), so the nose of the fuselage and the wing's leading edge carry it, not the
            // constant-height boom behind. The tail surfaces in the slipstream add their own lift (low aspect ratio,
            // ≈ 1.5 per radian), halved in the vortex sheet the keel and the wing shed ahead of them.
            if !c.isDual && !c.isPusher && !c.kind.isTailless {
                let cgz = a.cg.z, step = 2.0
                // (the slabs end where the tail surfaces begin: the fin's leading edge)
                let finLE = c.kind.isNutBall ? c.rootChord * (1 - c.controlChordPct) - c.vStabChord
                                             : c.tailArm + 0.6 * c.hStabChord - 1.25 * c.vStabChord
                func slender(_ pieces: [(outline: [Vec2], lo: Double, hi: Double)]) -> Double {
                    let us = pieces.flatMap { p -> [Double] in let b = Poly.bounds(p.outline); return [b.min.x, b.max.x] }
                    guard let u0 = us.min(), let u1 = us.max().map({ min($0, finLE) }) else { return 0 }
                    var hMax = 0.0, moment = 0.0, u = u0
                    while u < u1 {
                        var h = 0.0
                        for p in pieces { h += Poly.area(Poly.clip(p.outline, to: Poly.rect(minU: u, maxU: u + step, minV: p.lo, maxV: p.hi))) / step }
                        if h > hMax { moment += .pi / 2 * (h * h - hMax * hMax) * (u + step / 2 - cgz); hMax = h }
                        u += step
                    }
                    return moment * 1e-9
                }
                var keel: [(outline: [Vec2], lo: Double, hi: Double)] = [], plate: [(outline: [Vec2], lo: Double, hi: Double)] = []
                for part in d.parts {
                    guard let first = part.instances.first else { continue }
                    if abs(first.normal.x) > 0.9 && abs(first.origin.x) < 5 && part.role != .winglet {
                        // vertical on the centre line (one layer of a laminated web): world y = origin.y + v
                        keel.append((part.outline, -tube - first.origin.y, tube - first.origin.y))
                    } else if abs(first.normal.y) > 0.9 && abs(first.origin.y) < 5 {
                        // horizontal at the thrust line, every instance (both wing halves): world x = origin.x + v · v̂.x
                        for pl in part.instances where abs(pl.v.x) > 0.5 {
                            let a0 = (-tube - pl.origin.x) / pl.v.x, a1 = (tube - pl.origin.x) / pl.v.x
                            plate.append((part.outline, min(a0, a1), max(a0, a1)))
                        }
                    }
                }
                blownKeelMoment = slender(keel)
                blownPlateMoment = slender(plate)
                let tailLift = 1.5 * 0.5
                let arm = (c.kind.isNutBall ? c.rootChord * (1 - c.controlChordPct) : c.tailArm + 0.4 * c.hStabChord) / 1000 - cgz / 1000
                blownKeelMoment += tailLift * c.vStabHeight * c.vStabChord * 1e-6 * washRudder * arm
                if c.kind.hasTail { blownPlateMoment += tailLift * c.hStabSpan * c.hStabChord * 1e-6 * washElevator * arm }
            }
        }
        // Motor torque Q ≈ 0.06 · T · D; counter-rotating dual props cancel. Pusher props turn the other way.
        let sense: Double = c.isDual ? 0 : (c.kind.isPusher ? -1 : 1)
        torquePerThrust = 0.06 * D * sense
        // Gyroscopic: H = I·Ω per prop at full throttle (I = m R² / 3, Ω from the pitch speed and the pitch).
        let propMass = c.propInches * 0.35 / 1000 * (c.customProp ? Double(c.propBladeCount) / Double(c.kind.propBlades) : 1)
        let pitchM = max(c.propModel.pitch, 1) * 0.0254
        let omegaMax = 2 * .pi * pitchSpeed / pitchM
        propH = propMass * (D / 2) * (D / 2) / 3 * omegaMax * sense
        swirlFin = c.kind.hasTail ? !c.kind.isTwinBoom : (c.kind.isNutBall || c.hasCentreFin)
        // (about 40 % with the wing right behind a single tractor prop, 20 % more where the + fuselage's vertical
        // halves stand in the slipstream too, like stator vanes; nothing behind a pusher's)
        swirlRecovery = c.isDual || c.isPusher ? 0 : (0.4 + (c.kind.hasFuselage ? 0.2 : 0)) * min(1, stripWash.reduce(0, +))
    }

    /// Throws as flown at full stick, degrees (roll, pitch, yaw): what a typical setup of the type uses – a trainer
    /// or glider gentle, a sport model more, the 3D Plane and the NutBall all the way.
    static func flightThrows(_ kind: AircraftKind) -> (roll: Double, pitch: Double, yaw: Double) {
        switch kind {
        case .trainer: return (12, 15, 35)
        case .glider: return (10, 12, 35)
        case .twinBoom: return (13, 15, 35)
        case .jet: return (16, 16, 35)
        case .flyingWing: return (18, 15, 25)
        case .delta: return (26, 22, 25)
        case .aerobat: return (45, 45, 45)
        case .nutBall: return (30, 35, 40)
        }
    }
    /// The fin's side force against sideslip β, per unit of its linear slope (2.5 / rad): linear, rounding off past
    /// ~20°, a flat plate's normal force ≈ 1.1 broadside.
    static func finCurve(_ beta: Double) -> Double {
        let s = sin(beta)
        return (liftCurve(beta, slope: 2.5, stall: 20 * .pi / 180) * cos(beta) + 1.1 * s * abs(s)) / 2.5
    }
    /// A hinged flat surface turns the flow less and less beyond about 25°: the deflection that counts (rad).
    static let surfaceSaturation = 0.45
    static func effective(_ deflection: Double) -> Double { surfaceSaturation * tanh(deflection / surfaceSaturation) }
    /// Flap effectiveness of a control surface of chord fraction cf (thin-aerofoil theory, × 0.8 for a flat plate
    /// with a tape hinge at low Reynolds numbers).
    static func flapTau(_ cf: Double) -> Double {
        let th = acos(2 * min(max(cf, 0.05), 0.6) - 1)
        return 0.8 * (1 - (th - sin(th)) / .pi)
    }
    /// Share of the strip lift change a rolling (antisymmetric) load keeps against its own induced flow.
    static let antisymmetricShare = 0.8

    /// Lift curve of a flat plate with slope `slope` and stall angle `stall`: linear, a rounded top (from 75 % of the
    /// stall angle), then over 11° down to the flat plate's 0.9·sin 2α – no sudden break.
    static func liftCurve(_ alpha: Double, slope: Double, stall: Double) -> Double {
        let a = abs(alpha), sgn: Double = alpha < 0 ? -1 : 1
        let x = a / stall
        let rounded = x < 0.75 ? x : 0.75 + 0.25 * tanh((x - 0.75) / 0.25)
        let attached = slope * stall * rounded
        let t = smooth((a - stall) / (11 * .pi / 180))
        return sgn * attached * (1 - t) + 0.9 * sin(2 * alpha) * t
    }
    static func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    /// Lift coefficient of the wing.
    func CL(_ alpha: Double) -> Double { Self.liftCurve(alpha, slope: CLa, stall: alphaStall) }
    /// How far into the stall (0 attached … 1 fully separated), rising from 2° below the stall angle to 10° above.
    func stallShare(_ alpha: Double) -> Double { Self.smooth((abs(alpha) - alphaStall + 2 * .pi / 180) / (12 * .pi / 180)) }
}

/// Rigid-body state in the world (metres, y up, the pilot at the origin looking along −z).
struct FlightState {
    var position = SIMD3<Double>(0.35, 1.55, -0.7)
    var velocity = SIMD3<Double>.zero
    var orientation = simd_quatd(angle: 6 * .pi / 180, axis: [1, 0, 0])   // body → world, nose a little up
    var omega = SIMD3<Double>.zero                                          // body rates (x pitch, y yaw, z roll)
    enum Phase { case held, flying, landed, crashed }
    var phase = Phase.held
    var time = 0.0
    var maxAltitude = 0.0
    var message = ""
    /// What ended the flight, and how long ago (the simulator puts the model back in the hand after a second).
    enum Impact { case ground, tree, water, lost }
    var impact: Impact?
    var crashAge = 0.0
}

/// The flight simulation: hand launch, flight, ground contact.
final class FlightSim {
    let model: FlightModel
    private(set) var state = FlightState()
    var input = StickInput()
    /// Smoothed surface deflection actually applied (servos are not instantaneous).
    private(set) var surfaces = StickInput()
    static let rho = 1.225, g = 9.81

    init(model: FlightModel) { self.model = model }

    func reset() { state = FlightState(); surfaces = StickInput() }
    /// Place the model (self-test views).
    func place(_ p: SIMD3<Double>) { state.position = p }
    /// Set the whole state (self-test flight cases: hover, spin entry).
    func setState(_ s: FlightState) { state = s }

    /// Hand launch: a firm throw along the nose, a little above stall speed.
    func launch() {
        guard state.phase == .held else { return }
        let fwd = state.orientation.act([0, 0, -1])
        state.velocity = fwd * max(model.stallSpeed * 1.25, 5)
        state.phase = .flying
        state.message = ""
    }

    func step(_ dt: Double) {
        let n = max(1, Int((dt / (1.0 / 600)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n { substep(h) }
        if state.phase == .crashed { state.crashAge += dt }
    }

    private func crash(_ kind: FlightState.Impact, _ text: String) {
        state.phase = .crashed
        state.impact = kind
        state.message = text
        state.velocity = .zero; state.omega = .zero
    }

    private func substep(_ h: Double) {
        // Servo speed: ~0.1 s for full travel.
        func slew(_ cur: Double, _ target: Double) -> Double { cur + max(min(target - cur, h * 10), -h * 10) }
        surfaces.roll = slew(surfaces.roll, input.roll); surfaces.pitch = slew(surfaces.pitch, input.pitch)
        surfaces.yaw = slew(surfaces.yaw, input.yaw); surfaces.throttle = slew(surfaces.throttle, input.throttle)
        guard state.phase == .flying else { return }
        state.time += h                         // flight time (from the launch)

        let m = model, q = state.orientation
        let vb = q.inverse.act(state.velocity)
        let V = simd_length(vb)
        var force = SIMD3<Double>.zero, torque = SIMD3<Double>.zero
        // Without ailerons the roll stick does nothing here (the NutBall's roll-to-rudder mix is in the input, an option).
        var da = m.hasAilerons ? surfaces.roll : 0
        var dr = m.hasRudder ? surfaces.yaw : 0
        da = max(min(da, 1), -1); dr = max(min(dr, 1), -1)
        let de = surfaces.pitch
        // Deflections that count (rad): the throws as flown, levelling off above ~25°.
        let dA = FlightModel.effective(da * m.rollThrow), dE = FlightModel.effective(de * m.pitchThrow), dR = FlightModel.effective(dr * m.yawThrow)
        // Thrust along the nose, falling off with airspeed.
        let u = max(-vb.z, 0)
        // (thrust grows about with rpm², rpm about with throttle → throttle^1.6)
        let thrust = m.staticThrust * pow(max(surfaces.throttle, 0), 1.6) * max(0, 1 - u / m.pitchSpeed)
        force += SIMD3(0, 0, -thrust)
        // Slipstream at the tail (momentum theory, half way between the disc and the fully developed wake):
        // v² = u² + T / (ρ A).
        let qWash = 0.5 * Self.rho * (u * u + thrust / (Self.rho * m.discArea))
        // Motor torque: the airframe rolls against the prop (left behind a clockwise tractor prop) – a flat foam plane
        // has no side thrust in its mount. A wing behind the prop straightens part of the slipstream's swirl and
        // takes that much back (the swirl carries the torque's angular momentum – the wing can't give back more).
        torque.z += m.torquePerThrust * thrust * (1 - m.swirlRecovery)

        // Wing in strips, each in its own airflow (body velocity + rotation × station): its own angle of attack, lift
        // and drag, its own stall. Roll damping, aileron power (with reversal near the stall), tip stall, wing drop and
        // spins follow from these. The part of a strip in a tractor prop's slipstream also gets the slipstream's
        // airflow – its aileron keeps working at any airspeed (hover, prop hang), and its drag holds back the thrust.
        // Induced drag: each strip's lift tilted back by the wing's downwash, which follows the whole wing's lift
        // (cd = k · cl_strip · CL_wing) – adverse aileron yaw in the right measure.
        let CLwing = V > 0.3 ? m.CL(atan2(-vb.y, -vb.z)) : 0
        let washDelta = max((u * u + thrust / (Self.rho * m.discArea)).squareRoot() - u, 0)
        // The slipstream's swirl (tangential speed ≈ Q / (ρ A v r̄), r̄ ≈ 0.35 D) on a centre fin in it: like a
        // sideslip, yawing the nose left behind a clockwise tractor prop.
        let swirlSense: Double = m.torquePerThrust > 0 ? 1 : (m.torquePerThrust < 0 ? -1 : 0)
        let vSwirl = thrust > 0 ? 0.06 / 0.35 * thrust / (Self.rho * m.discArea * max(u + washDelta, 0.5)) : 0
        for side in [1.0, -1.0] {
            for k in 0..<m.stripY.count {
                let rpos = SIMD3<Double>(side * m.stripY[k], 0, 0)
                let vs = vb + simd_cross(state.omega, rpos)
                // Aileron: a lift change on the strip (right aileron up for roll right) – it fades as the strip stalls, so
                // near the stall the ailerons lose grip instead of pushing a wing further in.
                let ail = -side * m.aileronDCL * dA * m.stripAileron[k]
                func strip(_ v: SIMD3<Double>, _ area: Double) {
                    let Vs = simd_length(v)
                    guard Vs > 0.3, area > 0 else { return }
                    let a = atan2(-v.y, -v.z)
                    let sep = m.stallShare(a)
                    let cl = m.CL(a) + ail * (1 - 0.7 * sep)
                    let cd = m.CD0 + m.k * cl * CLwing + 1.1 * pow(sin(a), 2) * (0.3 + 0.7 * sep) + 0.6 * ail * ail
                    let vh = v / Vs
                    let liftDir = simd_normalize(simd_cross([1, 0, 0], vh))
                    let qs = 0.5 * Self.rho * Vs * Vs * area
                    let f = liftDir * (qs * cl) - vh * (qs * cd)
                    force += f
                    torque += simd_cross(rpos, f)
                }
                let wf = m.stripWash[k]
                if wf > 0, washDelta > 0.05 {
                    strip(vs + SIMD3(0, 0, -washDelta), m.stripS[k] * wf)
                    strip(vs, m.stripS[k] * (1 - wf))
                } else {
                    strip(vs, m.stripS[k])
                }
            }
        }
        let p = -state.omega.z, qq = state.omega.x, r = -state.omega.y
        let qbar = 0.5 * Self.rho * V * V
        var stallFade = 1.0
        if V > 0.3 {
            let alpha = atan2(-vb.y, -vb.z)
            let beta = asin(max(min(vb.x / V, 1), -1))
            // (the wing's wake over the tail: the elevator loses some grip as the wing stalls)
            stallFade = 1 - 0.4 * m.stallShare(alpha)
            let qS = qbar * m.S
            force += SIMD3<Double>(qS * m.CYb * beta, 0, 0)
            // Pitch: stability and trim (damping and the elevator below, with the wash). Roll: only the dihedral effect
            // is left here – the rest comes from the strips. Yaw: weathercock (damping below).
            var Cm = m.Cm0 + m.Cma * alpha
            // The tail's own stall: its angle of attack (the wing's angle less the downwash, the pitch rate, the elevator)
            // beyond its stall angle makes less lift than the linear terms above and below assume – the difference is
            // taken back, so a full pull ends near the stall instead of rotating the model on and on.
            if m.tailVH > 0 {
                let xt = m.tailAlphaShare * alpha + qq * m.tailArm / V - m.Cmde / max(m.tailVH * m.tailCLa, 1e-9) * dE
                let linear = m.tailCLa * xt, actual = FlightModel.liftCurve(xt, slope: m.tailCLa, stall: m.tailStall)
                Cm += -m.tailVH * (actual - linear) * (1 - m.washElevator)
            }
            let Cl = m.Clb * beta
            // (adverse aileron yaw comes from the strips' drag) The fin stalls too: beyond ~20° of sideslip its push
            // levels off, broadside (a sideways slide in a hover) it is a flat plate's ≈ 1.1 – not the linear term at 90°.
            let Cn = m.Cnb * FlightModel.finCurve(beta)
            torque += SIMD3<Double>(qS * m.cbar * Cm, -qS * m.b * Cn, -qS * m.b * Cl)
        }
        // (what the wing and the fuselage ahead of it have straightened out no longer reaches the fin)
        if m.swirlFin, m.washSwirl != 0 {
            torque.y += swirlSense * qWash * m.washSwirl * m.S * m.b * m.Cnb * atan(vSwirl * (1 - m.swirlRecovery) / max(u + washDelta, 0.5))
        }
        // Hanging on the prop, a sideways slide blows across the slipstream: everything in it – keel, fin, rudder,
        // plate, wing, stabiliser, elevator – meets it at atan(slide / slipstream speed) with the thrust's share of
        // the slipstream's dynamic pressure (levelling off past 20°). What pushes behind the CG swings the nose into
        // the slide and tips the model further over; the nose of the flat fuselage and the wing's leading edge push
        // back. (Only the moment: the wing's strips already carry the force.)
        if m.blownKeelMoment != 0 || m.blownPlateMoment != 0, thrust > 0 {
            let qT = 0.5 * thrust / m.discArea, vS = max(u + washDelta, 0.5)
            torque.y += -qT * FlightModel.liftCurve(atan(vb.x / vS), slope: 1, stall: 20 * .pi / 180) * m.blownKeelMoment
            torque.x += qT * FlightModel.liftCurve(atan(vb.y / vS), slope: 1, stall: 20 * .pi / 180) * m.blownPlateMoment
        }
        // Pitch and yaw damping (mostly the tail): ½ρ·V·rate – the part of the tail in the prop's slipstream turns
        // through the slipstream's speed, so a hanging model is damped too, not only one with airspeed.
        let vWash = u + washDelta
        let vPitch = V * (1 - m.washElevator) + vWash * m.washElevator
        let vYaw = V * (1 - m.washRudder) + vWash * m.washRudder
        torque.x += 0.5 * Self.rho * vPitch * m.S * m.cbar * m.Cmq * qq * m.cbar / 2
        torque.y += -0.5 * Self.rho * vYaw * m.S * m.b * m.Cnr * r * m.b / 2
        // Elevator and rudder: the part in the prop's slipstream keeps working at any airspeed (hover, prop hang),
        // the rest sees the free stream (and loses grip in a stall).
        let qElev = qbar * (1 - m.washElevator) * stallFade + qWash * m.washElevator
        let qRud = qbar * (1 - m.washRudder) + qWash * m.washRudder
        torque.x += qElev * m.S * m.cbar * m.Cmde * dE
        torque.y += -qRud * m.S * m.b * m.Cndr * dR
        // Integrate (body forces → world).
        let accel = q.act(force) / m.mass + SIMD3(0, -Self.g, 0)
        state.velocity += accel * h
        state.position += state.velocity * h
        let I = m.inertia
        let w = state.omega
        // Rigid body plus the spinning prop's angular momentum (gyroscopic precession).
        let rpmShare = pow(max(surfaces.throttle, 0), 0.8)
        let Hprop = SIMD3<Double>(0, 0, -m.propH * rpmShare)
        let Iw = I * w + Hprop
        let wdot = (torque - simd_cross(w, Iw)) / I
        state.omega += wdot * h
        let wl = simd_length(state.omega)
        if wl > 1e-9 { state.orientation = simd_normalize(state.orientation * simd_quatd(angle: wl * h, axis: state.omega / wl)) }
        state.maxAltitude = max(state.maxAltitude, state.position.y)
        // Ground: a touch-down slower than ~2.5 m/s down and below ~2.2× stall speed lands, anything harder crashes.
        let ground = SimScenery.surfaceHeight(state.position.x, state.position.z)
        if state.position.y < ground + m.groundClearance {
            let vdown = -state.velocity.y, speed = simd_length(state.velocity)
            let up = state.orientation.act([0, 1, 0])
            state.position.y = ground + m.groundClearance
            if SimScenery.isWater(state.position.x, state.position.z) {
                crash(.water, "Splash – into the pond")
            } else if vdown > 2.5 || speed > max(2.2 * m.stallSpeed, 7) || up.y < 0.3 {
                crash(.ground, String(format: "Crashed – %.1f m/s down, %.1f m/s", vdown, speed))
            } else {
                state.phase = .landed
                state.message = String(format: "Landed – %.1f s flight", state.time)
                state.velocity = .zero; state.omega = .zero
                // Settle level on the ground, keeping the heading.
                let fwd = state.orientation.act([0, 0, -1])
                let heading = atan2(-fwd.x, -fwd.z)
                state.orientation = simd_quatd(angle: heading, axis: [0, 1, 0])
            }
        } else if let what = SimScenery.obstacle(at: state.position) {
            crash(.tree, "Crashed into \(what)")
        }
        // Far away or way out: stop.
        if state.phase == .flying, simd_length(SIMD2(state.position.x, state.position.z)) > 600 { crash(.lost, "Out of sight") }
    }

    /// Airspeed (m/s), height (m), attitude helpers for the HUD.
    var airspeed: Double { simd_length(state.velocity) }
    var height: Double { state.position.y - SimScenery.surfaceHeight(state.position.x, state.position.z) - model.groundClearance }
}
