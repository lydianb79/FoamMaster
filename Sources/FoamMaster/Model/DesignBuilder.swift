import Foundation
import simd

extension AircraftConfig {
    /// Depth of the trailing-edge cutout the pusher motor of a flying wing sits in.
    /// Motor body length (bell + base) along the thrust line.
    var motorLength: Double { motor.bellDiameter + 4 }
    /// Depth of the trailing-edge cutout the pusher motor of a flying wing sits in: firewall at the front of
    /// the cutout, motor body behind it, prop spinning inside the cutout.
    var motorNotchDepth: Double { max(26, motorLength + 14) }
    var motorNotchWidth: Double { propInches * 25.4 + 2 * AircraftConfig.propClearance }
    /// Half width of the trailing-edge cutout: at least the prop + clearance, and it ends at the elevons.
    var motorNotchHalfWidth: Double { max(semiSpan * 0.12, motorNotchWidth / 2) }
    /// Firewall (printed mount plate) position. The clamp always grips the structure ahead of / behind it:
    /// pusher = structure in front, motor and prop behind; tractor = structure behind, motor and prop in front.
    /// Lateral position of the two motors of a dual-tractor layout: props clear the fuselage/pod and each other.
    /// As far inboard as possible (less roll inertia and less yaw if one motor quits) while the props clear the
    /// fuselage/pod/centre fin by 4 mm.
    var dualMotorX: Double { max(propRadius + dualBodyHalfWidth + AircraftConfig.propClearance, propRadius + minDualPropGap / 2) }
    /// Clear gap kept between the two prop discs of a dual tractor: 25 mm, or a quarter of the diameter for big props
    /// (the props' tip vortices and the airflow between them must not interfere).
    var minDualPropGap: Double { max(25, 0.25 * 2 * propRadius) }
    /// Gap between the two prop discs as built.
    var dualPropGap: Double { 2 * dualMotorX - 2 * propRadius }
    /// Half width of whatever sits between the two props (centre fin / keel, or fuselage plate / pod).
    var dualBodyHalfWidth: Double {
        kind.isTailless ? (taillessFins.hasCentreFin ? material.thickness / 2 + 2 : 4) : fuselagePlateWidth / 2 + 2
    }
    /// The printed firewall plate always sits against the end of the foam, never inside it: tractors have the plate
    /// in front of the nose / leading edge, pushers behind the foam end. `firewallZ` is the plate face the motor
    /// is screwed to.
    var firewallZ: Double {
        let th = firewallThickness
        if isDual { return sweep * dualMotorX / semiSpan - th - mountStandoff }   // plate (+ standoff) ahead of the LE
        if kind.isTailless { return rootChord - motorNotchDepth + th } // plate against the front of the TE cutout
        if kind.isTwinBoom { return rootChord + th }                  // plate against the end of the pod
        if kind.isJet { return jetPropZ - 4 - motorLength }           // prop disc exactly at jetPropZ
        return -noseLength - th
    }
    var firewallThickness: Double { PrintedParts.firewallThickness(motor) }

    /// One aileron servo: aileron, elevator and rudder servos centred on the plate (half in the upper, half in the
    /// lower fuselage half), which holds them firmly and keeps the pushrods clear of the structure. Ahead of the
    /// spar groove: the elevator servo next to it, the aileron servo (shaft down) in front – so the elevator pushrod
    /// (arm down, under the plate) starts behind the aileron double arm and stays inboard of the aileron pushrods.
    /// Behind the spar: the rudder servo.
    var centralSparU: Double {
        let w = TaperedPanel(rootChord: rootChord, tipChord: tipChord, sweep: sweep, semiSpan: semiSpan)
        let hw = fuselagePlateWidth / 2
        return w.le(hw) + 0.3 * w.chord(hw)
    }
    var centralSparHalf: Double { sparEnabled ? sparSpec.widthMM / 2 : 1.5 }
    /// Slope du/dv of the wing spar line (30 % chord) on each wing half: sweep plus taper.
    var sparSlope: Double { (sweep + 0.3 * (tipChord - rootChord)) / max(semiSpan, 1) }
    /// Angle between each spar half and the span-wise direction (degrees).
    var sparSweepAngle: Double { atan(abs(sparSlope)) * 180 / .pi }
    /// Swept spar line: two rods, one per wing half, meeting at the centre line in a printed spar joiner.
    var hasSparJoiner: Bool { sparEnabled && !kind.isNutBall && sparSweepAngle > 1 }
    /// Length of each joiner arm along its rod.
    var sparJoinerArm: Double { max(25, sparSpec.widthMM * 9) }
    /// The joiner's floor sits inside the foam (pocket deeper than the groove) when at least 1 mm of foam stays above
    /// it, otherwise on the underside (0.6 mm proud) and the pocket is only as deep as the groove.
    var sparJoinerFloorInside: Bool { material.thickness - (sparSpec.widthMM + PrintedParts.joinerFloor) >= 1.0 }
    /// Root station (u) of the spar line.
    var sparRootU: Double { 0.3 * rootChord }
    /// Half length of the plate opening for a servo passing through the webs (flush, 0.2 mm each end).
    var centralWebServoHalfOpening: Double { servo.size.l / 2 + 0.2 }
    /// Next to the spar groove, 2 mm clear of it – also its arm pocket (on the aft side of the opening).
    var centralElevatorServoU: Double {
        let pocketAft = servo.size.l / 2 - 5 + ServoClass.armSwingAlong(sheet: material.thickness)
        return centralSparU - centralSparHalf - 2 - max(centralWebServoHalfOpening + servo.earLength, pocketAft)
    }
    var centralAileronServoU: Double {
        // 8 mm between the openings – at least both ears plus 1 mm, so the ears never meet.
        centralElevatorServoU - centralWebServoHalfOpening - max(8, 2 * servo.earLength + 1) - 0.2 - servo.size.l / 2
    }
    /// Depth of the battery's top edge below the plate centre on the cross-fuselage types: it hangs just below the
    /// elevator / rudder servos centred on the plate, so it can sit beside them (1 mm under the plate otherwise).
    var batteryTop: Double { max(material.thickness / 2 + 1, servo.size.w / 2 + 0.8) }
    /// Front edge of the foremost servo (the aileron servo's cutout in the plate).
    /// (Its ears hang below the plate within the servo's width – beside the battery, not in front of it.)
    var centralServosFrontU: Double { centralAileronServoU - servo.size.l / 2 - 0.2 }
    /// First station behind the spar for the rudder servo (the builder moves it aft if its plate opening needs it).
    var centralRudderServoU: Double { centralSparU + centralSparHalf + 2 + centralWebServoHalfOpening + servo.earLength }
    var hasCentralAileronServo: Bool { hasAilerons && aileronServos == 1 && kind.allowsSingleAileronServo }

    /// Nose face (+ section) `d` mm aft of the nose: plate half width and web height above / below the plate.
    /// Matches the outlines drawn by the builder (the nose tapers to the size of the motor mount / nose cone).
    func noseFace(at d: Double) -> (halfWidth: Double, top: Double, bottom: Double) {
        let t = material.thickness, W = fuselagePlateWidth, hw = W / 2
        let halfWidth = W * 0.3 + (hw - W * 0.3) * min(1, d / 6)
        if kind.isTwinBoom {
            let hp = fuselageHeight * 0.5 - t / 2
            return (halfWidth, hp * 0.5 + hp * 0.4 * min(1, d / (0.35 * noseLength)), hp * 0.5 + hp * 0.5 * min(1, d / (0.3 * noseLength)))
        }
        let mountHalf = PrintedParts.motorMountPlate(motor, foam: t) / 2
        let hNose = fuselageHeight * 0.4 - t / 2, hLowWing = fuselageHeight * 0.5 - t / 2
        let top0 = min(hNose * 0.65, max(mountHalf - t / 2 - 0.5, 4)), bot0 = min(hLowWing * 0.55, max(mountHalf - t / 2 - 0.5, 4))
        return (halfWidth, top0 + (hNose - top0) * min(1, d / (0.35 * noseLength)), bot0 + (hLowWing - bot0) * min(1, d / (0.3 * noseLength)))
    }
    /// Printed standoff between firewall and clamp jaws. Needed for dual tractors on swept wings: the inboard
    /// half of each prop disc sweeps ahead of the leading edge there, so the motor has to move forward until
    /// the blades keep `propClearance` to the closest point of the leading edge.
    var mountStandoff: Double {
        guard isDual else { return 0 }
        let x = dualMotorX, reach = propRadius + AircraftConfig.propClearance
        let leAtMount = sweep * x / semiSpan
        let leMin = sweep * max(0, x - reach) / semiSpan
        let need = AircraftConfig.propClearance + propDepthIn + (leAtMount - leMin) - (firewallThickness + motorLength + 4)
        return need > 0 ? (need + 1).rounded(.up) : 0
    }

    // MARK: Propeller

    /// Prop diameter used (inches). The jet's prop spins in a slot through the wing: it is kept to 4" so the slot
    /// stays short, the wing root keeps its strength and the prop clears the ground on belly landings.
    /// Whether the pilot can choose the prop: the type allows it and it flies one tractor motor (not the dual tractor).
    var offersPropChoice: Bool { kind.allowsPropChoice && !isDual }
    /// A prop of the pilot's own (size or blades) is set and applies.
    var customProp: Bool { offersPropChoice && (propSize != nil || propBladeChoice != nil) }
    static let propSizeRange: ClosedRange<Double> = 2.5...8
    var propInches: Double {
        if offersPropChoice, let s = propSize { return min(max(s, Self.propSizeRange.lowerBound), Self.propSizeRange.upperBound) }
        return kind.isJet ? min(motor.propInches, 4) : motor.propInches
    }
    var propRadius: Double { propInches * 25.4 / 2 }
    var propBladeCount: Int { offersPropChoice ? (propBladeChoice ?? kind.propBlades) : kind.propBlades }

    /// The chosen prop on this motor and battery, relative to the motor's standard prop with the type's usual blades
    /// (factors 1 for the standard prop). Pitch is the usual pitch-to-diameter ratio for the cell count, lowered on
    /// a prop bigger than the motor's standard one so it asks for at most 60 % more power at the motor's rpm (never
    /// below 0.25 × D). Power the prop absorbs at that rpm ∝ blades × D⁴ × pitch (3-blade ≈ 1.27 × a 2-blade); the motor
    /// slows under the load, so the power it really delivers grows only with the square root of that. Static thrust
    /// (momentum theory) ∝ P^(2/3) · D^(2/3), a 3-blade ≈ 6 % less efficient. Speed ∝ pitch × rpm.
    struct PropModel { var pitch: Double; var thrust: Double; var power: Double; var speed: Double }
    var propModel: PropModel {
        let ratio = (battery.cells <= 1 ? 0.6 : (battery.cells == 2 ? 0.55 : 0.45))
        func basePitch(_ d: Double, _ blades: Int) -> Double { d * (ratio - (blades >= 3 ? 0.05 : 0)) }
        let d0 = motor.propInches, b0 = kind.propBlades
        let p0 = basePitch(d0, b0)
        guard customProp else { return PropModel(pitch: (basePitch(propInches, b0) * 2).rounded() / 2, thrust: 1, power: 1, speed: 1) }
        let d = propInches, b = propBladeCount
        func bladeLoad(_ n: Int) -> Double { n >= 3 ? 1.27 : 1 }
        var pitch = basePitch(d, b)
        let cap = 1.6 * bladeLoad(b0) * pow(d0, 4) * p0 / (bladeLoad(b) * pow(d, 4))
        if d > d0 { pitch = max(min(pitch, cap), 0.25 * d) }
        pitch = (pitch * 2).rounded() / 2
        let load = bladeLoad(b) * pow(d, 4) * pitch / (bladeLoad(b0) * pow(d0, 4) * p0)
        let power = load.squareRoot()
        let eff = (b >= 3 ? 0.94 : 1) / (b0 >= 3 ? 0.94 : 1)
        // An overloaded motor cannot give more than about 1.6 × its standard power (it sags, the ESC limits).
        let thrust = pow(min(power, 1.6), 2.0 / 3) * pow(d / d0, 2.0 / 3) * eff
        let rpm = pow(power / load, 1.0 / 3)
        return PropModel(pitch: pitch, thrust: thrust, power: power, speed: pitch / p0 * rpm)
    }
    /// Current at full throttle per motor (A): the standard prop draws about 80 % of the motor's maximum.
    var fullThrottleCurrent: Double { motor.maxCurrent * 0.8 * propModel.power }
    var propRecommendation: String {
        motor.propRecommendation(cells: battery.cells, pusher: isPusher, blades: propBladeCount, pair: isDual, diameter: propInches,
                                 pitch: customProp ? propModel.pitch : nil)
    }
    /// Gap kept between the prop (tips and blade faces) and any foam or structure.
    static let propClearance = 5.0
    /// Prop hub radius (matches the 3D propeller).
    var propHub: Double { motor.bellDiameter / 2 * 0.45 }
    /// Axial extent of the prop from its disc plane: towards the motor (blade pitch) and outward (hub + spinner).
    var propDepthIn: Double { 0.06 * propRadius + 0.5 }
    var propDepthOut: Double { max(0.06 * propRadius, 2.6 * propHub) }
    /// Jet: prop slot through the wing from the firewall plate to behind the spinner, with clearance all round.
    var jetSlotFront: Double { firewallZ - firewallThickness }
    var jetSlotRear: Double { jetPropZ + propDepthOut + AircraftConfig.propClearance }
    var jetSlotHalfWidth: Double { propRadius + AircraftConfig.propClearance + 1 }
    /// Height of the prop window in the jet's fuselage above (and below) the wing plate.
    var jetWindowHeight: Double { propRadius + AircraftConfig.propClearance + 1 }
    /// Lowest fuselage height that still closes the fuselage over the prop (window + frame top and bottom).
    var minFuselageHeight: Double {
        kind.isJet ? ((2 * (jetWindowHeight + DesignBuilder.jetFrameRim) + material.thickness) / 2).rounded(.up) * 2 : 0
    }
    /// Centre of the motor body.
    var motorZ: Double { isPusher ? firewallZ + motorLength / 2 : firewallZ - motorLength / 2 }
    /// z of the propeller disc (on the far side of the motor from the firewall).
    var propPlaneZ: Double { isPusher ? firewallZ + motorLength + 4 : firewallZ - motorLength - 4 }
    /// x positions of the motors.
    var motorXs: [Double] { isDual ? [-dualMotorX, dualMotorX] : [0] }
    /// Lateral position of the twin booms / fins.
    var boomX: Double { hStabSpan / 2 - 7 }
    /// Where the ailerons / elevons are along one half span (mm from the centre line) – as the builder lays them out:
    /// from near the root with one central servo and on the 3D Plane (else from about 30 % of the half span) to just
    /// short of the tip.
    /// Nil without them. (The flight simulator puts them on its wing strips there – in the prop's slipstream when
    /// they reach in close.)
    var aileronStations: ClosedRange<Double>? {
        guard hasAilerons || kind.isTailless else { return nil }
        let s = semiSpan
        var tip = 0.0
        if kind.hasTail {
            tip = max(0, wingTipRounding)
            if tailWinglets && wingletHeight > 5 { tip = min(tip, max(0, tipChord * 0.25 - 6)) }
            tip = min(tip, tipChord * 0.45)
        }
        let inner: Double, outer: Double
        if kind.isTailless {
            inner = motorNotchHalfWidth; outer = s - 5
        } else if kind.isJet {
            inner = max(jetSlotHalfWidth + 12, s * 0.35); outer = s - 8 - tip
        } else if kind.isTwinBoom {
            inner = max(s * 0.3, boomX + 14); outer = s - 10 - tip
        } else {
            let hw = fuselagePlateWidth / 2
            let central = hasAilerons && aileronServos == 1 && kind.allowsSingleAileronServo
            inner = hw + (central ? 3 : (kind == .aerobat ? 8 : max(8, s * 0.3 - hw))); outer = s - 10 - tip
        }
        return outer > inner + 1 ? inner...outer : nil
    }
    /// Width of the horizontal fuselage plate (cross fuselage) at the wing – about 8.5 % of the
    /// span, the proportion of the Crack Yak cross.
    var fuselagePlateWidth: Double { basePlateWidth + (kind.hasFuselage ? min(max(plateWidthExtra, 0), AircraftConfig.maxPlateWidthExtra) : 0) }
    /// Default plate width – the narrowest allowed (narrower would cost torsional stiffness).
    var basePlateWidth: Double {
        // The jet's horizontal fuselage is much wider (Ares: nose and tail plates are broad lifting bodies).
        kind.isJet ? min(max(wingspan * 0.14, 44), 84) : min(max(wingspan * 0.085, 30), 60)
    }
    /// Plate width where it meets the stabiliser.
    var plateTailWidth: Double { max(18, fuselagePlateWidth * 0.6) }
    /// Height of the upper fuselage half over the tail boom and of the lower half at its end.
    var boomTopHeight: Double { max(14, fuselageHeight * 0.24) }
    var lowerTailHeight: Double { max(10, fuselageHeight * 0.16) }
    /// Prop plane of the jet: the prop spins in a slot through the wing centre.
    var jetPropZ: Double { rootChord * 0.62 }
}

