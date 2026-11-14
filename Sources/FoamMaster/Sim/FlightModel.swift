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
    /// Wing strips (right half; the left half mirrors it): span station y (m), area (m²), aileron / elevon on it.
    var stripY: [Double] = [], stripS: [Double] = []
    /// Share of each strip covered by the aileron / elevon, and lying in the prop's slipstream (tractors).
    var stripAileron: [Double] = [], stripWash: [Double] = []
    /// Aileron: change of strip lift coefficient per radian of aileron (calibrated to the roll power Clda).
    var aileronDCL: Double = 0
    /// Share of the elevator / rudder inside the prop's slipstream, total disc area (m²).
    var washElevator: Double = 0, washRudder: Double = 0, discArea: Double = 0.01
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
        // No built-in trim: the model flies as designed – flat wing and flat stabiliser in one plane, no incidence
        // difference, so no pitching moment of its own (Cm0 = 0). With the CG ahead of the neutral point it trims to
        // almost no lift and dives until the pilot trims nose up (T / G in the simulator); the CG is the design's own.
        Cm0 = 0
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
        // Same roll power as Clda at small angles: Σ y·S·ΔCL over both halves = S·b·Clda per radian.
        let armArea = (0..<n).reduce(0.0) { $0 + stripY[$1] * stripS[$1] * stripAileron[$1] }
        aileronDCL = armArea > 0 ? S * b * Clda / (2 * armArea) : 0

        // Prop wash over the tail: a tractor (or the twin boom's / jet's prop ahead of the tail) blows over the part
        // of the elevator and rudder inside its disc; outboard dual tractors only touch the elevator's ends; the
        // tailless pushers blow over nothing.
        let D = c.propInches * 0.0254
        discArea = Double(c.motorCount) * .pi * D * D / 4
        let blowsTail = !(c.kind.isTailless)
        if blowsTail {
            let elevSpan = c.kind.isNutBall ? 0.6 * c.wingspan / 1000 : c.hStabSpan / 1000
            // (the slipstream's core contracts to about 0.7 D)
            washElevator = min(1, 0.7 * D / max(elevSpan, 0.05)) * (c.isDual ? 0.3 : 1)
            washRudder = c.isDual ? 0 : min(1, 0.35 * D / max(c.vStabHeight / 1000, 0.02))
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
                // Aileron: like a change of the strip's incidence (right aileron up for roll right).
                let ail = -side * m.aileronDCL * da * m.maxThrow / m.CLa * m.stripAileron[k]
                func strip(_ v: SIMD3<Double>, _ area: Double) {
                    let Vs = simd_length(v)
                    guard Vs > 0.3, area > 0 else { return }
                    let a = atan2(-v.y, -v.z) + ail
                    let cl = m.CL(a)
                    let cd = m.CD0 + m.k * cl * CLwing + 1.1 * pow(sin(a), 2) * (abs(a) > m.alphaStall ? 1 : 0.3)
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
            stallFade = abs(alpha) > m.alphaStall ? 0.5 : 1.0
            let qS = qbar * m.S
            force += SIMD3<Double>(qS * m.CYb * beta, 0, 0)
            // Pitch: stability and trim (damping and the elevator below, with the wash). Roll: only the dihedral effect
            // is left here – the rest comes from the strips. Yaw: weathercock (damping below).
            let Cm = m.Cm0 + m.Cma * alpha
            let Cl = m.Clb * beta
            let Cn = m.Cnb * beta                       // (adverse aileron yaw comes from the strips' drag)
            torque += SIMD3<Double>(qS * m.cbar * Cm, -qS * m.b * Cn, -qS * m.b * Cl)
        }
        // (what the wing and the fuselage ahead of it have straightened out no longer reaches the fin)
        if m.swirlFin, m.washRudder > 0 {
            torque.y += swirlSense * qWash * m.washRudder * m.S * m.b * m.Cnb * atan(vSwirl * (1 - m.swirlRecovery) / max(u + washDelta, 0.5))
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
        torque.x += qElev * m.S * m.cbar * m.Cmde * de * m.maxThrow
        torque.y += -qRud * m.S * m.b * m.Cndr * dr * m.maxThrow
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
