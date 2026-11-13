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
    var maxThrow: Double        // rad
    var hasAilerons: Bool, hasRudder: Bool, tailless: Bool
    var stallSpeed: Double      // m/s (from the analysis)
    /// Lowest point of the airframe below the CG (m) – touches the ground first.
    var groundClearance: Double

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
        maxThrow = c.kind.maxSurfaceThrow * .pi / 180
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
        } else {
            Cmde = CLa * tauE * c.controlChordPct * 0.5     // elevons: lever about half the MAC behind the CG
            Cmq = -0.25 * CLa - 0.4
        }
        // Trimmed (as the builder trims the elevator) for level flight at about 1.4 × stall speed.
        let vTrim = max(a.stallSpeed / 3.6 * 1.4, 3)
        let clTrim = 2 * mass * 9.81 / (1.225 * vTrim * vTrim * S)
        Cm0 = -Cma * clTrim / CLa
        // Roll: ailerons / elevons on the outer wing, damping of the wing, dihedral effect (flat foam: little).
        let sa = min(max(c.controlChordPct, 0.1), 0.45)
        Clda = hasAilerons ? 0.5 * CLa * tauE * sa * 0.65 * (c.kind.isTailless ? 1.2 : 1) : 0
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
        pitchSpeed = max(10, 3.2 * stallSpeed + 4)
        // Inertia: wing mass spread over the span, the rest along the fuselage.
        let L = max(d.overallLength / 1000, b * 0.5)
        let mw = mass * 0.45
        let Iroll = mw * b * b / 12 + mass * 0.0004
        let Ipitch = mass * L * L / 18 + mass * cbar * cbar / 12
        inertia = [Ipitch, Iroll + Ipitch, Iroll]
        groundClearance = max(c.fuselageHeight * 0.5, 15) / 1000
    }

    /// Lift coefficient with a soft stall: linear up to the stall angle, then down to a flat plate (sin 2α).
    func CL(_ alpha: Double) -> Double {
        let lin = CLa * alpha
        let a = abs(alpha)
        if a <= alphaStall { return lin }
        let plate = 0.9 * sin(2 * alpha)
        let t = min((a - alphaStall) / (8 * .pi / 180), 1)
        return CLa * alphaStall * (alpha < 0 ? -1 : 1) * (1 - t) + plate * t
    }
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
        // Pilot mixing: without ailerons the roll stick also works the rudder; without a rudder only roll is left.
        var da = m.hasAilerons ? surfaces.roll : 0
        var dr = m.hasRudder ? surfaces.yaw + (m.hasAilerons ? 0 : surfaces.roll) : 0
        da = max(min(da, 1), -1); dr = max(min(dr, 1), -1)
        let de = surfaces.pitch
        if V > 0.3 {
            let alpha = atan2(-vb.y, -vb.z)
            let beta = asin(max(min(vb.x / V, 1), -1))
            let qbar = 0.5 * Self.rho * V * V
            let CL = m.CL(alpha)
            let CD = m.CD0 + m.k * CL * CL + 1.1 * pow(sin(alpha), 2) * (abs(alpha) > m.alphaStall ? 1 : 0.3)
            let vhat = vb / V
            let liftDir = simd_normalize(simd_cross([1, 0, 0], vhat))
            let qS = qbar * m.S
            let lift: SIMD3<Double> = liftDir * (qS * CL)
            let drag: SIMD3<Double> = vhat * (qS * CD)
            let side = SIMD3<Double>(qS * m.CYb * beta, 0, 0)
            force += lift - drag + side
            // Body rates as roll p (right wing down), pitch q (nose up), yaw r (nose right).
            let p = -state.omega.z, qq = state.omega.x, r = -state.omega.y
            let ph = p * m.b / (2 * V), qh = qq * m.cbar / (2 * V), rh = r * m.b / (2 * V)
            let stallFade = abs(alpha) > m.alphaStall ? 0.5 : 1.0
            let Cm = m.Cm0 + m.Cma * alpha + m.Cmde * de * m.maxThrow * stallFade + m.Cmq * qh
            let Cl = m.Clb * beta + m.Clda * da * m.maxThrow * stallFade + m.Clp * ph + m.Clr * rh
            let Cn = m.Cnb * beta + m.Cndr * dr * m.maxThrow + m.Cnr * rh + m.Cnda * da * m.maxThrow
            let tq = SIMD3<Double>(qS * m.cbar * Cm, -qS * m.b * Cn, -qS * m.b * Cl)
            torque += tq
        }
        // Thrust along the nose, falling off with airspeed.
        let u = max(-vb.z, 0)
        // (thrust grows about with rpm², rpm about with throttle → throttle^1.6)
        let thrust = m.staticThrust * pow(max(surfaces.throttle, 0), 1.6) * max(0, 1 - u / m.pitchSpeed)
        force += SIMD3(0, 0, -thrust)
        // Integrate (body forces → world).
        let accel = q.act(force) / m.mass + SIMD3(0, -Self.g, 0)
        state.velocity += accel * h
        state.position += state.velocity * h
        let I = m.inertia
        let w = state.omega
        let Iw = I * w
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
                state.message = String(format: "Landed – %.1f s flight · press R", state.time)
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