/// Turns an `AircraftConfig` into flat foam parts, cutouts and component positions.
///
/// Construction follows the multi-layer style of commercial flat-foam kits:
/// conventional aircraft get a full-length horizontal fuselage plate (with the stabiliser as
/// part of it) and upper/lower vertical fuselage halves glued on with tabs, wing halves keyed
/// into the plate sides and carbon spars top + bottom in the wing.
enum DesignBuilder {
    static let slotClearance = 0.15
    /// Elevator up-throw the rudder must clear: its lower edge rises behind the hinge by tan(35°) per mm.
    /// Foam left above / below the jet's prop window.
    static let jetFrameRim = 8.0

    /// World boxes of a servo's two mounting ears (see ServoClass.earLength): sideways-shaft servos (in a wing or
    /// through the webs) have the length along z, the width along y and the shaft along ±x; the standing aileron
    /// servo (shaft down) the width along x.
    static func servoEarBoxes(_ ctrl: ControlSurface, _ c: AircraftConfig) -> [(lo: SIMD3<Double>, hi: SIMD3<Double>)] {
        let s = c.servo, sz = s.size, p = ctrl.servoPosition
        let e = s.earLength, T = ServoClass.earThickness
        let zs: [(Double, Double)] = [(p.z + sz.l / 2, p.z + sz.l / 2 + e), (p.z - sz.l / 2 - e, p.z - sz.l / 2)]
        if ctrl.isDoubleArm {
            let y = p.y - s.earOffset
            return zs.map { ([p.x - sz.w / 2, y - T / 2, $0.0], [p.x + sz.w / 2, y + T / 2, $0.1]) }
        }
        let side: Double = ctrl.armPosition == .zero ? 1 : (ctrl.armPosition.x >= p.x ? 1 : -1)
        let x = p.x + side * s.earOffset
        return zs.map { ([x - T / 2, p.y - sz.w / 2, $0.0], [x + T / 2, p.y + sz.w / 2, $0.1]) }
    }


    static func build(_ input: AircraftConfig) -> Design {
        // (the jet's fuselage is kept taller than its prop window)
        var c = input
        c.fuselageHeight = max(c.fuselageHeight, c.minFuselageHeight)
        // (stab sweep within its limits: straight hinge, one-piece elevator)
        if c.kind.hasTail { c.hStabSweep = min(max(c.hStabSweep, c.stabSweepLimits.lowerBound), c.stabSweepLimits.upperBound) }
        var b = Builder(c: c)
        b.run()
        addPushrodSlots(&b.parts, controls: b.controls)
        var d = Design(config: c, parts: b.parts, components: b.components, controls: b.controls,
                       servoCutouts: b.servoCutouts, geometryIssues: b.issues, trussLength: b.trussLength)
        if c.struts != .off || (c.torsionTruss && c.offersTorsionTruss) { addStruts(&d) }
        return d
    }

    /// Carbon struts where the stiffness checks would fail (or always, on request): rods + printed anchors as
    /// components (mass / CG), anchor marks on the plans of the parts they are glued to.
    /// A pushrod that runs from one side of a flat part to the other (e.g. elevator servo above the plate, elevator
    /// horn underneath) passes through a slot: from where it enters the top face to where it leaves the bottom face
    /// (a shallow rod needs a long slot), plus 4 mm travel at each end, 3 mm wide.
    static func addPushrodSlots(_ parts: inout [Part], controls: [ControlSurface]) {
        for ctrl in controls {
            let a = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition, h = ctrl.hornPosition
            for pi in parts.indices {
                let part = parts[pi]
                for inst in part.instances where abs(inst.normal.y) > 0.9 {
                    let y0 = inst.origin.y, half = part.thickness / 2 + 0.5        // rod radius
                    guard (a.y - y0) * (h.y - y0) < 0, abs(a.y - y0) > half, abs(h.y - y0) > half else { continue }
                    func at(_ y: Double) -> Vec2 {
                        let p = a + (h - a) * ((y - a.y) / (h.y - a.y)), q = p - inst.origin
                        return Vec2(simd_dot(q, inst.u), simd_dot(q, inst.v))
                    }
                    let p0 = at(y0 + half), p1 = at(y0 - half)
                    guard Poly.contains(part.outline, (p0 + p1) / 2) else { continue }
                    let dir = simd_length(p1 - p0) > 1e-6 ? simd_normalize(p1 - p0) : simd_normalize(Vec2(simd_dot(h - a, inst.u), simd_dot(h - a, inst.v)))
                    let w = Vec2(-dir.y, dir.x)
                    let s0 = p0 - dir * 4, s1 = p1 + dir * 4
                    let slot = [s0 - w * 1.5, s1 - w * 1.5, s1 + w * 1.5, s0 + w * 1.5]
                    parts[pi].holes.append(Hole(kind: .slot, polygon: Poly.ccw(slot), note: "pushrod"))
                }
            }
        }
    }

    static func addStruts(_ d: inout Design) {
        let loads = Analysis.massAndStall(d)
        let struts = StrutPlanner.plan(d, totalMass: loads.mass, stallSpeed: loads.stall)
        guard !struts.isEmpty else { return }
        var full = d
        apply(struts, to: &full)
        // Fin struts add weight far aft: leave them out if the battery could no longer reach the CG with them.
        if struts.contains(where: { $0.group == .fin }), !Analysis(design: full).cgReachable {
            var lean = d
            apply(struts.filter { $0.group != .fin }, to: &lean)
            if Analysis(design: lean).cgReachable {
                lean.strutNotes.append("Fin struts left out – their weight at the tail would put the CG beyond the battery's reach.")
                d = lean
                return
            }
        }
        d = full
    }

    private static func apply(_ struts: [Strut], to d: inout Design) {
        d.struts = struts
        var marked = Set<String>()
        for st in struts {
            d.components.append(MassItem(name: "Carbon strut \(st.label) – \(st.rod.name)", mass: st.rodMass,
                                         position: (st.a.rodEnd + st.b.rodEnd) / 2, category: "Hardware"))
            if st.group == .torsion {
                // Torsion truss: rod ends glued straight into the foam – glue only, and a small mark at each end.
                d.components.append(MassItem(name: "Glue – torsion truss \(st.label)", mass: 0.1, position: (st.a.rodEnd + st.b.rodEnd) / 2, category: "Hardware"))
                for end in [st.a, st.b] {
                    let key = "\(end.partIndex)-\(Int((end.plan.x * 2).rounded()))-\(Int((end.plan.y * 2).rounded()))"
                    guard marked.insert(key).inserted else { continue }
                    let face = abs(end.normal.x) > 0.9 ? " L+R" : " under"
                    d.parts[end.partIndex].features.append(.strutAnchor(end.plan, end.planDir, Vec2(3, 3), String(st.label.dropLast()) + face))
                }
                continue
            }
            for end in [st.a, st.b] {
                let base = String(st.label.dropLast())
                if let sd = end.saddle {
                    // One-piece saddle for the pair: its mass once (with the right-hand strut), its outline on the web plan.
                    if st.label.hasSuffix("R"), let left = struts.first(where: { $0.label == base + "L" }) {
                        let mesh = PrintedParts.strutSaddle(right: end, left: left.b, dia: st.diameter)
                        d.components.append(MassItem(name: "Strut saddle \(base)", mass: mesh.volume * 1.24e-3 * 0.85,
                                                     position: sd.center, category: "Printed"))
                        d.parts[sd.partIndex].features.append(.strutSaddle(sd.plan, base))
                        d.parts[sd.partIndex].features.append(.strutAnchor(end.plan, end.planDir, end.padSize, base + " L+R"))
                    }
                    continue
                }
                if let sp = end.shared {
                    // Double anchor: its mass once (with the first strut of the pair), one outline on the wing plan.
                    if st.label == sp.labels[0], let other = struts.first(where: { $0.label == sp.labels[1] }) {
                        let mesh = PrintedParts.strutDoubleAnchor(end, other.a, dia1: st.diameter, dia2: other.diameter, design: d)
                        d.components.append(MassItem(name: "Double strut anchor \(sp.labels.joined(separator: " + "))", mass: mesh.volume * 1.24e-3 * 0.85,
                                                     position: (end.surface + other.a.surface) / 2 + end.normal * 2, category: "Printed"))
                        // Mirrored halves share one outline (S1+S2); a one-piece wing gets one per side (S1R+S2R).
                        let mirrored = d.parts[sp.partIndex].mirroredPair
                        let names = (mirrored ? sp.labels.map { String($0.dropLast()) } : sp.labels).joined(separator: "+")
                        let key = "plate-\(sp.partIndex)-\(names)"
                        if marked.insert(key).inserted {
                            d.parts[sp.partIndex].features.append(.strutPlate(sp.plan, "\(names) one anchor"))
                        }
                    }
                } else {
                    let mesh = PrintedParts.strutAnchor(dia: st.diameter, elevation: end.elevation)
                    d.components.append(MassItem(name: "Strut anchor \(st.label)", mass: mesh.volume * 1.24e-3 * 0.85,
                                                 position: end.surface + end.normal * 2, category: "Printed"))
                }
                // One mark per spot on a plan: mirrored halves and both faces of a web share it.
                let key = "\(end.partIndex)-\(Int((end.plan.x * 2).rounded()))-\(Int((end.plan.y * 2).rounded()))"
                guard marked.insert(key).inserted else { continue }
                let part = d.parts[end.partIndex]
                let shared = part.mirroredPair || abs(end.normal.x) > 0.9
                // Which face: plans show horizontal parts from above, webs from the side (anchors on both faces).
                let face = abs(end.normal.x) > 0.9 ? " L+R" : (end.normal.y < 0 ? " under" : " top")
                d.parts[end.partIndex].features.append(.strutAnchor(end.plan, end.planDir, end.padSize, (shared ? base : st.label) + face))
            }
        }
    }

    private struct Builder {
        let c: AircraftConfig
        var parts: [Part] = []
        var components: [MassItem] = []
        var controls: [ControlSurface] = []
        var servoCutouts: [(part: String, rect: [Vec2])] = []
        var issues: [String] = []
        var batteryPos = SIMD3<Double>.zero
        /// Total length of carbon truss strips (mm) for the BOM.
        var trussLength = 0.0

        var t: Double { c.material.thickness }
        /// ESC size (l × w × h) – bigger motors need bigger ESCs.
        var escSize: SIMD3<Double> { c.motor.escMass > 4 ? [24, 13, 5] : [18, 10, 4] }
        /// ESC position for the motor at lateral position x: taped where the motor leads reach it, always on the
        /// visible side (top of the wing, or the right fuselage side next to the battery).
        func escPosition(motorX x: Double) -> SIMD3<Double> {
            let e = escSize
            let side = c.kind.isTailless || c.isDual ? 0 : t * Double(c.fuselageType.webLayers) / 2 + e.z / 2   // right web face
            if c.isDual { return [x * 0.8, t / 2 + e.z / 2, c.rootChord * 0.48] }                        // on the wing behind its motor, aft of the spar
            // Tailless: forward on top of the wing, left of the battery – keeps the CG reachable.
            if c.kind.isTailless { return [-(c.battery.size.w / 2 + e.y / 2 + 6), t / 2 + e.z / 2, c.rootChord * 0.25] }
            if c.kind.isTwinBoom { return [side, t / 2 + e.y / 2 + 2, c.rootChord * 0.55] }              // pod top, right side
            // Jet: on the canopy side ahead of the motor-mount clamp (the jaws reach forward from the firewall).
            if c.kind.isJet { return [side, t / 2 + e.y / 2 + 2, c.jetSlotFront - PrintedParts.mountJaw - e.x / 2 - 4] }
            return [side, t / 2 + e.y / 2 + 2, -c.noseLength * 0.55 + e.x / 2]                          // upper nose, right side
        }
        /// Receiver on the left side of the upper fuselage behind the servos (on top of the wing on tailless).
        var receiverPosition: SIMD3<Double> {
            if c.kind.isTailless { return [c.battery.size.w / 2 + 11, t / 2 + 1.5, c.rootChord * 0.22] }
            if c.kind.isNutBall { return [-(t / 2 + 2), t / 2 + 12, c.rootChord * 0.32] }
            return [-(t / 2 + 2), t / 2 + 12, c.rootChord * (c.kind.isJet ? 0.45 : 0.72)]
        }
        var s: Double { c.semiSpan }
        var propRadius: Double { c.propRadius }

        /// Wing-tip rounding radius actually used: tailed planes only; with tip winglets it stays clear of their tabs.
        var wingTipRadius: Double {
            guard c.kind.hasTail else { return 0 }
            var r = max(0, c.wingTipRounding)
            if c.tailWinglets && c.wingletHeight > 5 { r = min(r, max(0, c.tipChord * 0.25 - 6)) }
            return min(r, c.tipChord * 0.45)
        }
        var finTopRadius: Double { c.kind.hasTail || c.kind.isNutBall ? max(0, c.finTopRounding) : 0 }
        var stabTipRadius: Double { c.kind.hasTail && !c.kind.isTwinBoom ? max(0, c.stabTipRounding) : 0 }
        /// Rounds the given corners of several polygons that share them.
        func rounded(_ polys: [[Vec2]], corners: [Vec2], radius r: Double) -> [[Vec2]] {
            var p = polys
            for corner in corners { Poly.filletShared(&p, at: corner, radius: r) }
            return p
        }

        // Single central aileron servo (RC Factory cartoon style): it hangs upside down in the LOWER fuselage half
        // under the wing (shaft down), a double-ended arm below it drives both ailerons with one short pushrod each
        // to a horn under each aileron. The upper half keeps the elevator and rudder servos.
        var centralAileron: Bool { c.hasAilerons && c.aileronServos == 1 && c.kind.allowsSingleAileronServo }
        var ailServoU: Double { c.centralAileronServoU }
        var ailShaftU: Double { ailServoU + c.servo.size.l / 2 - 5 }
        /// Half length of the double arm (hole to hub) – longer for bigger servos.
        var ailArm: Double { c.servo.doubleArmHalf }
        /// Pushrod end under the double arm (case bottom − gap − arm − rod radius).
        var ailArmY: Double { -c.servo.size.h / 2 - ServoClass.rodOffset }
        var ailServoCenter: SIMD3<Double> { [0, 0, ailServoU] }
        /// Lower fuselage half (below the plate): flush notch for the lower half of the servo, and a deeper one only
        /// where the double arm crosses the web – around the hub, ±its swing (±50°) through the web, down to 1.5 mm
        /// below the arm. (u0, u1, depth below the plate) each.
        var ailWindow: (u0: Double, u1: Double, h: Double) {
            let sv = c.servo.size
            return (ailServoU - sv.l / 2 - 0.2, ailServoU + sv.l / 2 + 0.2, sv.h / 2 + 0.2 - t / 2)
        }
        var ailArmWindow: (u0: Double, u1: Double, h: Double) {
            let th = 50.0 * .pi / 180, tw = t * Double(c.fuselageType.webLayers)
            let along = ServoClass.armWidth / 2 / cos(th) + (tw / 2 + 1) * tan(th) + 1
            let depth = c.servo.size.h / 2 + ServoClass.armGap + ServoClass.armThickness + 1.5 - t / 2
            return (ailShaftU - along, ailShaftU + along, depth)
        }

        var wing: TaperedPanel {
            TaperedPanel(rootChord: c.rootChord, tipChord: c.tipChord, sweep: c.sweep, semiSpan: s)
        }

        mutating func run() {
            if c.kind.isTailless { buildTailless() }
            else if c.kind.isTwinBoom { buildTwinBoom() }
            else if c.kind.isJet { buildJet() }
            else if c.kind.isNutBall { buildNutBall() }
            else { buildConventional() }
            if c.hasSparJoiner { addSparJoinerPocket() }
            addServoEars()
            addElectronics()
            addComponentZones()
        }

