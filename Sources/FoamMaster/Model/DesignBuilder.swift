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
    var dualMotorX: Double { propRadius + dualBodyHalfWidth + AircraftConfig.propClearance }
    /// Half width of whatever sits between the two props (centre fin / keel, or fuselage plate / pod).
    var dualBodyHalfWidth: Double {
        kind.isTailless ? (taillessFins == .centreFin ? material.thickness / 2 + 2 : 4) : fuselagePlateWidth / 2 + 2
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
    var propInches: Double { kind.isJet ? min(motor.propInches, 4) : motor.propInches }
    var propRadius: Double { propInches * 25.4 / 2 }
    var propRecommendation: String {
        motor.propRecommendation(cells: battery.cells, pusher: isPusher, blades: kind.propBlades, pair: isDual, diameter: propInches)
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
    static let rudderCutSlope = tan(35.0 * .pi / 180)
    /// Foam left above / below the jet's prop window.
    static let jetFrameRim = 8.0

    static func build(_ input: AircraftConfig) -> Design {
        // (the jet's fuselage is kept taller than its prop window)
        var c = input
        c.fuselageHeight = max(c.fuselageHeight, c.minFuselageHeight)
        var b = Builder(c: c)
        b.run()
        return Design(config: c, parts: b.parts, components: b.components, controls: b.controls,
                      servoCutouts: b.servoCutouts, geometryIssues: b.issues, trussLength: b.trussLength)
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
            if c.isDual { return [x * 0.8, t / 2 + e.z / 2, c.rootChord * 0.3] }                         // on the wing behind its motor
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
        var finTopRadius: Double { c.kind.hasTail ? max(0, c.finTopRounding) : 0 }
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
        /// Station: about 55 mm ahead of the aileron hinge so the pushrods run mostly fore-aft.
        var ailServoU: Double {
            let hw = c.fuselagePlateWidth / 2, w = wing
            let hinge = w.te(hw) - c.controlChordPct * w.chord(hw)
            return max(c.rootChord * 0.06 + c.servo.size.l / 2, min(hinge - 55, c.rootChord * 0.55))
        }
        var ailShaftU: Double { ailServoU + c.servo.size.l / 2 - 5 }
        /// Half length of the double arm (hole to hub) – longer for bigger servos.
        var ailArm: Double { [.g17: 7.0, .g25: 8, .g37: 9, .g5: 10][c.servo]! }
        var ailArmY: Double { -t / 2 - c.servo.size.h - 2 }
        var ailServoCenter: SIMD3<Double> { [0, -t / 2 - c.servo.size.h / 2, ailServoU] }
        /// Window in the lower fuselage web for the servo body and the arm hub, with clearance below the arm.
        var ailWindow: (u0: Double, u1: Double, h: Double) {
            let sv = c.servo.size
            return (ailServoU - sv.l / 2 - 1, ailServoU + sv.l / 2 + 1, sv.h + 2 + 1.5 + 3)
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
            addElectronics()
        }

        // MARK: Helpers

        mutating func servoCut(_ name: String, center: Vec2, size: Vec2, in region: [Vec2], avoid: [[Vec2]] = []) -> Hole {
            let r = Poly.rect(center: center, size: size + Vec2(0.4, 0.4))
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
        func armTip(_ center: SIMD3<Double>, side: Double) -> SIMD3<Double> {
            let sv = c.servo.size
            return center + [side * (sv.h / 2 + 2), 10, sv.l / 2 - 5]
        }
        /// Sideways offset of the arm (and horn) from the servo centre so the pushrod is straight.
        var armOffset: Double { c.servo.size.h / 2 + 2.5 }
        /// Wing cutout (lying flat) and fuselage-web cutout sizes in plan coordinates (u, v).
        var wingServoCut: Vec2 { Vec2(c.servo.size.l, c.servo.size.h) }
        var webServoCut: Vec2 { Vec2(c.servo.size.l, c.servo.size.w) }

        func hornSlot(at p: Vec2, alongU: Bool = true) -> Hole {
            let size = alongU ? Vec2(10, 1.6) : Vec2(1.6, 10)
            return Hole(kind: .hornSlot, polygon: Poly.rect(center: p, size: size), note: "horn")
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
                let center = Vec2(hingeU - 10 - sv.l / 2, side * vs)
                let name = side < 0 ? "Left elevon" : "Right elevon"
                holes.append(servoCut(name, center: center, size: wingServoCut, in: mainRegion))
                let vh = vs + armOffset, hingeH = w.te(vh) - f * w.chord(vh)
                holes.append(hornSlot(at: Vec2(hingeH + 6, side * vh)))
                let body: SIMD3<Double> = [center.y, 0, center.x]
                controls.append(ControlSurface(name: name,
                                               hingeMid: [side * (v0 + v1) / 2, 0, w.te((v0 + v1) / 2) - f * w.chord((v0 + v1) / 2)],
                                               hornPosition: [side * vh, t / 2 + 9, hingeH + 2], servoPosition: body,
                                               area: Poly.area(out.controls.first ?? []), chord: f * c.rootChord * (1 + c.taper) / 2, servoID: name,
                                               armPosition: armTip(body, side: side)))
            }

            // Winglets / centre fin with tabs into the wing.
            let finHeight = c.wingletHeight
            if finHeight > 5 && c.taillessFins == .centreFin {
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
            } else if finHeight > 5 && c.taillessFins == .winglets {
                // Winglets are glued to the SIDE of the wing tip: tip tabs go through slots in the winglet.
                let wl = sideFin(chord: c.tipChord, height: finHeight)
                for v in [-s, s] {
                    for tu in wl.tabs {
                        outline = Poly.insertTab(outline, at: Vec2(w.le(v) + tu, v), width: 10, height: t)
                        mainRegion = Poly.insertTab(mainRegion, at: Vec2(w.le(v) + tu, v), width: 10, height: t)
                    }
                }
                parts.append(Part(name: "Winglet", role: .winglet, outline: wl.outline, holes: wl.slots,
                                  features: [.label("WINGLET", Vec2(c.tipChord * 0.45, finHeight * 0.45))],
                                  instances: [-1.0, 1.0].map { Placement(origin: [$0 * (s + t / 2), 0, w.le(s)], u: [0, 0, 1], v: [0, 1, 0]) },
                                  material: c.material))
            }

            // Centre keel under the wing (reinforcement strip, stays within the chord) – carries the motor mount clamp.
            let k0 = 10.0
            let k1 = single ? w.te(0) - nd : w.te(0) - 12
            let hk = max(12, min(20, c.rootChord * 0.08))
            if k1 - k0 > 40 {
                var keel = [Vec2(k0, 0), Vec2(k0 + hk, -hk), Vec2(k1, -hk), Vec2(k1, 0)]
                let tabs = [k0 + (k1 - k0) * 0.3, k0 + (k1 - k0) * 0.75]
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
            let a0 = central ? 3 : max(8, s * 0.3 - hw)
            let surfaces: [ClosedRange<Double>] = c.hasAilerons ? [a0...(span - 10 - wingTipRadius)] : []
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
                    let center = Vec2(hingeU - 8 - sv.l / 2, vs)
                    holes.append(servoCut("Aileron", center: center, size: wingServoCut, in: main))
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
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc * 0.8, sweep: hsc * 0.1, semiSpan: sh)
            // One-piece elevator on a straight hinge across the whole stabiliser (it runs under the rudder).
            let uH = stab.te(0) - ef * stab.chord(0)
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
            // Notch in the top edge of the lower half (listed aft → forward, like that edge).
            let ailNotch: [Vec2] = centralAileron ? [Vec2(aw.u1, 0), Vec2(aw.u1, -aw.h), Vec2(aw.u0, -aw.h), Vec2(aw.u0, 0)] : []
            let hasAilServo = centralAileron
            let clearOfAileronServo = { (u: Double) in !hasAilServo || u + 6 < aw.u0 - 2 || u - 6 > aw.u1 + 2 }
            let hBoom = c.boomTopHeight
            let finTop = hBoom + c.vStabHeight
            let finLE = uH - 1.25 * vsc
            if finLE < ub + 10 { issues.append("Fin is too long for the tail arm – fin leading edge reaches the wing.") }
            let rg = c.hasRudder ? TaperedPanel.endGap : 0     // rudder clears the plate / elevator by this gap
            // Cut-out at the bottom of the rudder (or fixed fin) so the one-piece elevator can move up under it.
            let rCut = rg + rudderChord * DesignBuilder.rudderCutSlope
            var upper: [Vec2] = [Vec2(uN, 0), Vec2(uH, 0)] + (rg > 0 ? [Vec2(uH, rg)] : []) + [Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                 Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, noseFront)]
            var upperMain: [Vec2] = [Vec2(uN, 0), Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                     Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, noseFront)]
            var rudder = [Vec2(uH, rg), Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH, finTop)]
            if finTopRadius > 0 {        // rounded fin / rudder top corners
                let r = rounded([upper, upperMain, rudder], corners: [Vec2(uR, finTop), Vec2(uH - 0.3 * vsc, finTop)], radius: finTopRadius)
                upper = r[0]; upperMain = r[1]; rudder = r[2]
            }
            let hasRudder = c.hasRudder
            if !hasRudder { upperMain = upper }
            let layers = Double(c.fuselageType.webLayers)
            let tw = t * layers
            let upTabs = [uN + max(32, c.noseLength * 0.45), c.rootChord * 0.45, (c.rootChord + finLE) / 2, finLE + vsc * 0.5].filter { $0 + 6 < uH }
            var upperOut = upper
            for tu in upTabs { upperOut = Poly.insertTab(upperOut, at: Vec2(tu, 0), width: 10, height: t); upperMain = Poly.insertTab(upperMain, at: Vec2(tu, 0), width: 10, height: t) }

            let uL = ta + hsc * 0.35
            let hLowWing = fh * 0.5 - t / 2
            let lower: [Vec2] = [Vec2(uN, 0), Vec2(uN, -noseFrontLow), Vec2(uN + 0.3 * c.noseLength, -hLowWing), Vec2(c.rootChord * 0.85, -hLowWing),
                                 Vec2(uL, -c.lowerTailHeight), Vec2(uL, 0)] + ailNotch
            let loTabs = [uN + max(44, c.noseLength * 0.6), c.rootChord * 0.75, (c.rootChord + ta) / 2 + 15].filter { $0 + 6 < uL && clearOfAileronServo($0) }
            var lowerOut = lower
            for tu in loTabs { lowerOut = Poly.insertTab(lowerOut, at: Vec2(tu, 0), width: 10, height: t) }

            // Plate slots for both halves (all on the centre line, at different stations).
            var plateHoles = (upTabs + loTabs).map { slot(minU: $0 - 5, maxU: $0 + 5, minV: -tw / 2, maxV: tw / 2) }
            // Elevator horn beside the rudder, outside its sideways swing.
            let eHornV = max(armOffset, tw / 2 + 10)
            plateHoles.append(hornSlot(at: Vec2(uH + 6, eHornV)))

            // Servos in the upper half above the plate.
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.06 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            var upperHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: upperMain)]
            if hasRudder {
                upperHoles.append(servoCut("Rudder", center: s2, size: webServoCut, in: upperMain))
                upperHoles.append(hornSlot(at: Vec2(uH + 6, rg + 6 * DesignBuilder.rudderCutSlope + 8)))
            }
            let lowerHoles: [Hole] = []
            if centralAileron && aw.h > hLowWing - 6 {
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
                                         .label("PLATE", Vec2(c.rootChord * 0.5, 0))] + sparFeatures(w, from: -hw, to: hw),
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
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -c.battery.size.w / 2 - 1), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")] + lowerTruss,
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))

            let eBody: SIMD3<Double> = [0, t / 2 + s1.y, s1.x]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [eHornV, t / 2 + 9, uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: ef * hsc * 0.9, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            if hasRudder {
                // Rudder horn on the left side of the rudder, servo arm on the left: pushrods never cross.
                let rBody: SIMD3<Double> = [0, t / 2 + s2.y, s2.x]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [-(tw / 2 + 8), t / 2 + 14, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: -1), hornAxis: [-1, 0, 0]))
            }

            batteryPos = [tw / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
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
            let out = w.build(full: true, surfaces: c.hasAilerons ? [a0...(s - 8 - wingTipRadius)] : [], fraction: fA)
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
                    let center = Vec2(hingeU - 8 - sv.l / 2, side * vs)
                    wingHoles.append(servoCut(name, center: center, size: wingServoCut, in: wingMain))
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
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc * 0.55, sweep: hsc * 0.45, semiSpan: sh)
            let uH = stab.te(0) - 0.4 * hsc
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
            let rCut = rgJ + rudderChord * DesignBuilder.rudderCutSlope        // cut-out over the elevator
            let window: [Vec2] = [Vec2(wF, 0), Vec2(wF, wH), Vec2(wR, wH), Vec2(wR, 0)]
            let topLine: [Vec2] = [Vec2(finLE, hBoom), Vec2(wR + 18, hFrame), Vec2(wF - 18, hFrame), Vec2(c.rootChord * 0.2, max(hCanopy, hFrame)),
                                   Vec2(-0.3 * c.noseLength, hCanopy * 0.85), Vec2(uN + 0.45 * c.noseLength, hCanopy * 0.4), Vec2(uN + 12, 3)]
            var upper = [Vec2(uN + 12, 0)] + window + [Vec2(uH, 0)] + (rgJ > 0 ? [Vec2(uH, rgJ)] : []) +
                [Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH - 0.35 * vsc, finTop)] + topLine
            var upperMain = [Vec2(uN + 12, 0)] + window + [Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.35 * vsc, finTop)] + topLine
            var rudder = [Vec2(uH, rgJ), Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH, finTop)]
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
            let clearOfWindow = { (u: Double) in u + 8 < wF || u - 8 > wR }
            let upTabs = [uN + 0.6 * c.noseLength, c.rootChord * 0.15, (te0 + ta) / 2, ta + hsc * 0.2].filter { clearOfWindow($0) && $0 + 8 < uH }
            let loTabs = [uN + 0.7 * c.noseLength, c.rootChord * 0.3, (te0 + uL) / 2].filter { clearOfWindow($0) && $0 + 8 < uL }
            for u in upTabs { upper = Poly.insertTab(upper, at: Vec2(u, 0), width: 10, height: t); upperMain = Poly.insertTab(upperMain, at: Vec2(u, 0), width: 10, height: t) }
            for u in loTabs { lower = Poly.insertTab(lower, at: Vec2(u, 0), width: 10, height: t) }
            lower = Poly.ccw(lower)
            addSlots(upTabs + loTabs)
            let eHornV = max(armOffset, tw / 2 + 10)
            tailHoles.append(hornSlot(at: Vec2(uH + 6, eHornV)))

            // Servo box in the upper front half, over the wing.
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.05 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            var upperHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: upperMain)]
            if c.hasRudder {
                upperHoles.append(servoCut("Rudder", center: s2, size: webServoCut, in: upperMain))
                upperHoles.append(hornSlot(at: Vec2(uH + 6, rgJ + 6 * DesignBuilder.rudderCutSlope + 8)))
            }

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
                              features: [.zone(Poly.rect(center: Vec2(c.batteryPosition, -c.battery.size.w / 2 - 1), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))

            let eBody: SIMD3<Double> = [0, t / 2 + s1.y, s1.x]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [eHornV, t / 2 + 9, uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: 0.4 * hsc * 0.8, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            if c.hasRudder {
                // Rudder horn on the left side of the rudder, servo arm on the left: pushrods never cross.
                let rBody: SIMD3<Double> = [0, t / 2 + s2.y, s2.x]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [-(tw / 2 + 8), t / 2 + 14, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: -1), hornAxis: [-1, 0, 0]))
            }
            batteryPos = [tw / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
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
            let out = w.build(full: true, surfaces: c.hasAilerons ? [a0...(s - 10 - wingTipRadius)] : [], fraction: fA)
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
            if c.hasAilerons {
                let sv = c.servo.size
                let vs = a0 + max(14, sv.h / 2 + 6)
                let hingeU = w.te(vs) - fA * w.chord(vs)
                for side in [-1.0, 1.0] {
                    let name = side < 0 ? "Left aileron" : "Right aileron"
                    let center = Vec2(hingeU - 8 - sv.l / 2, side * vs)
                    wingHoles.append(servoCut(name, center: center, size: wingServoCut, in: out.main))
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
            let topTabs = [uN * 0.5, c.rootChord * 0.3, c.rootChord * 0.75], botTabs = [uN * 0.3, c.rootChord * 0.5]
            for tu in topTabs { podTop = Poly.insertTab(podTop, at: Vec2(tu, 0), width: 10, height: t) }
            for tu in botTabs { podBot = Poly.insertTab(podBot, at: Vec2(tu, 0), width: 10, height: t) }
            wingHoles += centreSlots(topTabs.filter { $0 > 0 } + botTabs.filter { $0 > 0 })
            let noseHoles = centreSlots(topTabs.filter { $0 < 0 } + botTabs.filter { $0 < 0 })

            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.08 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            var podHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: podTop)]
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
            let soOutline = Poly.ccw([Vec2(ta, -sh), Vec2(ta, sh), Vec2(ue, sh), Vec2(ue, eb), Vec2(uHs, eb), Vec2(uHs, eb - g), Vec2(ue, eb - g),
                                      Vec2(ue, -(eb - g)), Vec2(uHs, -(eb - g)), Vec2(uHs, -eb), Vec2(ue, -eb), Vec2(ue, -sh)])
            let soMain = Poly.ccw([Vec2(ta, -sh), Vec2(ta, sh), Vec2(ue, sh), Vec2(ue, eb), Vec2(uHs, eb), Vec2(uHs, -eb), Vec2(ue, -eb), Vec2(ue, -sh)])
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
            for v in [-sh, sh] {
                for tu in fin.tabs {
                    stabOutline = Poly.insertTab(stabOutline, at: Vec2(finU0 + tu, v), width: 10, height: t)
                    stabRegions[0].polygon = Poly.insertTab(stabRegions[0].polygon, at: Vec2(finU0 + tu, v), width: 10, height: t)
                }
            }
            let eHorn = Vec2(ta + hsc * 0.6 + 6, max(armOffset, 8))
            stabHoles.append(hornSlot(at: eHorn))
            let stabY = boomY + 2 + t / 2
            parts.append(Part(name: "Stabiliser", role: .stabilizer, outline: stabOutline, holes: stabHoles,
                              features: [Feature.hinge(Vec2(uHs, -(eb - g)), Vec2(uHs, eb - g))] + [-xb, xb].map { .spar(Vec2(ta, $0), Vec2(ta + hsc * 0.55, $0), rod.widthMM) },
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

            let eBody: SIMD3<Double> = [0, t / 2 + s1.y, s1.x]
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
            // Cut-out at the bottom of the rudder so the elevator can deflect up underneath it.
            let rCut = rg + rudderChord * DesignBuilder.rudderCutSlope
            let upper: [Vec2] = [Vec2(uN, 0), Vec2(uH, 0), Vec2(uH, rg), Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH - 0.25 * vsc, finTop), Vec2(finLE, hs),
                                 Vec2(uN + 15, hs), Vec2(uN, noseFront)]
            var upperMain: [Vec2] = [Vec2(uN, 0), Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.25 * vsc, finTop), Vec2(finLE, hs), Vec2(uN + 15, hs), Vec2(uN, noseFront)]
            let rudder = [Vec2(uH, rg), Vec2(uR, rCut), Vec2(uR, finTop), Vec2(uH, finTop)]
            let upTabs = [L * 0.06, L * 0.4, finLE + vsc * 0.35].filter { $0 + 6 < uH && $0 - 6 > uN }
            var upperOut = upper
            for tu in upTabs {
                upperOut = Poly.insertTab(upperOut, at: Vec2(tu, 0), width: 10, height: t)
                upperMain = Poly.insertTab(upperMain, at: Vec2(tu, 0), width: 10, height: t)
            }
            let noseFrontLow = min(hk, max(mountHalf - t / 2 - 0.5, 4))
            let kEnd = L * 0.62
            let lower: [Vec2] = [Vec2(uN, 0), Vec2(uN, -noseFrontLow), Vec2(uN + 20, -hk), Vec2(L * 0.45, -hk), Vec2(kEnd, 0)]
            let loTabs = [L * 0.12, L * 0.36].filter { $0 + 6 < kEnd }
            var lowerOut = lower
            for tu in loTabs { lowerOut = Poly.insertTab(lowerOut, at: Vec2(tu, 0), width: 10, height: t) }

            var discHoles = centreSlots(upTabs + loTabs)
            let eHornV = max(armOffset, t / 2 + 10)
            discHoles.append(hornSlot(at: Vec2(uH + 6, eHornV)))

            // Servos in the spine just ahead of the CG.
            let sv = c.servo.size
            let s1 = Vec2(L * 0.12 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            let upperHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: upperMain),
                              servoCut("Rudder", center: s2, size: webServoCut, in: upperMain),
                              hornSlot(at: Vec2(uH + 6, rg + 6 * DesignBuilder.rudderCutSlope + 8))]

            let us = L * 0.3
            let vs = S * sin(acos(min(1, max(-1, 1 - 2 * us / L)))) * 0.88
            var features: [Feature] = [.hinge(Vec2(uH, -pt(thH).y), pt(thH)), .label("NUTBALL", Vec2(L * 0.55, S * 0.35))]
            if c.sparEnabled { features.append(.rod(Vec2(us, -vs), Vec2(us, vs), c.sparSpec.widthMM)) }
            parts.append(Part(name: "Disc wing", role: .wing, outline: outline, holes: discHoles, features: features,
                              regions: [Region(polygon: mainRegion, isControl: false), Region(polygon: elevator, isControl: true)],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Spine & fin", role: .fuselage, outline: upperOut, holes: upperHoles,
                              features: [.hinge(Vec2(uH, 0), Vec2(uH, finTop)), .label("SPINE", Vec2(L * 0.3, hs * 0.5))],
                              regions: [Region(polygon: upperMain, isControl: false), Region(polygon: rudder, isControl: true)],
                              instances: [.vertical(at: [0, t / 2, 0])], material: c.material))
            parts.append(Part(name: "Keel", role: .fuselage, outline: lowerOut,
                              features: [.label("KEEL", Vec2(L * 0.3, -hk * 0.5)),
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -c.battery.size.w / 2 - 1), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: [.vertical(at: [0, -t / 2, 0])], material: c.material))

            let eBody: SIMD3<Double> = [0, t / 2 + s1.y, s1.x]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [eHornV, t / 2 + 9, uH + 2],
                                           servoPosition: eBody, area: Poly.area(elevator), chord: f * L * 0.7, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            let rBody: SIMD3<Double> = [0, t / 2 + s2.y, s2.x]
            controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [-(t / 2 + 8), t / 2 + 14, uH + 2],
                                           servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                           armPosition: armTip(rBody, side: -1), hornAxis: [-1, 0, 0]))
            batteryPos = [t / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
        }

        // MARK: Electronics & hardware

        mutating func addElectronics() {
            let pusher = c.isPusher
            let motorZ = c.motorZ
            for (i, x) in c.motorXs.enumerated() {
                let tag = c.isDual ? (i == 0 ? " (left)" : " (right)") : ""
                components.append(MassItem(name: c.motor.name + tag, mass: c.motor.mass, position: [x, 0, motorZ], category: "Power"))
                components.append(MassItem(name: "Propeller\(tag)", mass: c.propInches * 0.35, position: [x, 0, c.propPlaneZ], category: "Power"))
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