        /// Notches for the servo ears in every foam part they pass through (the ear footprint on that part's plan,
        /// trimmed to the part), and a geometry issue where an ear would cut into a spar groove, another cutout or a
        /// strut anchor.
        mutating func addServoEars() {
            var seen = Set<String>()
            for ctrl in controls where seen.insert(ctrl.servoID).inserted {
                for box in DesignBuilder.servoEarBoxes(ctrl, c) {
                    for pi in parts.indices {
                        let part = parts[pi]
                        for inst in part.instances {
                            let n = inst.normal
                            // Box corners in the part's plan coordinates (axes are axis-aligned).
                            let corners = (0..<8).map { k -> SIMD3<Double> in
                                let q = SIMD3<Double>(k & 1 == 0 ? box.lo.x : box.hi.x, k & 2 == 0 ? box.lo.y : box.hi.y, k & 4 == 0 ? box.lo.z : box.hi.z) - inst.origin
                                return [simd_dot(q, inst.u), simd_dot(q, inst.v), simd_dot(q, n)]
                            }
                            let zlo = corners.map(\.z).min()!, zhi = corners.map(\.z).max()!
                            guard zhi > -part.thickness / 2 + 0.05, zlo < part.thickness / 2 - 0.05 else { continue }
                            let rect = Poly.rect(minU: corners.map(\.x).min()!, maxU: corners.map(\.x).max()!,
                                                 minV: corners.map(\.y).min()!, maxV: corners.map(\.y).max()!)
                            let cut = Poly.clip(part.outline, to: rect)
                            guard cut.count >= 3, Poly.area(cut) > 0.3 else { continue }
                            // Collisions: spar groove, other cutouts (not this servo's own), strut anchors.
                            for f in part.features {
                                if case let .rod(a, b, dia) = f, Self.bandOverlaps(Poly.inset(cut, by: 0.3), a, b, halfWidth: dia / 2 + 0.3) {
                                    issues.append("The \(ctrl.servoID.lowercased()) servo's mounting ear cuts into the spar groove – use a smaller servo or move the servo.")
                                }
                                if case let .strutAnchor(cc, dd, size, label) = f {
                                    let w = Vec2(-dd.y, dd.x), hx = dd * size.x / 2, hy = w * size.y / 2
                                    if Poly.overlaps(cut, [cc - hx - hy, cc + hx - hy, cc + hx + hy, cc - hx + hy]) {
                                        issues.append("The \(ctrl.servoID.lowercased()) servo's mounting ear is under strut anchor \(label).")
                                    }
                                }
                            }
                            // (shrunk a little: the ear starts right at the end of its own servo's cutout)
                            let core = Poly.inset(cut, by: 0.3)
                            for h in part.holes where h.note != "servo ear" && core.count >= 3 && Poly.overlaps(h.polygon, core) {
                                let what = h.kind == .hornSlot ? "a horn slot" : (h.kind == .servo ? "the \(h.note.lowercased()) cutout" : "a slot")
                                issues.append("The \(ctrl.servoID.lowercased()) servo's mounting ear cuts into \(what) – move the servo or pick a smaller one.")
                            }
                            if !parts[pi].holes.contains(where: { $0.note == "servo ear" && Poly.overlaps($0.polygon, cut) }) {
                                parts[pi].holes.append(Hole(kind: .servo, polygon: cut, note: "servo ear"))
                            }
                        }
                    }
                }
            }
        }
        /// Does polygon `p` reach into the band of half width `hw` around the segment a–b?
        static func bandOverlaps(_ p: [Vec2], _ a: Vec2, _ b: Vec2, halfWidth hw: Double) -> Bool {
            let d = simd_normalize(b - a), n = Vec2(-d.y, d.x)
            return Poly.overlaps(p, [a - n * hw, b - n * hw, b + n * hw, a + n * hw])
        }

        /// Dashed placement zones on the plans for the ESC and receiver (taped to a foam face): the footprint of the
        /// component on the face of the part it sits against, in that part's plan coordinates (once per part).
        mutating func addComponentZones() {
            let e = escSize
            for item in components {
                let size: SIMD3<Double>
                let label: String
                if item.name.hasPrefix("ESC") {
                    size = (c.isDual || c.kind.isTailless) ? [e.y, e.z, e.x] : [e.z, e.y, e.x]
                    label = "ESC"
                } else if item.name.hasPrefix("Receiver") {
                    size = c.kind.isTailless ? [10, 3, 14] : [3, 10, 14]
                    label = "RX"
                } else { continue }
                let p = item.position
                var best: (part: Int, rect: [Vec2], gap: Double)?
                for (pi, part) in parts.enumerated() {
                    for inst in part.instances {
                        let n = inst.normal
                        let rel = p - inst.origin
                        let x = simd_dot(rel, inst.u), y = simd_dot(rel, inst.v), z = simd_dot(rel, n)
                        // Half thickness of the component across this part's face.
                        let across = abs(n.x) * size.x / 2 + abs(n.y) * size.y / 2 + abs(n.z) * size.z / 2
                        let gap = abs(abs(z) - part.thickness / 2 - across)
                        guard gap < 3, Poly.contains(part.outline, Vec2(x, y)) else { continue }
                        let hu = abs(inst.u.x) * size.x / 2 + abs(inst.u.y) * size.y / 2 + abs(inst.u.z) * size.z / 2
                        let hv = abs(inst.v.x) * size.x / 2 + abs(inst.v.y) * size.y / 2 + abs(inst.v.z) * size.z / 2
                        let rect = Poly.rect(center: Vec2(x, y), size: Vec2(2 * hu, 2 * hv))
                        if best == nil || gap < best!.gap { best = (pi, rect, gap) }
                    }
                }
                guard let b = best else { continue }
                let already = parts[b.part].features.contains {
                    if case let .zone(poly, l) = $0 { return l == label && simd_distance(Poly.centroid(poly), Poly.centroid(b.rect)) < 1 }
                    return false
                }
                if !already { parts[b.part].features.append(.zone(b.rect, label)) }
            }
        }

        /// A tab station on the centre line moved just clear of the spar joiner pocket at the wing root (tabs go through
        /// slots on the centre line, where the joiner sits).
        func clearOfJoiner(_ u: Double) -> Double {
            guard c.hasSparJoiner else { return u }
            let h = PrintedParts.joinerPocketHalfWidth(c) / cos(atan(abs(c.sparSlope))) + abs(c.sparSlope) * 4 + 1
            let lo = c.sparRootU - h - 5, hi = c.sparRootU + h + 5
            guard u > lo && u < hi else { return u }
            return u - lo < hi - u ? lo : hi
        }

        /// Pocket for the printed spar joiner on the plan of the part that carries the wing root (one-piece wing or
        /// fuselage plate) and, where the arms reach that far, on the wing halves.
        mutating func addSparJoinerPocket() {
            let u0 = c.sparRootU, k = c.sparSlope
            let half = PrintedParts.joinerPocketHalfWidth(c)
            let A = PrintedParts.joinerArmSpan(c)
            let depth = c.sparJoinerFloorInside ? c.sparSpec.widthMM + PrintedParts.joinerFloor : c.sparSpec.widthMM
            let label = "SPAR JOINER POCKET \(String(format: "%.1f", depth)) MM DEEP"
            let toPlan = { (p: Vec2) in Vec2(u0 + p.y, p.x) }
            if let i = parts.firstIndex(where: { $0.name == "Wing" && $0.role == .wing }) {
                let pocket = PrintedParts.strip([Vec2(-A, k * A), Vec2(0, 0), Vec2(A, k * A)], from: -half, to: half).map(toPlan)
                parts[i].features.append(.zone(pocket, label))
                for h in parts[i].holes {
                    if Poly.overlaps(h.polygon, pocket) {
                        issues.append("The spar joiner pocket cuts into the \(h.note.isEmpty ? (h.kind == .slot ? "tab slot" : "cutout") : h.note) at the wing root – move the spar or the cutout.")
                    }
                }
            } else if let i = parts.firstIndex(where: { $0.name == "Fuselage plate" }) {
                // Across the plate (V through the centre) …
                let hw = c.fuselagePlateWidth / 2
                let a = min(A, hw)
                let pocket = PrintedParts.strip([Vec2(-a, k * a), Vec2(0, 0), Vec2(a, k * a)], from: -half, to: half).map(toPlan)
                parts[i].features.append(.zone(pocket, label))
                for h in parts[i].holes where Poly.overlaps(h.polygon, pocket) {
                    issues.append("The spar joiner pocket cuts into the \(h.note.isEmpty ? "cutout" : h.note) in the fuselage plate – pick a smaller servo or a thinner spar.")
                }
                // … and on into each wing half (its plan starts at the plate edge).
                if A > hw + 1, let j = parts.firstIndex(where: { $0.name == "Wing half" }) {
                    let seg = PrintedParts.strip([Vec2(hw, k * hw), Vec2(A, k * A)], from: -half, to: half).map { Vec2(u0 + $0.y, $0.x - hw) }
                    parts[j].features.append(.zone(seg, "JOINER POCKET"))
                }
            }
        }

        /// Battery box (centre ± half size) for a battery hung on the side of a web (x = side face) or lying on top.
        func batteryBox(at p: SIMD3<Double>) -> (lo: SIMD3<Double>, hi: SIMD3<Double>) {
            let b = c.battery.size
            // Drawn 1.2 mm off its anchor point (the printed tray between foam and battery).
            let q = abs(p.x) > 0.1 ? p + [p.x > 0 ? 1.2 : -1.2, 0, 0] : p + [0, 1.2, 0]
            let half: SIMD3<Double> = abs(p.x) > 0.1 ? [b.h / 2, b.w / 2, b.l / 2] : [b.w / 2, b.h / 2, b.l / 2]
            return (q - half, q + half)
        }
        /// Pushrods (servo arm tip → horn) passing through the battery box grown by `margin`.
        func pushrodsThroughBattery(at p: SIMD3<Double>, margin: Double = 1.5) -> [String] {
            let box = batteryBox(at: p)
            let lo = box.lo - margin, hi = box.hi + margin
            return controls.compactMap { ctrl -> String? in
                let a = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition, b = ctrl.hornPosition
                let n = max(2, Int(simd_distance(a, b) / 0.5))
                for i in 0...n {
                    let q = a + (b - a) * (Double(i) / Double(n))
                    if q.x > lo.x && q.x < hi.x && q.y > lo.y && q.y < hi.y && q.z > lo.z && q.z < hi.z { return ctrl.name }
                }
                return nil
            }
        }
        /// A battery hung on one side of the web moves to the other side when a pushrod would run through it (the
        /// check runs on every build, so it follows the battery as it is moved to balance).
        mutating func placeBatteryClearOfPushrods() {
            guard abs(batteryPos.x) > 0.1 else { return }
            let hit = pushrodsThroughBattery(at: batteryPos)
            guard !hit.isEmpty else { return }
            let other: SIMD3<Double> = [-batteryPos.x, batteryPos.y, batteryPos.z]
            let hitOther = pushrodsThroughBattery(at: other)
            if hitOther.isEmpty { batteryPos = other }
            else { issues.append("The battery is in the way of the \(hit.joined(separator: " / ").lowercased()) pushrod on both sides – move the battery (or the servo) fore or aft.") }
        }

        // MARK: Helpers

        /// Outline of two overlapping axis-aligned rectangles (servo cutout + arm pocket), counter-clockwise.
        static func unionRects(_ a: [Vec2], _ b: [Vec2]) -> [Vec2] {
            let ba = Poly.bounds(a), bb = Poly.bounds(b)
            let xs = Array(Set([ba.min.x, ba.max.x, bb.min.x, bb.max.x])).sorted()
            var low: [Vec2] = [], high: [Vec2] = []
            for i in 0..<(xs.count - 1) {
                let m = (xs[i] + xs[i + 1]) / 2
                var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
                for r in [ba, bb] where m > r.min.x && m < r.max.x { lo = min(lo, r.min.y); hi = max(hi, r.max.y) }
                guard lo < hi else { continue }
                low += [Vec2(xs[i], lo), Vec2(xs[i + 1], lo)]; high += [Vec2(xs[i], hi), Vec2(xs[i + 1], hi)]
            }
            return Poly.ccw(Poly.cleaned(low + high.reversed()))
        }

        /// Servo cutout, flush (+0.2 mm each side). `arm`: the shaft sits in this sheet (servo lying flat in a wing, or
        /// centred on the plate) – a pocket on the shaft side (plan side ±1) lets the arm's hub and swing clear the foam.
        mutating func servoCut(_ name: String, center: Vec2, size: Vec2, in region: [Vec2], avoid: [[Vec2]] = [],
                               arm: (side: Double, sheet: Double)? = nil) -> Hole {
            var r = Poly.rect(center: center, size: size + Vec2(0.4, 0.4))
            if let arm {
                let pocket = armPocket(cutCenter: center, cutHalfAcross: size.y / 2 + 0.2, side: arm.side,
                                       hubU: center.x + c.servo.size.l / 2 - 5, sheet: arm.sheet)
                r = Self.unionRects(r, pocket)
            }
            if !Poly.containsAll(region, r) || avoid.contains(where: { Poly.overlaps($0, r) }) {
                issues.append("Servo cutout '\(name)' does not fit inside the part – increase chord/height or pick a smaller servo.")
            }
            servoCutouts.append((name, r))
            return Hole(kind: .servo, polygon: r, note: name)
        }

        /// Servo arm tip. One mounting convention everywhere: servo length L fore-aft, width W vertical,
        /// height H sideways – i.e. the output shaft (which leaves the L×W top face) points sideways (±x).
        /// In the wing that means the servo lies FLAT (L×H cutout, only W crosses the thin foam); in a
        /// vertical fuselage web it passes through the web (L×W cutout) like on profile planes.
        /// The arm points up at neutral, so the pushrod runs straight fore-aft to a horn at the same x.
        /// Returns the pushrod end at the arm: arm length from the shaft, on the arm's outer side.
        /// Plate opening for an elevator / rudder servo centred on a horizontal part (through the vertical web): flush
        /// around the servo, with a pocket on the shaft side for the arm's hub at plate level. `tw` = web thickness.
        func centredServoOpening(_ u: Double, side: Double, tw: Double) -> [Vec2] {
            let sv = c.servo.size, half = c.centralWebServoHalfOpening
            let body = Poly.rect(center: Vec2(u, 0), size: Vec2(2 * half, 2 * max(sv.h / 2 + 0.2, tw / 2 + 0.2)))
            return Self.unionRects(body, armPocket(cutCenter: Vec2(u, 0), cutHalfAcross: sv.h / 2 + 0.2, side: side,
                                                   hubU: u + sv.l / 2 - 5, sheet: t))
        }
        /// Notch profile along the plate edge (v = 0) of an upper (sign +1) or lower (sign −1) web for servos centred on
        /// the plate at the stations `us`, in increasing u.
        func centredServoNotches(_ us: [Double], sign: Double) -> [Vec2] {
            let sv = c.servo.size
            let depth = sv.w / 2 + 0.3 - t / 2
            guard depth > 0 else { return [] }
            return us.sorted().flatMap { u -> [Vec2] in
                let u0 = u - sv.l / 2 - 0.2, u1 = u + sv.l / 2 + 0.2
                return [Vec2(u0, 0), Vec2(u0, sign * depth), Vec2(u1, sign * depth), Vec2(u1, 0)]
            }
        }
        /// Span stations of an aileron (from the half-span station `a0` out to `a1`). Where the wing is too short for
        /// one (e.g. booms far out on a small wing), the design is flagged and a short aileron at the tip keeps the
        /// geometry valid instead of an inverted range.
        mutating func aileronSpan(from a0: Double, to a1: Double, what: String) -> ClosedRange<Double> {
            if a1 - a0 < 20 {
                issues.append("No room for the ailerons between the \(what) and the wing tip – increase the wingspan\(what == "booms" ? " or reduce the stab span" : "").")
                let hi = max(a1, 12)
                return max(2, hi - 20)...hi
            }
            return a0...a1
        }
        func armTip(_ center: SIMD3<Double>, side: Double, down: Bool = false) -> SIMD3<Double> {
            let sv = c.servo.size
            return center + [side * (sv.h / 2 + ServoClass.rodOffset), (down ? -1 : 1) * c.servo.armLength, sv.l / 2 - 5]
        }
        /// Sideways offset of the pushrod (and horn) from the servo centre so the pushrod is straight.
        var armOffset: Double { c.servo.size.h / 2 + ServoClass.rodOffset }
        /// Pocket beside a servo whose shaft sits in a foam sheet (mid-plane): the arm's hub and its swing through the
        /// sheet (±50°) need room. Plan rectangle on the shaft side: across from the cutout edge to beyond the arm,
        /// along the sheet ± its swing where it crosses the sheet's thickness.
        func armPocket(cutCenter: Vec2, cutHalfAcross: Double, side: Double, hubU: Double, sheet: Double) -> [Vec2] {
            let along = ServoClass.armSwingAlong(sheet: sheet)
            let a0 = cutHalfAcross - 0.5, a1 = c.servo.size.h / 2 + ServoClass.armGap + ServoClass.armThickness + 1.5
            let v0 = cutCenter.y + side * a0, v1 = cutCenter.y + side * a1
            return Poly.rect(minU: hubU - along, maxU: hubU + along, minV: min(v0, v1), maxV: max(v0, v1))
        }
        /// Wing cutout (lying flat) and fuselage-web cutout sizes in plan coordinates (u, v).
        var wingServoCut: Vec2 { Vec2(c.servo.size.l, c.servo.size.h) }
        var webServoCut: Vec2 { Vec2(c.servo.size.l, c.servo.size.w) }

        /// Bottom edge of the fin / rudder over the one-piece elevator, in web coordinates (v above the plate top,
        /// Δz behind the elevator hinge). The elevator is hinged with tape on top, so it turns about the top-surface
        /// line: its top face rises to Δz·tanθ, its trailing edge to ce·sinθ. The edge stays above that for every
        /// angle up to the type's throw + 5°, plus the gap `rg`.
        struct FinCut {
            var rg: Double, tanT: Double, cap: Double
            func v(_ dz: Double) -> Double { rg + min(max(dz, 0) * tanT, cap) }
            /// Edge points (Δz, v) from d0 to d1, with the knee where the line turns flat.
            func edge(_ d0: Double, _ d1: Double) -> [Vec2] {
                let knee = cap / tanT
                return ([d0] + (knee > d0 && knee < d1 ? [knee] : []) + [d1]).map { Vec2($0, v($0)) }
            }
        }
        func finCut(elevChord ce: Double, rg: Double) -> FinCut {
            let T = (c.kind.maxSurfaceThrow + StrutPlanner.throwMargin) * .pi / 180
            return FinCut(rg: rg, tanT: tan(T), cap: ce * sin(T))
        }

        /// Height of the rudder horn above the plate top (its slot on the web): the horn, swung with the rudder through
        /// its throw + 5° about the hinge at uH, stays above the highest point the up-going elevator reaches within
        /// the horn's reach aft of the hinge (tape hinge on top: min(Δz·tanθ, ce·sinθ)), with 2 mm clearance.
        func rudderHornV(uH: Double, elevChord ce: Double, tw: Double) -> Double {
            let T = (c.kind.maxSurfaceThrow + StrutPlanner.throwMargin) * .pi / 180, clear = 2.0
            let a = SIMD3<Double>(-1, 0, 0), ex = SIMD3<Double>(0, 0, 1), ey = simd_cross(a, ex)
            let o = SIMD3<Double>(-(tw / 2 + 8), t / 2 + 14, uH + 2) - a * 9 + [0, 0, 4]
            let pts = PrintedParts.controlHorn(foam: t).triangles.flatMap { [$0.0, $0.1, $0.2] }.map { o + ex * $0.x + ey * $0.y + a * $0.z }
            var reach = 0.0
            for k in -6...6 {
                let q = simd_quatd(angle: T * Double(k) / 6, axis: [0, 1, 0])
                for p in pts { reach = max(reach, (q.act(p - [0, 0, uH]) + [0, 0, uH]).z - uH) }
            }
            let elevTop = min(reach * tan(T), ce * sin(T))
            // The horn reaches 3 mm below its slot (flange), so its slot sits elevTop + 3 + clearance up.
            return (max(14, elevTop + 3 + clear) * 2).rounded(.up) / 2
        }

        /// `under`: the horn is glued in from the underside (elevator – clear of the rudder above it).
        func hornSlot(at p: Vec2, alongU: Bool = true, under: Bool = false) -> Hole {
            let size = alongU ? Vec2(10, 1.6) : Vec2(1.6, 10)
            return Hole(kind: .hornSlot, polygon: Poly.rect(center: p, size: size), note: under ? "horn under" : "horn")
        }

        func slot(minU: Double, maxU: Double, minV: Double, maxV: Double) -> Hole {
            Hole(kind: .slot, polygon: Poly.rect(minU: minU - slotClearance, maxU: maxU + slotClearance,
                                                 minV: minV - slotClearance, maxV: maxV + slotClearance))
        }

        /// Slots along the centre line (v = 0) for tabs of a vertical part standing on a horizontal one.
        func centreSlots(_ us: [Double], width: Double = 10) -> [Hole] {
            us.map { slot(minU: $0 - width / 2, maxU: $0 + width / 2, minV: -t / 2, maxV: t / 2) }
        }

        func regions(_ out: TaperedPanel.Output) -> [Region] {
            [Region(polygon: out.main, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) }
        }

        /// Clear gap between the spar groove and the front edge of a servo next to it (mm) – measured from the servo
        /// FRAME's outer edge (the visible / glued edge), i.e. cutout edge + frame flange.
        static let servoSparGap = 3.0
        /// Wing servos (ailerons, elevons, Twin Boom elevator) sit as far forward as possible – front edge about
        /// `servoSparGap` behind the spar groove (30 % chord line, also used as reference without a spar) – which
        /// moves the CG forward and lets the battery sit further aft. Never further aft than 8 mm ahead of the hinge.
        /// Spar line (30 % chord) at its most aft point across a flat wing servo's spanwise width at station `v`:
        /// on swept / tapered wings the spar runs diagonally, so the servo's outboard corner is the closest one.
        func sparAcrossServo(_ p: TaperedPanel, _ v: Double) -> Double {
            // Across the cutout and the arm pocket beside it (on either side).
            let h = c.servo.size.h / 2 + ServoClass.armGap + ServoClass.armThickness + 1.5
            func spar(_ x: Double) -> Double { p.le(x) + 0.3 * p.chord(x) }
            return max(spar(v - h), spar(v + h))
        }
        mutating func wingServoU(hingeU: Double, sparU: Double) -> Double {
            // Half length including the mounting ears (they cross the foam at both ends of the cutout).
            let l = c.servo.size.l + 2 * c.servo.earLength
            let sparHalf = c.sparEnabled ? c.sparSpec.widthMM / 2 : 1.5
            // cutout = servo + 0.4 mm (glued in flush, no frame)
            let forward = sparU + sparHalf + Self.servoSparGap + 0.2 + l / 2
            let mostAft = hingeU - 8 - l / 2
            // No room between the spar groove and 8 mm ahead of the hinge: the cutout would reach the groove.
            if c.sparEnabled && mostAft < sparU + sparHalf + 1.0 + 0.2 + l / 2,
               !issues.contains(where: { $0.hasPrefix("The wing servos do not fit") }) {
                issues.append("The wing servos do not fit between the spar and the hinge – they would cut into the spar groove. Use a smaller servo, a larger chord or smaller control surfaces.")
            }
            return min(mostAft, forward)
        }

        /// Carbon rod spar on the 30 % chord line, in a groove under the wing.
        func sparFeatures(_ w: TaperedPanel, from v0: Double, to v1: Double) -> [Feature] {
            guard c.sparEnabled else { return [] }
            return [.rod(Vec2(w.le(v0) + 0.3 * w.chord(v0), v0), Vec2(w.le(v1) + 0.3 * w.chord(v1), v1), c.sparSpec.widthMM)]
        }

        /// Fuselage carbon truss was removed on request – only the wing spar is carbon.
        /// Kept as a no-op so the call sites stay readable.
        func truss(from u0: Double, to u1: Double, low: (Double) -> Double, high: (Double) -> Double) -> [Feature] { [] }

        func finOutline(chord fc: Double, height h: Double, rudderFrac: Double = 0) -> (outline: [Vec2], main: [Vec2], rudder: [Vec2]?, tabs: [Double]) {
            let topLE = min(h * 0.55 + fc * 0.25, fc * 0.75 + h * 0.2)
            var fin = [Vec2(0, 0), Vec2(fc, 0), Vec2(fc + h * 0.2, h), Vec2(topLE, h)]
            var main = fin
            var rudder: [Vec2]?
            if rudderFrac > 0 {
                let hu = fc * (1 - rudderFrac)
                fin = [Vec2(0, 0), Vec2(fc, 0), Vec2(fc, h), Vec2(min(topLE, hu - 2), h)]
                main = [Vec2(0, 0), Vec2(hu, 0), Vec2(hu, h), Vec2(min(topLE, hu - 2), h)]
                rudder = [Vec2(hu, 0), Vec2(fc, 0), Vec2(fc, h), Vec2(hu, h)]
            }
            let tabs = [fc * 0.22, fc * (rudderFrac > 0 ? 0.48 : 0.62)]
            for tu in tabs {
                fin = Poly.insertTab(fin, at: Vec2(tu, 0), width: 8, height: t)
                main = Poly.insertTab(main, at: Vec2(tu, 0), width: 8, height: t)
            }
            return (fin, main, rudder, tabs)
        }

        /// End-plate fin glued to the side of a tip edge (winglet / twin-boom fin): reaches above and a little
        /// below the surface, with two slots at the surface plane for the tip tabs. Optional rudder strip aft.
        func sideFin(chord fc: Double, height h: Double, below: Double? = nil, rudderFrac: Double = 0)
            -> (outline: [Vec2], main: [Vec2], rudder: [Vec2]?, slots: [Hole], tabs: [Double]) {
            let lo = below ?? max(h * 0.25, 10)
            let topLE = min(h * 0.55 + fc * 0.25, fc * 0.75 + h * 0.2)
            let topTE = rudderFrac > 0 ? fc : fc + h * 0.2
            let outline = Poly.ccw([Vec2(fc * 0.12, -lo), Vec2(fc, -lo), Vec2(topTE, h), Vec2(topLE, h), Vec2(0, 0)])
            var main = outline
            var rudder: [Vec2]?
            if rudderFrac > 0 {
                let hu = fc * (1 - rudderFrac)
                main = Poly.ccw([Vec2(fc * 0.12, -lo), Vec2(hu, -lo), Vec2(hu, h), Vec2(min(topLE, hu - 2), h), Vec2(0, 0)])
                rudder = [Vec2(hu, -lo), Vec2(fc, -lo), Vec2(fc, h), Vec2(hu, h)]
            }
            let tabs = [fc * 0.25, fc * (rudderFrac > 0 ? 0.48 : 0.65)]
            let slots = tabs.map { slot(minU: $0 - 5, maxU: $0 + 5, minV: -t / 2, maxV: t / 2) }
            return (outline, main, rudder, slots, tabs)
        }

        /// Optional side winglets on tailed aircraft: tip tabs into winglet slots (same joint as the tailless winglets).
        mutating func tipWinglets(outline: inout [Vec2], main: inout [Vec2], tipV: [Double], tipLE: Double) {
            guard c.tailWinglets, !c.kind.isTailless, c.wingletHeight > 5 else { return }
            let wl = sideFin(chord: c.tipChord, height: c.wingletHeight)
            for v in tipV {
                for tu in wl.tabs {
                    outline = Poly.insertTab(outline, at: Vec2(tipLE + tu, v), width: 10, height: t)
                    main = Poly.insertTab(main, at: Vec2(tipLE + tu, v), width: 10, height: t)
                }
            }
            parts.append(Part(name: "Winglet", role: .winglet, outline: wl.outline, holes: wl.slots,
                              features: [.label("WINGLET", Vec2(c.tipChord * 0.45, c.wingletHeight * 0.45))],
                              instances: [-1.0, 1.0].map { Placement(origin: [$0 * (s + t / 2), 0, tipLE], u: [0, 0, 1], v: [0, 1, 0]) },
                              material: c.material))
        }

        // MARK: Tailless (flying wing / delta)

        mutating func buildTailless() {
            let w = wing
            let f = c.controlChordPct
            let single = !c.isDual
            // The cutout reaches exactly to the elevon inner edges – no leftover trailing-edge strip beside it.
            let nw = single ? 2 * c.motorNotchHalfWidth : 0, nd = single ? c.motorNotchDepth : 0
            let v0 = single ? nw / 2 : s * 0.12
            let v1 = s - 14
            if v1 - v0 < 40 { issues.append("Elevons are too short: the motor cutout needs \(Int(nw)) mm at the centre – use a smaller prop or more span.") }
            let out = w.build(full: true, surfaces: v1 > v0 + 10 ? [v0...v1] : [], fraction: f)

            // Motor sits in a cutout in the trailing edge (prop spins inside the cutout).
            func withMotorNotch(_ poly: [Vec2]) -> [Vec2] {
                guard single, let i = poly.firstIndex(where: { abs($0.y) < 1e-6 && abs($0.x - w.te(0)) < 1e-6 }) else { return poly }
                var p = poly
                p.replaceSubrange(i...i, with: [Vec2(w.te(-nw / 2), -nw / 2), Vec2(w.te(0) - nd, -nw / 2),
                                                Vec2(w.te(0) - nd, nw / 2), Vec2(w.te(nw / 2), nw / 2)])
                return Poly.cleaned(p)
            }
            var outline = withMotorNotch(out.outline)
            var mainRegion = withMotorNotch(out.main)
            if single && w.te(0) - nd < c.rootChord * 0.45 { issues.append("Root chord is too short for the motor cutout.") }
            for v in [-12.0, 12.0] { outline = Poly.insertNotch(outline, at: Vec2(w.le(v), v)) }

            var holes: [Hole] = []
            var features = out.features + sparFeatures(w, from: -s * 0.9, to: 0) + sparFeatures(w, from: 0, to: s * 0.9)

            let sv = c.servo.size
            for side in [-1.0, 1.0] where v1 > v0 + 10 {
                let vs = v0 + max(sv.h / 2 + 6, 14)
                let hingeU = w.te(vs) - f * w.chord(vs)
                let center = Vec2(wingServoU(hingeU: hingeU, sparU: sparAcrossServo(w, vs)), side * vs)
                let name = side < 0 ? "Left elevon" : "Right elevon"
                holes.append(servoCut(name, center: center, size: wingServoCut, in: mainRegion, arm: (side, t)))
                let vh = vs + armOffset, hingeH = w.te(vh) - f * w.chord(vh)
                holes.append(hornSlot(at: Vec2(hingeH + 6, side * vh)))
                let body: SIMD3<Double> = [center.y, 0, center.x]
                controls.append(ControlSurface(name: name,
                                               hingeMid: [side * (v0 + v1) / 2, 0, w.te((v0 + v1) / 2) - f * w.chord((v0 + v1) / 2)],
                                               hornPosition: [side * vh, t / 2 + 9, hingeH + 2], servoPosition: body,
                                               area: Poly.area(out.controls.first ?? []), chord: f * c.rootChord * (1 + c.taper) / 2, servoID: name,
                                               armPosition: armTip(body, side: side)))
            }

            // Centre fin and / or winglets with tabs into the wing.
            let finHeight = c.tailFinHeight
            if finHeight > 5 && c.taillessFins.hasCentreFin {
                let fc = c.rootChord * 0.42
                let fin = finOutline(chord: fc, height: finHeight)
                let maxFinU = w.te(0) - nd - fc - 4
                if c.finPosition > maxFinU {
                    issues.append("Centre fin is too far back – it reaches the motor cutout. Move it forward to ≤ \(Int(maxFinU)) mm.")
                }
                let u0 = c.finPosition
                for tu in fin.tabs { holes.append(slot(minU: u0 + tu - 4, maxU: u0 + tu + 4, minV: -t / 2, maxV: t / 2)) }
                parts.append(Part(name: "Centre fin", role: .fin, outline: fin.outline, features: [.label("FIN", Vec2(fc * 0.45, finHeight * 0.4))],
                                  instances: [Placement(origin: [0, t / 2, u0], u: [0, 0, 1], v: [0, 1, 0])], material: c.material))
            }
            let wingletHeight = c.wingletHeight
            if wingletHeight > 5 && c.taillessFins.hasWinglets {
                // Winglets are glued to the SIDE of the wing tip: tip tabs go through slots in the winglet.
                let wl = sideFin(chord: c.tipChord, height: wingletHeight)
                for v in [-s, s] {
                    for tu in wl.tabs {
                        outline = Poly.insertTab(outline, at: Vec2(w.le(v) + tu, v), width: 10, height: t)
                        mainRegion = Poly.insertTab(mainRegion, at: Vec2(w.le(v) + tu, v), width: 10, height: t)
                    }
                }
                parts.append(Part(name: "Winglet", role: .winglet, outline: wl.outline, holes: wl.slots,
                                  features: [.label("WINGLET", Vec2(c.tipChord * 0.45, wingletHeight * 0.45))],
                                  instances: [-1.0, 1.0].map { Placement(origin: [$0 * (s + t / 2), 0, w.le(s)], u: [0, 0, 1], v: [0, 1, 0]) },
                                  material: c.material))
            }

            // Centre keel under the wing (reinforcement strip, stays within the chord) – carries the motor mount clamp.
            let k0 = 10.0
            let k1 = single ? w.te(0) - nd : w.te(0) - 12
            let hk = max(12, min(20, c.rootChord * 0.08))
            if k1 - k0 > 40 {
                var keel = [Vec2(k0, 0), Vec2(k0 + hk, -hk), Vec2(k1, -hk), Vec2(k1, 0)]
                let tabs = [k0 + (k1 - k0) * 0.3, k0 + (k1 - k0) * 0.75].map(clearOfJoiner).filter { $0 - 6 > k0 && $0 + 6 < k1 }
                for tu in tabs { keel = Poly.insertTab(keel, at: Vec2(tu, 0), width: 10, height: t) }
                holes += centreSlots(tabs)
                parts.append(Part(name: "Centre keel", role: .fuselage, outline: keel,
                                  features: truss(from: k0 + hk, to: k1 - 4, low: { _ in -hk + 2 }, high: { _ in -2 }),
                                  instances: [.vertical(at: [0, -t / 2, 0])], material: c.material))
            }

            let b = c.battery.size
            features.append(.zone(Poly.rect(center: Vec2(c.batteryPosition, 0), size: Vec2(b.l, b.w)), "Battery"))
            batteryPos = [0, t / 2 + b.h / 2, c.batteryPosition]

            parts.insert(Part(name: "Wing", role: .wing, outline: outline, holes: holes, features: features,
                              regions: [Region(polygon: mainRegion, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) },
                              instances: [.horizontal(at: .zero)], material: c.material), at: 0)
        }

        // MARK: Wing halves keyed into the fuselage plate

        /// Builds the two wing halves that plug into the sides of a centre plate of half-width `hw`.
        /// Returns the u-positions of the two joint tabs (the plate needs matching notches).
        mutating func buildWingHalves(plateHalfWidth hw: Double, allowDihedral: Bool) -> [Double] {
            let w = wing
            let f = c.controlChordPct
            let span = s - hw
            let half = TaperedPanel(rootLE: w.le(hw), rootChord: w.chord(hw), tipChord: c.tipChord,
                                    sweep: c.sweep - w.le(hw), semiSpan: span)
            let central = centralAileron
            // Ailerons from near the root with one central servo – and always on the 3D Plane: their inner part sits in
            // the prop's slipstream, so they still work in a hover (holding the torque roll); else from ~30 % of the span.
            let a0 = central ? 3 : (c.kind == .aerobat ? 8 : max(8, s * 0.3 - hw))
            let surfaces: [ClosedRange<Double>] = c.hasAilerons ? [aileronSpan(from: a0, to: span - 10 - wingTipRadius, what: "fuselage")] : []
            let out = half.build(full: false, surfaces: surfaces, fraction: f)
            let ua = half.le(0), ub = half.te(0)
            let tabUs = [ua + (ub - ua) * 0.3, ua + (ub - ua) * 0.72]
            var outline = out.outline, main = out.main
            // Rounded wing tip (LE and TE corners) – the aileron ends far enough inboard to keep it in the fixed tip.
            if wingTipRadius > 0 {
                let r = rounded([outline, main], corners: [Vec2(half.le(span), span), Vec2(half.te(span), span)], radius: wingTipRadius)
                outline = r[0]; main = r[1]
            }
            for tu in tabUs {
                outline = Poly.insertTab(outline, at: Vec2(tu, 0), width: 10, height: 6)
                main = Poly.insertTab(main, at: Vec2(tu, 0), width: 10, height: 6)
            }
            var holes: [Hole] = []
            var features = out.features + sparFeatures(half, from: 0, to: span * 0.9)
            if c.hasAilerons {
                let sv = c.servo.size
                let area = Poly.area(out.controls.first ?? [])
                let chord = f * c.rootChord * (1 + c.taper) / 2
                if central {
                    // Horn under the inner end of each aileron; pushrod from the double arm's end runs aft to it.
                    let hv = a0 + TaperedPanel.endGap + 5
                    let hingeH = half.te(hv) - f * half.chord(hv)
                    holes.append(hornSlot(at: Vec2(hingeH + 6, hv)))
                    _ = sv
                    for side in [-1.0, 1.0] {
                        controls.append(ControlSurface(name: side < 0 ? "Left aileron" : "Right aileron",
                                                       hingeMid: [side * (hw + span * 0.6), 0, half.te(span * 0.6) - f * half.chord(span * 0.6)],
                                                       hornPosition: [side * (hw + hv), -t / 2 - 9, hingeH + 2],
                                                       servoPosition: ailServoCenter,
                                                       area: area, chord: chord, servoID: "Ailerons (double arm)",
                                                       armPosition: [side * ailArm, ailArmY, ailShaftU], hornAxis: [0, -1, 0]))
                    }
                } else {
                    let vs = a0 + max(14, sv.h / 2 + 6)
                    let hingeU = half.te(vs) - f * half.chord(vs)
                    let center = Vec2(wingServoU(hingeU: hingeU, sparU: sparAcrossServo(half, vs)), vs)
                    holes.append(servoCut("Aileron", center: center, size: wingServoCut, in: main, arm: (1, t)))
                    let vh = vs + armOffset, hingeH = half.te(vh) - f * half.chord(vh)
                    holes.append(hornSlot(at: Vec2(hingeH + 6, vh)))
                    for side in [-1.0, 1.0] {
                        let name = side < 0 ? "Left aileron" : "Right aileron"
                        let body: SIMD3<Double> = [side * (hw + vs), 0, center.x]
                        controls.append(ControlSurface(name: name, hingeMid: [side * (hw + span * 0.6), 0, hingeU],
                                                       hornPosition: [side * (hw + vh), t / 2 + 9, hingeH + 2],
                                                       servoPosition: body, area: area, chord: chord, servoID: name,
                                                       armPosition: armTip(body, side: side)))
                    }
                }
            }
            tipWinglets(outline: &outline, main: &main, tipV: [span], tipLE: w.le(s))
            let d = 0.0   // flat wings only – dihedral joints in foam are not stiff enough
            parts.append(Part(name: "Wing half", role: .wing, outline: outline, holes: holes, features: features,
                              regions: [Region(polygon: main, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) },
                              instances: [Placement(origin: [hw, 0, 0], u: [0, 0, 1], v: [cos(d), sin(d), 0]),
                                          Placement(origin: [-hw, 0, 0], u: [0, 0, 1], v: [-cos(d), sin(d), 0])],
                              material: c.material, mirroredPair: true))
            return tabUs
        }

        // MARK: Conventional aircraft – cross fuselage

        mutating func buildConventional() {
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm, hsc = c.hStabChord, vsc = c.vStabChord
            let W = c.fuselagePlateWidth, hw = W / 2
            let wb = c.plateTailWidth
            let sh = c.hStabSpan / 2
            let ef = 0.4
            // Swept forward the tip chord grows by the sweep: the trailing edge stays put and the elevator one piece.
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc * 0.8 + max(0, -c.hStabSweep), sweep: c.hStabSweep, semiSpan: sh)
            // One-piece elevator on a straight hinge across the whole stabiliser (it runs under the rudder).
            let uH = stab.te(0) - ef * stab.chord(0)
            if stab.le(sh) > uH - 8 { issues.append("Stabiliser sweep too large – the tip's leading edge reaches the elevator hinge. Reduce the stab sweep or increase the stab chord.") }
            func hS(_ v: Double) -> Double { uH }
            let w = wing

            // Wing halves keyed into the plate.
            let jointTabs = buildWingHalves(plateHalfWidth: hw, allowDihedral: true)
            let ua = w.le(hw), ub = w.te(hw)

            // --- Horizontal fuselage plate: nose strip + wing centre + tail boom + stabiliser in one piece.
            let rudderChord = max(0.4 * vsc, 18.0)
            let uR = uH + rudderChord            // rudder trailing edge
            if stab.le(wb / 2) < ub + 10 { issues.append("Tail arm is too short – the stabiliser would reach the wing.") }

            func notch(_ u: Double) -> [Vec2] { [Vec2(u - 5.2, hw), Vec2(u - 5.2, hw - 6.2), Vec2(u + 5.2, hw - 6.2), Vec2(u + 5.2, hw)] }
            let noseSide = [Vec2(uN, W * 0.3), Vec2(uN + 6, hw)]
            let wingSide = [Vec2(ua, hw)] + notch(jointTabs[0]) + notch(jointTabs[1]) + [Vec2(ub, hw)]
            let boomSide = [Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh)]
            func mirrored(_ r: [Vec2]) -> [Vec2] { r.reversed().map { Vec2($0.x, -$0.y) } }
            let rOutline = noseSide + wingSide + boomSide + [Vec2(stab.te(sh), sh)]
            let rMain = noseSide + wingSide + boomSide + [Vec2(uH, sh)]
            var plateOutline = Poly.ccw(rOutline + [Vec2(stab.te(0), 0)] + mirrored(rOutline))
            let plateMain = Poly.ccw(rMain + mirrored(rMain))
            var elevator = Poly.ccw([Vec2(uH, -sh), Vec2(uH, sh), Vec2(stab.te(sh), sh), Vec2(stab.te(0), 0), Vec2(stab.te(sh), -sh)])
            if stabTipRadius > 0 {       // rounded elevator trailing-edge tips
                let r = rounded([plateOutline, elevator], corners: [Vec2(stab.te(sh), sh), Vec2(stab.te(sh), -sh)], radius: stabTipRadius)
                plateOutline = r[0]; elevator = r[1]
            }
            if !Poly.isSimple(plateOutline) { issues.append("Fuselage plate outline intersects itself – check tail arm, stabiliser and wing chord.") }

            // --- Upper fuselage half (with fin & rudder) and lower half.
            let hWing = fh * 0.5 - t / 2
            let hNose = fh * 0.4 - t / 2
            // The nose tapers to the firewall so the clamp-type motor mount covers the whole nose face.
            let mountHalf = PrintedParts.motorMountPlate(c.motor, foam: t) / 2
            // (also with dual motors: then the printed nose protector covers the nose face)
            let noseFront = min(hNose * 0.65, max(mountHalf - t / 2 - 0.5, 4))
            let noseFrontLow = min((fh * 0.5 - t / 2) * 0.55, max(mountHalf - t / 2 - 0.5, 4))
            let aw = ailWindow
            // One aileron servo: aileron servo (front) and elevator servo ahead of the spar, rudder servo behind it, each
            // centred on the plate – half in the upper, half in the lower fuselage half (orientation as always: aileron
            // servo shaft down, elevator / rudder servos through the web with the shaft sideways).
            let central = centralAileron
            let svC = c.servo.size
            let twC = t * Double(c.fuselageType.webLayers)
            let webOpen = c.centralWebServoHalfOpening
            /// Plate opening for a servo passing through the webs: flush around the servo, with a pocket on the shaft side
            /// for the arm (its hub sits at plate level).
            func webServoOpening(_ u: Double, side: Double) -> [Vec2] {
                let body = Poly.rect(center: Vec2(u, 0), size: Vec2(2 * webOpen, 2 * max(svC.h / 2 + 0.2, twC / 2 + 0.2)))
                return Self.unionRects(body, armPocket(cutCenter: Vec2(u, 0), cutHalfAcross: svC.h / 2 + 0.2, side: side,
                                                       hubU: u + svC.l / 2 - 5, sheet: t))
            }
            let uEC = c.centralElevatorServoU
            var uRC = c.centralRudderServoU
            if c.hasRudder {
                // Behind the spar; further aft while the opening would cut into a wing-joint notch of the plate.
                while !Poly.containsAll(Poly.inset(plateOutline, by: 1.5), webServoOpening(uRC, side: 1)) && uRC < c.centralRudderServoU + 30 { uRC += 1 }
            }
            // Notches: in the bottom edge of the upper half (for the servo tops and the aileron servo's frame on the
            // plate) and in the top edge of the lower half (servo bottoms, the aileron servo's arm). (u0, u1, depth)
            let webDepth = svC.w / 2 + 0.3 - t / 2
            var upNotches: [(Double, Double, Double)] = [], loNotches: [(Double, Double, Double)] = []
            if central {
                upNotches.append((ailServoU - svC.l / 2 - 0.2, ailServoU + svC.l / 2 + 0.2, svC.h / 2 + 0.2 - t / 2))
                loNotches.append((aw.u0, aw.u1, aw.h))
                let aa = ailArmWindow
                loNotches.append((aa.u0, aa.u1, aa.h))
            }
            // Elevator and rudder servos centred on the plate – with one or two aileron servos alike.
            var webServos = [uEC]
            if c.hasRudder { webServos.append(uRC) }
            for u in webServos where webDepth > 0 {
                upNotches.append((u - svC.l / 2 - 0.2, u + svC.l / 2 + 0.2, webDepth))
                loNotches.append((u - svC.l / 2 - 0.2, u + svC.l / 2 + 0.2, webDepth))
            }
            // Overlapping notches merge into one stepped profile (deepest wins); the bottom edge of the upper half runs
            // aft, the top edge of the lower half forward.
            func profile(_ ns: [(Double, Double, Double)], sign: Double) -> [Vec2] {
                let xs = Array(Set(ns.flatMap { [$0.0, $0.1] })).sorted()
                var pts: [Vec2] = []
                for i in 0..<max(xs.count - 1, 0) {
                    let m = (xs[i] + xs[i + 1]) / 2
                    let dep = ns.filter { m > $0.0 && m < $0.1 }.map(\.2).max() ?? 0
                    pts += [Vec2(xs[i], sign * dep), Vec2(xs[i + 1], sign * dep)]
                }
                guard let f = pts.first, let l = pts.last else { return [] }
                return Poly.cleaned([Vec2(f.x, 0)] + pts + [Vec2(l.x, 0)])
            }
            let upNotchPts = profile(upNotches.filter { $0.2 > 0 }, sign: 1)
            let ailNotch = Array(profile(loNotches.filter { $0.2 > 0 }, sign: -1).reversed())
            // Tabs keep clear of every servo station (also where thick foam needs no notch) and of the servos'
            // mounting ears, which reach `earLength` beyond each end.
            let earL = c.servo.earLength
            let servoSpans = (upNotches + loNotches).map { ($0.0, $0.1) }
                + webServos.map { ($0 - svC.l / 2 - 0.2, $0 + svC.l / 2 + 0.2) }
                + (central ? [(ailServoU - svC.l / 2 - 0.2, ailServoU + svC.l / 2 + 0.2)] : [])
            let clearOfAileronServo = { (u: Double) in servoSpans.allSatisfy { u + 6 < $0.0 - 2 - earL || u - 6 > $0.1 + 2 + earL } }
            let hBoom = c.boomTopHeight
            let finTop = hBoom + c.vStabHeight
            let finLE = uH - 1.25 * vsc
            if finLE < ub + 10 { issues.append("Fin is too long for the tail arm – fin leading edge reaches the wing.") }
            let rg = c.hasRudder ? TaperedPanel.endGap : 0     // rudder clears the plate / elevator by this gap
            // Cut-out at the bottom of the rudder (or fixed fin) so the one-piece elevator can move up under it, at the
            // full throw + 5° (see FinCut); the rudder horn sits above the elevator's reach.
            let cut = finCut(elevChord: ef * hsc, rg: rg)
            let cutEdge = cut.edge(0, uR - uH).map { Vec2(uH + $0.x, $0.y) }
            let rHornV = max(rudderHornV(uH: uH, elevChord: ef * hsc, tw: t * Double(c.fuselageType.webLayers)), cut.v(6) + 8)
            var upper: [Vec2] = [Vec2(uN, 0)] + upNotchPts + [Vec2(uH, 0)] + (rg > 0 ? cutEdge : Array(cutEdge.dropFirst())) + [Vec2(uR, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                 Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, noseFront)]
            var upperMain: [Vec2] = [Vec2(uN, 0)] + upNotchPts + [Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                     Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, noseFront)]
            var rudder = cutEdge + [Vec2(uR, finTop), Vec2(uH, finTop)]
            if finTopRadius > 0 {        // rounded fin / rudder top corners
                let r = rounded([upper, upperMain, rudder], corners: [Vec2(uR, finTop), Vec2(uH - 0.3 * vsc, finTop)], radius: finTopRadius)
                upper = r[0]; upperMain = r[1]; rudder = r[2]
            }
            let hasRudder = c.hasRudder
            if !hasRudder { upperMain = upper }
            let layers = Double(c.fuselageType.webLayers)
            let tw = t * layers
            let upTabs = [uN + max(32, c.noseLength * 0.45), c.rootChord * 0.45, (c.rootChord + finLE) / 2, finLE + vsc * 0.5].map(clearOfJoiner).filter { $0 + 6 < uH && clearOfAileronServo($0) }
            var upperOut = upper
            for tu in upTabs { upperOut = Poly.insertTab(upperOut, at: Vec2(tu, 0), width: 10, height: t); upperMain = Poly.insertTab(upperMain, at: Vec2(tu, 0), width: 10, height: t) }

            let uL = ta + hsc * 0.35
            let hLowWing = fh * 0.5 - t / 2
            let lower: [Vec2] = [Vec2(uN, 0), Vec2(uN, -noseFrontLow), Vec2(uN + 0.3 * c.noseLength, -hLowWing), Vec2(c.rootChord * 0.85, -hLowWing),
                                 Vec2(uL, -c.lowerTailHeight), Vec2(uL, 0)] + ailNotch
            let loTabs = [uN + max(44, c.noseLength * 0.6), c.rootChord * 0.75, (c.rootChord + ta) / 2 + 15].map(clearOfJoiner).filter { $0 + 6 < uL && clearOfAileronServo($0) }
            var lowerOut = lower
            for tu in loTabs { lowerOut = Poly.insertTab(lowerOut, at: Vec2(tu, 0), width: 10, height: t) }

            // Plate slots for both halves (all on the centre line, at different stations).
            var plateHoles = (upTabs + loTabs).map { slot(minU: $0 - 5, maxU: $0 + 5, minV: -tw / 2, maxV: tw / 2) }
            // Elevator horn beside the rudder, outside its sideways swing.
            let eHornV = max(armOffset, tw / 2 + 10)

            // Servos: in the upper half above the plate – or, with one aileron servo, all three centred on the plate.
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.06 + sv.l / 2 + c.servo.earLength, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 2 * c.servo.earLength + 5, s1.y)
            var upperHoles: [Hole] = []
            if central {
                // Aileron servo standing in the plate: flush L × W cutout (its arm is below the plate).
                plateHoles.append(servoCut("Aileron", center: Vec2(ailServoU, 0), size: Vec2(sv.l, sv.w), in: plateOutline))
                if c.batteryPosition + c.battery.size.l / 2 + 3 > c.centralServosFrontU {
                    issues.append("The battery reaches the aileron servo centred on the plate – move it forward (Auto-balance) or use a smaller battery.")
                }
            }
            // Elevator / rudder servos pass through both webs and a flush opening in the plate (arm pocket on the shaft
            // side): the elevator servo's shaft on the left with its arm pointing down (below the plate the right side
            // stays free for the battery), the rudder servo's shaft on the right with its arm pointing up – elevator and
            // rudder horns sit on opposite sides.
            for (name, u, side) in [("Elevator", uEC, -1.0)] + (hasRudder ? [("Rudder", uRC, 1.0)] : []) {
                let open = webServoOpening(u, side: side)
                if !Poly.containsAll(plateOutline, open) {
                    issues.append("The \(name.lowercased()) servo opening does not fit in the fuselage plate – widen the plate or pick a smaller servo.")
                }
                plateHoles.append(Hole(kind: .servo, polygon: open, note: name))
            }
            _ = s2
            if hasRudder { upperHoles.append(hornSlot(at: Vec2(uH + 6, rHornV))) }
            // Elevator horn under the elevator on the left, straight behind the arm (the pushrod runs under the plate).
            plateHoles.append(hornSlot(at: Vec2(uH + 6, -eHornV), under: true))
            let lowerHoles: [Hole] = []
            if centralAileron && ailArmWindow.h > hLowWing - 6 {
                issues.append("The lower fuselage is too shallow for the upside-down aileron servo and its arm – increase the fuselage height.")
            }

            // Carbon truss on both sides of the boom and along the lower half.
            let rc = c.rootChord
            let lowTail = c.lowerTailHeight
            let boomTop: (Double) -> Double = { u in
                let k = (u - rc) / max(finLE - rc, 1)
                return hWing * 0.9 + (hBoom - hWing * 0.9) * min(max(k, 0), 1) - 2.5
            }
            let upperTruss = truss(from: c.rootChord + 4, to: min(finLE + vsc * 0.6, uH - 6), low: { _ in 2.5 }, high: boomTop)
            let lowerTruss = truss(from: c.rootChord * 0.9, to: uL - 6, low: { u in
                let k = (u - rc * 0.85) / max(uL - rc * 0.85, 1)
                return -(hLowWing + (lowTail - hLowWing) * min(max(k, 0), 1)) + 2.5
            }, high: { _ in -2.5 })

            parts.append(Part(name: "Fuselage plate", role: .fuselage, outline: plateOutline, holes: plateHoles,
                              features: [.hinge(Vec2(uH, -sh), Vec2(uH, sh)),
                                         .label("PLATE", Vec2(c.rootChord * 0.5, 0))] + (c.hasSparJoiner ? sparFeatures(w, from: -hw, to: 0) + sparFeatures(w, from: 0, to: hw) : sparFeatures(w, from: -hw, to: hw)),
                              regions: [Region(polygon: plateMain, isControl: false), Region(polygon: elevator, isControl: true)],
                              instances: [.horizontal(at: .zero)], material: c.material))
            let webX: [Double] = layers > 1 ? [-t / 2, t / 2] : [0]
            let layerNote = layers > 1 ? " · 2 layers laminated" : ""
            var upperFeatures: [Feature] = [.label("TOP", Vec2(c.rootChord * 0.4, hWing * 0.55))] + upperTruss
            if hasRudder { upperFeatures.insert(.hinge(Vec2(uH, 0), Vec2(uH, finTop)), at: 0) }
            parts.append(Part(name: "Fuselage top\(layerNote)", role: .fuselage, outline: upperOut, holes: upperHoles,
                              features: upperFeatures,
                              regions: hasRudder ? [Region(polygon: upperMain, isControl: false), Region(polygon: rudder, isControl: true)] : [],
                              instances: webX.map { .vertical(at: [$0, t / 2, 0]) }, material: c.material))
            parts.append(Part(name: "Fuselage bottom\(layerNote)", role: .fuselage, outline: lowerOut, holes: lowerHoles,
                              features: [.label("BOTTOM", Vec2(c.rootChord * 0.3, -hLowWing * 0.5)),
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -(c.batteryTop - t / 2) - c.battery.size.w / 2), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")] + lowerTruss,
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))

            let eBody: SIMD3<Double> = [0, 0, uEC]
            // Centred on the plate the elevator servo's arm points down: its pushrod runs under the plate straight to
            // the horn under the elevator.
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [-eHornV, -(t / 2 + 9), uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: ef * hsc * 0.9, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: -1, down: true), hornAxis: [0, -1, 0]))
            if hasRudder {
                // Rudder horn on the right side of the rudder, servo arm on the right (elevator on the left): the
                // pushrods run on opposite sides and never cross.
                let rBody: SIMD3<Double> = [0, 0, uRC]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [tw / 2 + 8, t / 2 + rHornV, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: 1), hornAxis: [1, 0, 0]))
            }

            batteryPos = [tw / 2 + c.battery.size.h / 2, -c.batteryTop - c.battery.size.w / 2, c.batteryPosition]
        }

        // MARK: Sport jet (Ares style) – swept wing, prop spinning in a slot through the wing centre

        mutating func buildJet() {
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm, hsc = c.hStabChord, vsc = c.vStabChord
            let W = c.fuselagePlateWidth, hw = W / 2, wb = c.plateTailWidth
            let w = wing
            let zp = c.jetPropZ
            let slotHalf = c.jetSlotHalfWidth
            let gap = c.jetSlotRear - zp                    // rear fuselage halves start behind the slot (prop + spinner + clearance)
            let layers = Double(c.fuselageType.webLayers), tw = t * layers
            let webX: [Double] = layers > 1 ? [-t / 2, t / 2] : [0]
            let layerNote = layers > 1 ? " · 2 layers laminated" : ""
            let te0 = w.te(0)

            // --- Wing (one piece) with prop slot, ailerons and joints for nose and tail plates.
            let fA = c.controlChordPct
            let a0 = max(slotHalf + 12, s * 0.35)
            let out = w.build(full: true, surfaces: c.hasAilerons ? [aileronSpan(from: a0, to: s - 8 - wingTipRadius, what: "prop slot")] : [], fraction: fA)
            var wingOutline = out.outline, wingMain = out.main
            if wingTipRadius > 0 {
                let r = rounded([wingOutline, wingMain], corners: [Vec2(w.le(s), s), Vec2(w.te(s), s), Vec2(w.le(s), -s), Vec2(w.te(s), -s)], radius: wingTipRadius)
                wingOutline = r[0]; wingMain = r[1]
            }
            for v in [-hw * 0.5, hw * 0.5] {
                for u in [w.le(v), w.te(v)] {
                    wingOutline = Poly.insertTab(wingOutline, at: Vec2(u, v), width: 10, height: -6)
                    wingMain = Poly.insertTab(wingMain, at: Vec2(u, v), width: 10, height: -6)
                }
            }
            // The slot runs from the firewall plate (motor body inside it) to behind the spinner.
            var wingHoles: [Hole] = [slot(minU: c.jetSlotFront, maxU: c.jetSlotRear, minV: -slotHalf, maxV: slotHalf)]
            wingHoles[0].note = "prop slot"
            if w.le(slotHalf) > c.jetSlotFront - 10 || w.te(slotHalf) < c.jetSlotRear + 10 {
                issues.append("The prop slot (\(Int(slotHalf * 2)) mm) does not fit in the wing root – increase root chord, reduce sweep or use a smaller prop.")
            }
            if c.hasAilerons {
                let sv = c.servo.size
                let vs = a0 + max(14, sv.h / 2 + 6)
                let hingeU = w.te(vs) - fA * w.chord(vs)
                for side in [-1.0, 1.0] {
                    let name = side < 0 ? "Left aileron" : "Right aileron"
                    let center = Vec2(wingServoU(hingeU: hingeU, sparU: sparAcrossServo(w, vs)), side * vs)
                    wingHoles.append(servoCut(name, center: center, size: wingServoCut, in: wingMain, arm: (side, t)))
                    let vh = vs + armOffset, hingeH = w.te(vh) - fA * w.chord(vh)
                    wingHoles.append(hornSlot(at: Vec2(hingeH + 6, side * vh)))
                    let body: SIMD3<Double> = [side * vs, 0, center.x]
                    controls.append(ControlSurface(name: name, hingeMid: [side * (a0 + s) / 2, 0, hingeU], hornPosition: [side * vh, t / 2 + 9, hingeH + 2],
                                                   servoPosition: body, area: Poly.area(out.controls.first ?? []),
                                                   chord: fA * c.rootChord * (1 + c.taper) / 2, servoID: name, armPosition: armTip(body, side: side)))
                }
            }
            var wingFeatures = out.features + sparFeatures(w, from: -s * 0.9, to: 0) + sparFeatures(w, from: 0, to: s * 0.9)

            // --- Nose plate (pointed) keyed into the leading edge.
            var nose = Poly.ccw([Vec2(uN, -2), Vec2(uN + 0.5 * c.noseLength, -hw * 0.85), Vec2(w.le(hw), -hw), Vec2(0, 0),
                                 Vec2(w.le(hw), hw), Vec2(uN + 0.5 * c.noseLength, hw * 0.85), Vec2(uN, 2)])
            for v in [-hw * 0.5, hw * 0.5] { nose = Poly.insertTab(nose, at: Vec2(w.le(v), v), width: 10, height: 6) }

            // --- Tail plate: boom + swept stabiliser, keyed into the trailing edge.
            let sh = c.hStabSpan / 2
            // Swept leading edge, straight trailing edge: the one-piece elevator gets a straight hinge across the
            // whole tail and runs under the rudder.
            // (tip chord = root chord − sweep: the trailing edge stays straight)
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: max(hsc - c.hStabSweep, hsc * 0.3), sweep: c.hStabSweep, semiSpan: sh)
            let uH = stab.te(0) - 0.4 * hsc
            if stab.le(sh) > uH - 8 { issues.append("Stabiliser sweep too large – the tip's leading edge reaches the elevator hinge. Reduce the stab sweep or increase the stab chord.") }
            let rudderChord = max(0.4 * vsc, 18.0)
            let uR = uH + rudderChord
            if stab.le(wb / 2) < w.te(hw) + 15 { issues.append("Tail arm is too short – the stabiliser would reach the wing.") }
            let rFull = [Vec2(w.te(hw), hw), Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh), Vec2(stab.te(sh), sh)]
            let rFixed = [Vec2(w.te(hw), hw), Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh), Vec2(uH, sh)]
            func mirrored(_ r: [Vec2]) -> [Vec2] { r.reversed().map { Vec2($0.x, -$0.y) } }
            var tail = Poly.ccw([Vec2(te0, 0)] + rFull + mirrored(rFull))
            var tailMain = Poly.ccw([Vec2(te0, 0)] + rFixed + mirrored(rFixed))
            for v in [-hw * 0.5, hw * 0.5] {
                tail = Poly.insertTab(tail, at: Vec2(w.te(v), v), width: 10, height: 6)
                tailMain = Poly.insertTab(tailMain, at: Vec2(w.te(v), v), width: 10, height: 6)
            }
            var elevator = Poly.ccw([Vec2(uH, -sh), Vec2(uH, sh), Vec2(stab.te(sh), sh), Vec2(stab.te(sh), -sh)])
            if stabTipRadius > 0 {
                let r = rounded([tail, elevator], corners: [Vec2(stab.te(sh), sh), Vec2(stab.te(sh), -sh)], radius: stabTipRadius)
                tail = r[0]; elevator = r[1]
            }

            // --- Vertical fuselage: one upper and one lower piece from nose to tail. The prop spins in a window cut
            // into both (and the prop slot in the wing); a frame of foam closes the fuselage above and below it.
            let hCanopy = fh * 0.5 - t / 2, hBoom = c.boomTopHeight
            let finTop = hBoom + c.vStabHeight
            let finLE = uH - 1.3 * vsc
            let wF = c.jetSlotFront, wR = c.jetSlotRear          // window front (firewall plate) / rear
            let wH = c.jetWindowHeight                            // window height above / below the plate
            // Fuselage height over the window: at least window + rim, and it grows with the fuselage height
            // (top and bottom of the frame follow the fuselage height setting).
            let hFrame = max(wH + DesignBuilder.jetFrameRim, fh * 0.5 - t / 2)
            let rgJ = c.hasRudder ? TaperedPanel.endGap : 0
            let cut = finCut(elevChord: 0.4 * hsc, rg: rgJ)                    // cut-out over the elevator
            let cutEdge = cut.edge(0, uR - uH).map { Vec2(uH + $0.x, $0.y) }
            let rHornV = max(rudderHornV(uH: uH, elevChord: 0.4 * hsc, tw: t * Double(c.fuselageType.webLayers)), cut.v(6) + 8)
            let window: [Vec2] = [Vec2(wF, 0), Vec2(wF, wH), Vec2(wR, wH), Vec2(wR, 0)]
            let topLine: [Vec2] = [Vec2(finLE, hBoom), Vec2(wR + 18, hFrame), Vec2(wF - 18, hFrame), Vec2(c.rootChord * 0.2, max(hCanopy, hFrame)),
                                   Vec2(-0.3 * c.noseLength, hCanopy * 0.85), Vec2(uN + 0.45 * c.noseLength, hCanopy * 0.4), Vec2(uN + 12, 3)]
            var upper = [Vec2(uN + 12, 0)] + window + [Vec2(uH, 0)] + (rgJ > 0 ? cutEdge : Array(cutEdge.dropFirst())) +
                [Vec2(uR, finTop), Vec2(uH - 0.35 * vsc, finTop)] + topLine
            var upperMain = [Vec2(uN + 12, 0)] + window + [Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.35 * vsc, finTop)] + topLine
            var rudder = cutEdge + [Vec2(uR, finTop), Vec2(uH, finTop)]
            if finTopRadius > 0 {
                let r = rounded([upper, upperMain, rudder], corners: [Vec2(uR, finTop), Vec2(uH - 0.35 * vsc, finTop)], radius: finTopRadius)
                upper = r[0]; upperMain = r[1]; rudder = r[2]
            }
            if !c.hasRudder { upperMain = upper }
            if finLE < wR + 25 { issues.append("Fin is too long for the tail arm – it reaches the prop window.") }
            if c.rootChord * 0.2 > wF - 25 { issues.append("The prop window starts too far forward – increase the root chord or use a smaller prop.") }
            let hLow = fh * 0.3
            let uL = ta + hsc * 0.3
            var lower = [Vec2(uN + 0.3 * c.noseLength, 0), Vec2(wF, 0), Vec2(wF, -wH), Vec2(wR, -wH), Vec2(wR, 0), Vec2(uL, 0),
                         Vec2(uL, -c.lowerTailHeight * 0.7), Vec2(wR + 25, -hFrame), Vec2(wF - 18, -hFrame),
                         Vec2(c.rootChord * 0.2, -min(hLow, hFrame)), Vec2(uN + 0.5 * c.noseLength, -hLow * 0.5)]
            if uL < wR + 35 { issues.append("Tail arm is too short for the prop window.") }

            // Tabs → slots in whichever horizontal part lies underneath (never inside the window).
            var noseHoles: [Hole] = [], tailHoles: [Hole] = []
            func addSlots(_ us: [Double]) {
                for u in us {
                    let h = slot(minU: u - 5, maxU: u + 5, minV: -tw / 2, maxV: tw / 2)
                    if u < -6 { noseHoles.append(h) } else if u < te0 - 8 { wingHoles.append(h) } else if u > te0 + 8 { tailHoles.append(h) }
                }
            }
            // Elevator and rudder servos BEHIND the prop window (their pushrods run aft to the tail without crossing the
            // spinning prop), centred on the plate as on the cross-fuselage types: half in the upper, half in the lower
            // fuselage, through flush openings in the wing / tail plate – an opening never straddles their joint.
            let sv = c.servo.size
            let open = c.centralWebServoHalfOpening + 1
            var servoUs: [Double] = []
            var nextU = wR + 12 + sv.l / 2
            for _ in 0..<(c.hasRudder ? 2 : 1) {
                var u = nextU
                if u - open < te0 + 3 && u + open > te0 - 3 { u = te0 + 3 + open }
                servoUs.append(u)
                nextU = u + sv.l + 2 * c.servo.earLength + 5
            }
            let uEJ = servoUs[0], uRJ = servoUs.count > 1 ? servoUs[1] : uEJ
            if (servoUs.last ?? 0) + sv.l / 2 + 6 > finLE { issues.append("No room for the elevator and rudder servos between the prop window and the fin – lengthen the tail arm.") }
            let earReach = sv.l / 2 + c.servo.earLength + 7
            let clearOfServos = { (u: Double) in servoUs.allSatisfy { abs(u - $0) > earReach } }
            let clearOfWindow = { (u: Double) in u + 8 < wF || u - 8 > wR }
            let upTabs = [uN + 0.6 * c.noseLength, c.rootChord * 0.15, (te0 + ta) / 2, ta + hsc * 0.2].map(clearOfJoiner).filter { clearOfWindow($0) && $0 + 8 < uH && clearOfServos($0) }
            let loTabs = [uN + 0.7 * c.noseLength, c.rootChord * 0.3, (te0 + uL) / 2].map(clearOfJoiner).filter { clearOfWindow($0) && $0 + 8 < uL && clearOfServos($0) }
            // Notches for the servos in the plate edges of both fuselage halves (aft of the window).
            if let i = upper.firstIndex(of: Vec2(wR, 0)) { upper.insert(contentsOf: centredServoNotches(servoUs, sign: 1), at: i + 1) }
            if let i = upperMain.firstIndex(of: Vec2(wR, 0)) { upperMain.insert(contentsOf: centredServoNotches(servoUs, sign: 1), at: i + 1) }
            if let i = lower.firstIndex(of: Vec2(wR, 0)) { lower.insert(contentsOf: centredServoNotches(servoUs, sign: -1), at: i + 1) }
            for u in upTabs { upper = Poly.insertTab(upper, at: Vec2(u, 0), width: 10, height: t); upperMain = Poly.insertTab(upperMain, at: Vec2(u, 0), width: 10, height: t) }
            for u in loTabs { lower = Poly.insertTab(lower, at: Vec2(u, 0), width: 10, height: t) }
            lower = Poly.ccw(lower)
            addSlots(upTabs + loTabs)
            // Elevator horn under the elevator on the left, straight behind the servo arm (the pushrod runs under the plate).
            let eHornV = max(armOffset, tw / 2 + 10)
            tailHoles.append(hornSlot(at: Vec2(uH + 6, -eHornV), under: true))
            // Plate openings: elevator servo shaft on the left (arm down), rudder servo shaft on the right (arm up).
            for (name, u, side) in [("Elevator", uEJ, -1.0)] + (c.hasRudder ? [("Rudder", uRJ, 1.0)] : []) {
                let o = centredServoOpening(u, side: side, tw: tw)
                let inWing = Poly.containsAll(wingMain, o), inTail = Poly.containsAll(tailMain, o)
                if inWing { wingHoles.append(Hole(kind: .servo, polygon: o, note: name)) }
                else if inTail { tailHoles.append(Hole(kind: .servo, polygon: o, note: name)) }
                else {
                    issues.append("The \(name.lowercased()) servo opening does not fit in the wing or tail plate – widen the plate or pick a smaller servo.")
                    (u < te0 ? { wingHoles.append(Hole(kind: .servo, polygon: o, note: name)) } : { tailHoles.append(Hole(kind: .servo, polygon: o, note: name)) })()
                }
            }
            var upperHoles: [Hole] = []
            if c.hasRudder { upperHoles.append(hornSlot(at: Vec2(uH + 6, rHornV))) }

            tipWinglets(outline: &wingOutline, main: &wingMain, tipV: [-s, s], tipLE: w.le(s))
            parts.append(Part(name: "Wing", role: .wing, outline: wingOutline, holes: wingHoles, features: wingFeatures,
                              regions: c.hasAilerons ? [Region(polygon: wingMain, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) } : [],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Nose plate", role: .fuselage, outline: nose, holes: noseHoles,
                              features: [.label("NOSE", Vec2(uN * 0.45, 0))], instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Tail plate", role: .stabilizer, outline: tail, holes: tailHoles,
                              features: [.hinge(Vec2(uH, -sh), Vec2(uH, sh))],
                              regions: [Region(polygon: tailMain, isControl: false), Region(polygon: elevator, isControl: true)],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Fuselage top\(layerNote)", role: .fuselage, outline: upper, holes: upperHoles,
                              features: (c.hasRudder ? [.hinge(Vec2(uH, 0), Vec2(uH, finTop))] : []) +
                                        [.label("CANOPY", Vec2(c.rootChord * 0.05, hCanopy * 0.6)), .label("PROP WINDOW", Vec2((wF + wR) / 2 - 18, wH + 3))],
                              regions: c.hasRudder ? [Region(polygon: upperMain, isControl: false), Region(polygon: rudder, isControl: true)] : [],
                              instances: webX.map { .vertical(at: [$0, t / 2, 0]) }, material: c.material))
            parts.append(Part(name: "Fuselage bottom\(layerNote)", role: .fuselage, outline: lower,
                              features: [.zone(Poly.rect(center: Vec2(c.batteryPosition, -(c.batteryTop - t / 2) - c.battery.size.w / 2), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))

            // Elevator servo arm down on the left: the pushrod runs under the plate to the horn, never through the body.
            let eBody: SIMD3<Double> = [0, 0, uEJ]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [-eHornV, -(t / 2 + 9), uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: 0.4 * hsc * 0.8, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: -1, down: true), hornAxis: [0, -1, 0]))
            if c.hasRudder {
                // Rudder servo arm up on the right, horn on the right side of the rudder: the pushrods never cross.
                let rBody: SIMD3<Double> = [0, 0, uRJ]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [tw / 2 + 8, t / 2 + rHornV, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: 1), hornAxis: [1, 0, 0]))
            }
            batteryPos = [tw / 2 + c.battery.size.h / 2, -c.batteryTop - c.battery.size.w / 2, c.batteryPosition]
        }

        // MARK: Twin boom pusher

        mutating func buildTwinBoom() {
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm, hsc = c.hStabChord
            let xb = c.boomX
            let boomY = -t / 2 - 2
            let rod = CarbonSpar.tube4
            let w = wing
            let W = c.fuselagePlateWidth, hw = W / 2

            // One-piece wing; the pod nose plate keys into its leading edge.
            let fA = c.controlChordPct
            let a0 = max(s * 0.3, xb + 14)
            let out = w.build(full: true, surfaces: c.hasAilerons ? [aileronSpan(from: a0, to: s - 10 - wingTipRadius, what: "booms")] : [], fraction: fA)
            var wingOutline = out.outline, twinMain = out.main
            if wingTipRadius > 0 {
                let r = rounded([wingOutline, twinMain], corners: [Vec2(w.le(s), s), Vec2(w.te(s), s), Vec2(w.le(s), -s), Vec2(w.te(s), -s)], radius: wingTipRadius)
                wingOutline = r[0]; twinMain = r[1]
            }
            for v in [-hw * 0.5, hw * 0.5] {
                wingOutline = Poly.insertTab(wingOutline, at: Vec2(w.le(v), v), width: 10, height: -6)
                twinMain = Poly.insertTab(twinMain, at: Vec2(w.le(v), v), width: 10, height: -6)
            }
            var wingHoles: [Hole] = []
            // Elevator servo lies flat in the right wing between the prop disc and the boom: its pushrod runs aft
            // 12 mm inboard of the boom, outside the prop disc (from the pod it would cross the spinning prop).
            let ePushX = xb - 12
            let eServoX = ePushX - armOffset
            // Same rule as the aileron servos: front edge 5 mm behind the spar groove (one row of servos).
            let sparE = sparAcrossServo(w, eServoX)
            let eServoU = wingServoU(hingeU: w.te(eServoX) - fA * w.chord(eServoX), sparU: sparE)
            wingHoles.append(servoCut("Elevator", center: Vec2(eServoU, eServoX), size: wingServoCut, in: twinMain, arm: (1, t)))
            if !c.isDual && ePushX < propRadius + AircraftConfig.propClearance + 2 {
                issues.append("The elevator pushrod would pass through the prop disc – increase the stabiliser span (boom spacing) or use a smaller prop.")
            }
            if c.hasAilerons {
                let sv = c.servo.size
                let vs = a0 + max(14, sv.h / 2 + 6)
                let hingeU = w.te(vs) - fA * w.chord(vs)
                for side in [-1.0, 1.0] {
                    let name = side < 0 ? "Left aileron" : "Right aileron"
                    let center = Vec2(wingServoU(hingeU: hingeU, sparU: sparAcrossServo(w, vs)), side * vs)
                    wingHoles.append(servoCut(name, center: center, size: wingServoCut, in: out.main, arm: (side, t)))
                    let vh = vs + armOffset, hingeH = w.te(vh) - fA * w.chord(vh)
                    wingHoles.append(hornSlot(at: Vec2(hingeH + 6, side * vh)))
                    let body: SIMD3<Double> = [side * vs, 0, center.x]
                    controls.append(ControlSurface(name: name, hingeMid: [side * (a0 + s) / 2, 0, hingeU], hornPosition: [side * vh, t / 2 + 9, hingeH + 2],
                                                   servoPosition: body, area: Poly.area(out.controls.first ?? []),
                                                   chord: fA * c.rootChord * (1 + c.taper) / 2, servoID: name, armPosition: armTip(body, side: side)))
                }
            }
            var wingFeatures = out.features + sparFeatures(w, from: -s * 0.9, to: 0) + sparFeatures(w, from: 0, to: s * 0.9)
            wingFeatures += [-xb, xb].map { .spar(Vec2(c.rootChord * 0.15, $0), Vec2(w.te($0) - 1, $0), rod.widthMM) }

            // Pod nose plate (horizontal, ahead of the wing) – gives the pod its + section.
            var nose = [Vec2(uN, -W * 0.3), Vec2(uN + 6, -hw), Vec2(w.le(hw), -hw), Vec2(w.le(0), 0), Vec2(w.le(hw), hw), Vec2(uN + 6, hw), Vec2(uN, W * 0.3)]
            for v in [-hw * 0.5, hw * 0.5] { nose = Poly.insertTab(nose, at: Vec2(w.le(v), v), width: 10, height: 6) }

            // Pod halves glued on top and bottom with tabs.
            let hp = fh * 0.5 - t / 2
            let pe = c.rootChord
            var podTop = [Vec2(uN, 0), Vec2(pe, 0), Vec2(pe, hp * 0.45), Vec2(c.rootChord * 0.55, hp), Vec2(uN + 0.35 * c.noseLength, hp * 0.9), Vec2(uN, hp * 0.5)]
            var podBot = [Vec2(uN, 0), Vec2(uN, -hp * 0.5), Vec2(uN + 0.3 * c.noseLength, -hp), Vec2(c.rootChord * 0.6, -hp), Vec2(pe, -hp * 0.4), Vec2(pe, 0)]
            let topTabs = [uN * 0.5, c.rootChord * 0.3, c.rootChord * 0.75].map(clearOfJoiner), botTabs = [uN * 0.3, c.rootChord * 0.5].map(clearOfJoiner)
            for tu in topTabs { podTop = Poly.insertTab(podTop, at: Vec2(tu, 0), width: 10, height: t) }
            for tu in botTabs { podBot = Poly.insertTab(podBot, at: Vec2(tu, 0), width: 10, height: t) }
            wingHoles += centreSlots(topTabs.filter { $0 > 0 } + botTabs.filter { $0 > 0 })
            let noseHoles = centreSlots(topTabs.filter { $0 < 0 } + botTabs.filter { $0 < 0 })

            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.08 + sv.l / 2 + c.servo.earLength, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 2 * c.servo.earLength + 5, s1.y)
            var podHoles: [Hole] = []          // elevator servo sits in the wing (see above)
            if c.hasRudder { podHoles.append(servoCut("Rudders", center: s2, size: webServoCut, in: podTop)) }
            if fh / 2 - t / 2 < 8 { issues.append("Pod height is too small.") }

            tipWinglets(outline: &wingOutline, main: &twinMain, tipV: [-s, s], tipLE: w.le(s))
            parts.append(Part(name: "Wing", role: .wing, outline: wingOutline, holes: wingHoles, features: wingFeatures,
                              regions: c.hasAilerons || c.tailWinglets ? [Region(polygon: twinMain, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) } : [],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Pod nose plate", role: .fuselage, outline: Poly.ccw(nose), holes: noseHoles,
                              features: [.label("NOSE", Vec2(uN * 0.5, 0))], instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Pod top", role: .fuselage, outline: podTop, holes: podHoles,
                              features: [.label("POD TOP", Vec2(uN * 0.4, hp * 0.4))] + truss(from: uN + 20, to: -4, low: { _ in 2.5 }, high: { _ in hp * 0.45 }),
                              instances: [.vertical(at: [0, t / 2, 0])], material: c.material))
            parts.append(Part(name: "Pod bottom", role: .fuselage, outline: podBot,
                              features: [.label("POD BOTTOM", Vec2(uN * 0.3, -hp * 0.5)),
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -c.battery.size.w / 2 - 1), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: [.vertical(at: [0, -t / 2, 0])], material: c.material))

            // Stabiliser on the booms with twin fins.
            let sh = c.hStabSpan / 2
            // Rectangular stabiliser with a one-piece elevator across the full span between the fins
            // (end slots give it clearance at both ends).
            let uHs = ta + hsc * 0.6, ue = ta + hsc, eb = sh - 14, g = TaperedPanel.endGap
            // Swept leading edge (stab sweep), straight trailing edge and hinge.
            let sw = c.hStabSweep
            let leS = { (v: Double) in ta + sw * abs(v) / max(sh, 1) }
            let le3 = [Vec2(ta + sw, -sh), Vec2(ta, 0), Vec2(ta + sw, sh)]
            let soOutline = Poly.ccw(le3 + [Vec2(ue, sh), Vec2(ue, eb), Vec2(uHs, eb), Vec2(uHs, eb - g), Vec2(ue, eb - g),
                                      Vec2(ue, -(eb - g)), Vec2(uHs, -(eb - g)), Vec2(uHs, -eb), Vec2(ue, -eb), Vec2(ue, -sh)])
            let soMain = Poly.ccw(le3 + [Vec2(ue, sh), Vec2(ue, eb), Vec2(uHs, eb), Vec2(uHs, -eb), Vec2(ue, -eb), Vec2(ue, -sh)])
            if leS(eb) > uHs - 8 { issues.append("Stabiliser sweep too large – the leading edge reaches the elevator hinge. Reduce the stab sweep or increase the stab chord.") }
            let soElevator = Poly.ccw([Vec2(uHs, -(eb - g)), Vec2(uHs, eb - g), Vec2(ue, eb - g), Vec2(ue, -(eb - g))])
            var stabHoles: [Hole] = []
            // Twin fins are end plates glued to the SIDE of the stabiliser tips (tip tabs into fin slots).
            let fin0 = sideFin(chord: c.vStabChord, height: c.vStabHeight, below: max(10, c.vStabHeight * 0.2), rudderFrac: c.hasRudder ? 0.4 : 0)
            var fin = fin0
            if finTopRadius > 0 {
                // Same top corners as sideFin: rudder (or fin) trailing edge top and the fin's leading edge top.
                let fc = c.vStabChord, h = c.vStabHeight
                let topLE = min(h * 0.55 + fc * 0.25, fc * 0.75 + h * 0.2)
                let topTE = c.hasRudder ? fc : fc + h * 0.2
                let r = rounded([fin.outline, fin.main] + (fin.rudder.map { [$0] } ?? []), corners: [Vec2(topTE, h), Vec2(topLE, h)], radius: finTopRadius)
                fin.outline = r[0]; fin.main = r[1]
                if fin.rudder != nil { fin.rudder = r[2] }
            }
            let finU0 = ta + hsc - c.vStabChord
            var stabOutline = soOutline
            var stabRegions = [Region(polygon: soMain, isControl: false), Region(polygon: soElevator, isControl: true)]
            // With a swept stabiliser the tip is shorter: the fin may overhang ahead of it, only tabs that land on the
            // tip edge are used (and only their slots cut in the fin).
            let usableTabs = fin.tabs.filter { finU0 + $0 - 5 > ta + sw + 1 && finU0 + $0 + 5 < ue - 1 }
            fin.slots = fin.slots.enumerated().filter { usableTabs.contains(fin.tabs[$0.offset]) }.map(\.element)
            if usableTabs.isEmpty { issues.append("The swept stabiliser tip is too short to carry the fins – reduce the stab sweep or increase the stab chord.") }
            for v in [-sh, sh] {
                for tu in usableTabs {
                    stabOutline = Poly.insertTab(stabOutline, at: Vec2(finU0 + tu, v), width: 10, height: t)
                    stabRegions[0].polygon = Poly.insertTab(stabRegions[0].polygon, at: Vec2(finU0 + tu, v), width: 10, height: t)
                }
            }
            let eHorn = Vec2(ta + hsc * 0.6 + 6, ePushX)          // straight behind the wing servo's arm
            stabHoles.append(hornSlot(at: eHorn))
            let stabY = boomY + 2 + t / 2
            parts.append(Part(name: "Stabiliser", role: .stabilizer, outline: stabOutline, holes: stabHoles,
                              features: [Feature.hinge(Vec2(uHs, -(eb - g)), Vec2(uHs, eb - g))] + [-xb, xb].map { .spar(Vec2(leS($0), $0), Vec2(ta + hsc * 0.55, $0), rod.widthMM) },
                              regions: stabRegions, instances: [.horizontal(at: [0, stabY, 0])], material: c.material))
            if finU0 < ta { issues.append("Fin chord is longer than the stabiliser chord.") }

            let finInst = [-1.0, 1.0].map { Placement(origin: [$0 * (sh + t / 2), stabY, finU0], u: [0, 0, 1], v: [0, 1, 0]) }
            var finRegions = [Region(polygon: fin.main, isControl: false)]
            if let r = fin.rudder { finRegions.append(Region(polygon: r, isControl: true)) }
            let rHingeU = c.vStabChord * 0.6
            parts.append(Part(name: "Fin", role: .fin, outline: fin.outline,
                              holes: fin.slots + (c.hasRudder ? [hornSlot(at: Vec2(rHingeU + 6, 14))] : []),
                              features: (c.hasRudder ? [.hinge(Vec2(rHingeU, 0), Vec2(rHingeU, c.vStabHeight))] : []) + [.label("FIN", Vec2(c.vStabChord * 0.3, c.vStabHeight * 0.4))],
                              regions: c.hasRudder ? finRegions : [], instances: finInst, material: c.material))

            if !c.isDual && xb < propRadius + 6 { issues.append("Booms are inside the propeller disc – increase the stabiliser span (boom spacing) or use a smaller prop.") }

            let boomLen = ta + hsc * 0.55 - c.rootChord * 0.15
            components.append(MassItem(name: "Tail booms (2 × \(rod.name))", mass: 2 * boomLen / 1000 * rod.gramsPerMeter,
                                       position: [0, boomY, c.rootChord * 0.15 + boomLen / 2], category: "Hardware"))

            let eBody: SIMD3<Double> = [eServoX, 0, eServoU]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, stabY, ta + hsc * 0.6], hornPosition: [eHorn.y, stabY + t / 2 + 9, ta + hsc * 0.6 + 2],
                                           servoPosition: eBody, area: Poly.area(soElevator), chord: 0.4 * hsc, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            let rudderArea = (fin.rudder.map { Poly.area($0) } ?? 0) * 2
            if c.hasRudder { controls.append(ControlSurface(name: "Rudders", hingeMid: [sh + t / 2, stabY + c.vStabHeight / 2, finU0 + rHingeU],
                                           hornPosition: [-sh + 8, stabY + 14, finU0 + rHingeU + 2],
                                           servoPosition: [0, t / 2 + s2.y, s2.x], area: rudderArea, chord: 0.4 * c.vStabChord, servoID: "Rudders",
                                           armPosition: armTip([0, t / 2 + s2.y, s2.x], side: -1), hornAxis: [1, 0, 0])) }

            batteryPos = [t / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
        }

        // MARK: NutBall – round flat wing, elevator across the trailing edge, centre spine + fin, tractor motor

        mutating func buildNutBall() {
            let L = c.rootChord, S = s, f = c.controlChordPct
            let fh = c.fuselageHeight, vsc = c.vStabChord
            let uN = -c.noseLength
            // Elliptic disc, parameter θ: u = L/2·(1 − cos θ), v = S·sin θ (θ = 0 nose, π tail).
            func pt(_ th: Double) -> Vec2 { Vec2(L / 2 * (1 - cos(th)), S * sin(th)) }
            func arc(_ a: Double, _ b: Double) -> [Vec2] {
                let n = max(4, Int((b - a) / (.pi / 60)))
                return (0...n).map { pt(a + (b - a) * Double($0) / Double(n)) }
            }
            func mirrored(_ r: [Vec2]) -> [Vec2] { r.reversed().map { Vec2($0.x, -$0.y) } }
            let uH = L * (1 - f)                                  // elevator hinge line
            let thH = acos(min(1, max(-1, 1 - 2 * uH / L)))
            let rudderChord = max(0.4 * vsc, 18.0)
            // Nose tongue in front of the disc carries the + clamp of the motor mount.
            let mountHalf = PrintedParts.motorMountPlate(c.motor, foam: t) / 2
            let nw = max(mountHalf, 10.0)
            let thN = asin(min(1, nw / S))
            let tongue = c.noseLength > 1 ? [Vec2(uN, nw)] : []
            // One-piece elevator: the rear segment of the disc behind a straight hinge, running under the rudder.
            let rOutline = tongue + arc(thN, .pi)
            let rMain = tongue + arc(thN, thH)
            let outline = Poly.ccw(rOutline + mirrored(Array(rOutline.dropLast())))
            let mainRegion = Poly.ccw(rMain + mirrored(rMain))
            let rElev = arc(thH, .pi)
            let elevator = Poly.ccw(rElev + mirrored(Array(rElev.dropLast())))
            if !Poly.isSimple(outline) { issues.append("Disc outline intersects itself – increase the width or reduce the elevator depth.") }

            // --- Spine (with fin + rudder) on top, keel below – the + section the motor mount clamps onto.
            let hs = fh * 0.5 - t / 2, hk = fh * 0.5 - t / 2
            let finTop = max(c.vStabHeight, hs + 15)
            let finLE = uH - vsc
            if finLE < L * 0.35 { issues.append("Fin chord is too long – the fin would reach the servos. Reduce the fin chord or the elevator depth.") }
            let noseFront = min(hs, max(mountHalf - t / 2 - 0.5, 4))
            let rg = TaperedPanel.endGap
            let uR = uH + rudderChord
            // Cut-out at the bottom of the rudder so the elevator can deflect up underneath it (full throw + 5°).
            let cut = finCut(elevChord: f * L, rg: rg)
            let cutEdge = cut.edge(0, uR - uH).map { Vec2(uH + $0.x, $0.y) }
            let rHornV = max(rudderHornV(uH: uH, elevChord: f * L, tw: t), cut.v(6) + 8)
            // Elevator and rudder servos just ahead of the CG, centred on the disc as on the cross-fuselage types: half in
            // the spine, half in the keel, through flush openings in the disc.
            let sv = c.servo.size
            let uEN = L * 0.12 + sv.l / 2 + c.servo.earLength
            var uRN = uEN + sv.l + 2 * c.servo.earLength + 5
            // Both ahead of the spar where they fit (ears included), otherwise the rudder servo goes behind it.
            let sparU = L * 0.3, sparH = c.sparEnabled ? c.sparSpec.widthMM / 2 : 1.5
            if c.sparEnabled && uRN + sv.l / 2 + c.servo.earLength + 2 > sparU - sparH {
                uRN = max(uRN, sparU + sparH + 2 + sv.l / 2 + c.servo.earLength)
            }
            let servoUs = [uEN, uRN]
            let upNotch = centredServoNotches(servoUs, sign: 1)
            var upper: [Vec2] = [Vec2(uN, 0)] + upNotch + [Vec2(uH, 0)] + cutEdge + [Vec2(uR, finTop), Vec2(uH - 0.25 * vsc, finTop), Vec2(finLE, hs),
                                 Vec2(uN + 15, hs), Vec2(uN, noseFront)]
            var upperMain: [Vec2] = [Vec2(uN, 0)] + upNotch + [Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.25 * vsc, finTop), Vec2(finLE, hs), Vec2(uN + 15, hs), Vec2(uN, noseFront)]
            let earReach = sv.l / 2 + c.servo.earLength + 7
            let clearOfServos = { (u: Double) in servoUs.allSatisfy { abs(u - $0) > earReach } }
            var rudder = cutEdge + [Vec2(uR, finTop), Vec2(uH, finTop)]
            if finTopRadius > 0 {        // rounded rudder / fin top corners (as on the tailed planes)
                let r = rounded([upper, upperMain, rudder], corners: [Vec2(uR, finTop), Vec2(uH - 0.25 * vsc, finTop)], radius: finTopRadius)
                upper = r[0]; upperMain = r[1]; rudder = r[2]
            }
            let upTabs = [L * 0.06, L * 0.4, finLE + vsc * 0.35].filter { $0 + 6 < uH && $0 - 6 > uN && clearOfServos($0) }
            var upperOut = upper
            for tu in upTabs {
                upperOut = Poly.insertTab(upperOut, at: Vec2(tu, 0), width: 10, height: t)
                upperMain = Poly.insertTab(upperMain, at: Vec2(tu, 0), width: 10, height: t)
            }
            let noseFrontLow = min(hk, max(mountHalf - t / 2 - 0.5, 4))
            let kEnd = L * 0.62
            // (top edge runs from the keel end forward: notches in decreasing u)
            let loNotch = Array(centredServoNotches(servoUs, sign: -1).reversed())
            let lower: [Vec2] = [Vec2(uN, 0), Vec2(uN, -noseFrontLow), Vec2(uN + 20, -hk), Vec2(L * 0.45, -hk), Vec2(kEnd, 0)] + loNotch
            let loTabs = [L * 0.12, L * 0.36].filter { $0 + 6 < kEnd && clearOfServos($0) }
            var lowerOut = lower
            for tu in loTabs { lowerOut = Poly.insertTab(lowerOut, at: Vec2(tu, 0), width: 10, height: t) }

            var discHoles = centreSlots(upTabs + loTabs)
            // Elevator horn under the elevator on the left, straight behind the servo arm (the pushrod runs under the disc).
            let eHornV = max(armOffset, t / 2 + 10)
            discHoles.append(hornSlot(at: Vec2(uH + 6, -eHornV), under: true))
            // Disc openings: elevator servo shaft on the left (arm down), rudder servo shaft on the right (arm up).
            for (name, u, side) in [("Elevator", uEN, -1.0), ("Rudder", uRN, 1.0)] {
                let o = centredServoOpening(u, side: side, tw: t)
                if !Poly.containsAll(mainRegion, o) { issues.append("The \(name.lowercased()) servo opening does not fit in the disc – pick a smaller servo.") }
                discHoles.append(Hole(kind: .servo, polygon: o, note: name))
            }
            let upperHoles = [hornSlot(at: Vec2(uH + 6, rHornV))]

            let us = L * 0.3
            let vs = S * sin(acos(min(1, max(-1, 1 - 2 * us / L)))) * 0.88
            var features: [Feature] = [.hinge(Vec2(uH, -pt(thH).y), pt(thH)), .label("NUTBALL", Vec2(L * 0.55, S * 0.35))]
            if c.sparEnabled { features.append(.rod(Vec2(us, -vs), Vec2(us, vs), c.sparSpec.widthMM)) }
            nutBallWinglets(holes: &discHoles, features: &features, uHinge: uH)
            parts.append(Part(name: "Disc wing", role: .wing, outline: outline, holes: discHoles, features: features,
                              regions: [Region(polygon: mainRegion, isControl: false), Region(polygon: elevator, isControl: true)],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Spine & fin", role: .fuselage, outline: upperOut, holes: upperHoles,
                              features: [.hinge(Vec2(uH, 0), Vec2(uH, finTop)), .label("SPINE", Vec2(L * 0.3, hs * 0.5))],
                              regions: [Region(polygon: upperMain, isControl: false), Region(polygon: rudder, isControl: true)],
                              instances: [.vertical(at: [0, t / 2, 0])], material: c.material))
            parts.append(Part(name: "Keel", role: .fuselage, outline: lowerOut,
                              features: [.label("KEEL", Vec2(L * 0.3, -hk * 0.5)),
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -(c.batteryTop - t / 2) - c.battery.size.w / 2), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: [.vertical(at: [0, -t / 2, 0])], material: c.material))

            // Elevator servo arm down on the left, rudder servo arm up on the right: the pushrods never cross or pass
            // through the disc.
            let eBody: SIMD3<Double> = [0, 0, uEN]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [-eHornV, -(t / 2 + 9), uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: f * L * 0.7, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: -1, down: true), hornAxis: [0, -1, 0]))
            let rBody: SIMD3<Double> = [0, 0, uRN]
            controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [t / 2 + 8, t / 2 + rHornV, uH + 2],
                                           servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                           armPosition: armTip(rBody, side: 1), hornAxis: [1, 0, 0]))
            batteryPos = [t / 2 + c.battery.size.h / 2, -c.batteryTop - c.battery.size.w / 2, c.batteryPosition]
        }

        mutating func nutBallWinglets(holes: inout [Hole], features: inout [Feature], uHinge: Double) {
            guard c.tailWinglets, c.wingletHeight > 5 else { return }
            let st = c.nutBallWinglet
            let fin = finOutline(chord: st.chord, height: c.wingletHeight)
            for v in [-st.v, st.v] {
                for tu in fin.tabs { holes.append(slot(minU: st.u0 + tu - 4, maxU: st.u0 + tu + 4, minV: v - t / 2, maxV: v + t / 2)) }
                // Footprint on the disc plan: where the winglet stands (its two tabs go into the slots).
                features.append(.zone(Poly.rect(minU: st.u0, maxU: st.u0 + st.chord, minV: v - t / 2, maxV: v + t / 2), "WINGLET"))
            }
            if st.u0 + st.chord > uHinge { issues.append("Winglets reach the elevator hinge – make the disc longer or the elevator shallower.") }
            parts.append(Part(name: "Winglet", role: .winglet, outline: fin.outline,
                              features: [.label("WINGLET", Vec2(st.chord * 0.45, c.wingletHeight * 0.4))],
                              instances: [-st.v, st.v].map { Placement(origin: [$0, t / 2, st.u0], u: [0, 0, 1], v: [0, 1, 0]) },
                              material: c.material))
        }

        // MARK: Electronics & hardware

        mutating func addElectronics() {
            let pusher = c.isPusher
            let motorZ = c.motorZ
            for (i, x) in c.motorXs.enumerated() {
                let tag = c.isDual ? (i == 0 ? " (left)" : " (right)") : ""
                components.append(MassItem(name: c.motor.name + tag, mass: c.motor.mass, position: [x, 0, motorZ], category: "Power"))
                components.append(MassItem(name: "Propeller\(tag)", mass: c.propInches * 0.35 * (c.customProp ? Double(c.propBladeCount) / Double(c.kind.propBlades) : 1),
                                          position: [x, 0, c.propPlaneZ], category: "Power"))
                components.append(MassItem(name: "Motor mount (printed)\(tag)", mass: 1.5 + c.motor.mass * 0.12, position: [x, 0, c.firewallZ], category: "Printed"))
                components.append(MassItem(name: "ESC\(tag)", mass: c.motor.escMass, position: escPosition(motorX: x), category: "Power"))
            }
            if c.isDual {
                // Mark both motor stations on the wing plan (mount plate + clamp, prop clearance).
                for i in parts.indices where parts[i].role == .wing {
                    let half = parts[i].mirroredPair
                    let offset = half ? (parts[i].instances.first?.origin.x ?? 0) : 0
                    for x in (half ? [c.dualMotorX] : c.motorXs) {
                        let v = half ? x - offset : x
                        let u = c.sweep * abs(x) / c.semiSpan
                        parts[i].features.append(.zone(Poly.rect(minU: u, maxU: u + 20, minV: v - c.motor.bellDiameter / 2 - 3, maxV: v + c.motor.bellDiameter / 2 + 3), "MOTOR"))
                    }
                }
                if c.dualMotorX + propRadius > s - 5 { issues.append("The motors are too far out – props would overhang the wing tips. Use smaller props or more span.") }
            }
            components.append(MassItem(name: "Receiver", mass: 2.5, position: receiverPosition, category: "Radio"))
            if c.isDual {
                // Printed nose protector – there is no motor on the nose any more.
                let z = c.kind.isTailless ? 2.0 : -c.noseLength - 1
                components.append(MassItem(name: "Nose protector (printed)", mass: c.kind.isTailless ? 1.0 : 2.0, position: [0, 0, z], category: "Printed"))
            }
            components.append(MassItem(name: "Wiring & connectors", mass: c.isDual ? 4.5 : 3, position: [0, 0, c.rootChord * 0.15], category: "Radio"))
            placeBatteryClearOfPushrods()
            components.append(MassItem(name: c.battery.name, mass: c.battery.mass, position: batteryPos, category: "Battery"))

            var seenServos = Set<String>()
            for ctrl in controls {
                if seenServos.insert(ctrl.servoID).inserted {
                    components.append(MassItem(name: "Servo – \(ctrl.servoID)", mass: c.servo.mass, position: ctrl.servoPosition, category: "Radio"))
                }
                components.append(MassItem(name: "Horn – \(ctrl.name)", mass: 0.3, position: ctrl.hornPosition - ctrl.hornAxis * 4, category: "Printed"))
                let arm = ctrl.armPosition == .zero ? ctrl.servoPosition : ctrl.armPosition
                let len = simd_distance(arm, ctrl.hornPosition)
                components.append(MassItem(name: "Pushrod – \(ctrl.name)", mass: len / 1000 * 1.6 + 0.2,
                                           position: (arm + ctrl.hornPosition) / 2, category: "Hardware"))
            }
            if c.sparEnabled {
                // Top and bottom strip.
                components.append(MassItem(name: "\(c.sparSpec.name) wing spar", mass: c.sparLength / 1000 * c.sparSpec.gramsPerMeter,
                                           position: [0, 0, c.rootChord * 0.3 + c.sweep * 0.45], category: "Hardware"))
                if c.hasSparJoiner {
                    components.append(MassItem(name: "Spar joiner (printed)", mass: PrintedParts.sparJoinerMass(c),
                                               position: [0, -t / 2 + c.sparSpec.widthMM / 2, c.sparRootU], category: "Printed"))
                }
            }
            if trussLength > 0 {
                components.append(MassItem(name: "Carbon truss strips 3 × 0.5 mm", mass: trussLength / 1000 * CarbonSpar.flat3x05.gramsPerMeter,
                                           position: [0, 0, c.kind.hasFuselage ? (c.rootChord + c.tailArm) / 2 : c.rootChord * 0.4], category: "Hardware"))
            }
            var foam = 0.0, moment = SIMD3<Double>.zero
            for p in parts {
                for inst in p.instances { foam += p.massEach; moment += inst.point(p.centroid2D) * p.massEach }
            }
            if foam > 0 {
                components.append(MassItem(name: "Glue, tape, velcro", mass: foam * 0.07, position: moment / foam, category: "Hardware"))
            }
        }
    }
}


extension Design {
    /// Receiver channels needed: one per servo plus the throttle (the ESCs of a dual layout share it via a Y-lead).
    var channels: Int { Set(controls.map(\.servoID)).count + 1 }

    /// Receiver channel assignment in the usual AETR order: aileron (elevon / rudder on 2-channel planes),
    /// elevator, throttle, rudder, then any extra servo (second aileron).
    var channelPlan: [(channel: Int, function: String)] {
        var servos = controls.map(\.servoID).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func take(_ pred: (String) -> Bool) -> String? {
            guard let i = servos.firstIndex(where: pred) else { return nil }
            return servos.remove(at: i)
        }
        let throttle = config.isDual ? "Throttle (both ESCs, Y-lead)" : "Throttle (ESC)"
        var plan: [String] = []
        let aileron = take { $0.contains("aileron") || $0.contains("Ailerons") || $0.contains("elevon") }
        let elevator = take { $0.hasPrefix("Elevator") || $0.contains("elevon") }
        if let aileron { plan.append(aileron) } else if let r = take({ $0.hasPrefix("Rudder") }) { plan.append(r) }
        if let elevator { plan.append(elevator) }
        plan.append(throttle)
        if let r = take({ $0.hasPrefix("Rudder") }) { plan.append(r) }
        plan += servos
        return plan.enumerated().map { ($0.offset + 1, $0.element) }
    }
}

extension AircraftConfig {
    /// NutBall winglet station: the disc edge is rounded, so the winglets stand ON TOP of the disc, inboard of
    /// the edge (a plain fin with tabs pushed through slots in the disc, like the spine). Lateral station, base
    /// leading edge and base chord – the base stays on the fixed disc ahead of the elevator hinge.
    var nutBallWinglet: (v: Double, u0: Double, chord: Double) {
        let L = rootChord, S = semiSpan
        let v = S * 0.8
        let cosT = (1 - pow(v / S, 2)).squareRoot()               // disc at v: u = L/2·(1 ∓ cos θ)
        let uLE = L / 2 * (1 - cosT) + 6
        let uEnd = min(L * (1 - controlChordPct) - 4, L / 2 * (1 + cosT) - 6)
        let chord = max(20, min(L * 0.32, uEnd - uLE))
        return (v, uEnd - chord, chord)
    }
}
