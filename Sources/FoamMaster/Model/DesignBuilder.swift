import Foundation
import simd

extension AircraftConfig {
    /// Depth of the trailing-edge cutout the pusher motor of a flying wing sits in.
    /// Motor body length (bell + base) along the thrust line.
    var motorLength: Double { motor.bellDiameter + 4 }
    /// Depth of the trailing-edge cutout the pusher motor of a flying wing sits in: firewall at the front of
    /// the cutout, motor body behind it, prop spinning inside the cutout.
    var motorNotchDepth: Double { max(26, motorLength + 14) }
    var motorNotchWidth: Double { motor.propInches * 25.4 + 10 }
    /// Firewall (printed mount plate) position. The clamp always grips the structure ahead of / behind it:
    /// pusher = structure in front, motor and prop behind; tractor = structure behind, motor and prop in front.
    /// Lateral position of the two motors of a dual-tractor layout: props clear the fuselage/pod and each other.
    var dualMotorX: Double {
        let r = motor.propInches * 25.4 / 2
        let body = kind.isTailless ? 6 : fuselagePlateWidth / 2 + 6
        return max(r + body + 6, semiSpan * 0.28)
    }
    var firewallZ: Double {
        if isDual { return sweep * dualMotorX / semiSpan - 2 }   // just ahead of the leading edge at the motor station
        if kind.isTailless { return rootChord - motorNotchDepth + 2 }
        if kind.isTwinBoom { return rootChord }
        if kind.isJet { return jetPropZ - 5 - motorLength }
        return -noseLength
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
    var fuselagePlateWidth: Double {
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
/// into the plate sides, carbon spars top + bottom and a carbon truss on the fuselage sides.
enum DesignBuilder {
    static let slotClearance = 0.15

    static func build(_ c: AircraftConfig) -> Design {
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
        var fpvCamera = SIMD3<Double>.zero
        var fpvVTX = SIMD3<Double>.zero
        var batteryPos = SIMD3<Double>.zero
        /// Total length of carbon truss strips (mm) for the BOM.
        var trussLength = 0.0

        var t: Double { c.material.thickness }
        var s: Double { c.semiSpan }
        var propRadius: Double { c.motor.propInches * 25.4 / 2 }

        var wing: TaperedPanel {
            TaperedPanel(rootChord: c.rootChord, tipChord: c.tipChord, sweep: c.sweep, semiSpan: s)
        }

        mutating func run() {
            if c.kind.isTailless { buildTailless() }
            else if c.kind.isTwinBoom { buildTwinBoom() }
            else if c.kind.isJet { buildJet() }
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

        /// Carbon spar on the 30 % chord line, slit in from top and bottom.
        func sparFeatures(_ w: TaperedPanel, from v0: Double, to v1: Double) -> [Feature] {
            guard c.sparEnabled else { return [] }
            return [.spar(Vec2(w.le(v0) + 0.3 * w.chord(v0), v0), Vec2(w.le(v1) + 0.3 * w.chord(v1), v1), c.sparSpec.widthMM)]
        }

        /// Carbon truss (3 × 0.5 mm strips) on both sides of a vertical part: two straight chords
        /// along the edges plus zig-zag diagonals between them – a Warren girder like the kits use.
        mutating func truss(from u0: Double, to u1: Double, low: (Double) -> Double, high: (Double) -> Double) -> [Feature] {
            guard u1 - u0 > 30 else { return [] }
            let n = max(2, Int((u1 - u0) / 32))
            var f: [Feature] = []
            var prev = Vec2(u0, low(u0))
            for i in 1...n {
                let u = u0 + (u1 - u0) * Double(i) / Double(n)
                let uPrev = u0 + (u1 - u0) * Double(i - 1) / Double(n)
                let p = Vec2(u, i % 2 == 1 ? high(u) : low(u))
                f.append(.spar(prev, p, 3))
                // chords
                let lo0 = Vec2(uPrev, low(uPrev)), lo1 = Vec2(u, low(u))
                let hi0 = Vec2(uPrev, high(uPrev)), hi1 = Vec2(u, high(u))
                f.append(.spar(lo0, lo1, 3)); f.append(.spar(hi0, hi1, 3))
                trussLength += (simd_distance(prev, p) + simd_distance(lo0, lo1) + simd_distance(hi0, hi1)) * 2   // both sides
                prev = p
            }
            return f
        }

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

        // MARK: Tailless (flying wing / delta)

        mutating func buildTailless() {
            let w = wing
            let f = c.controlChordPct
            let single = !c.isDual
            let nw = single ? c.motorNotchWidth : 0, nd = single ? c.motorNotchDepth : 0
            let v0 = single ? max(s * 0.12, nw / 2 + 6) : s * 0.12
            let v1 = s - 14
            if v1 - v0 < 40 { issues.append("Elevons are too short: the motor cutout needs \(Int(nw)) mm at the centre – use a smaller prop or more span.") }
            let out = w.build(full: true, surfaces: v1 > v0 + 10 ? [v0...v1] : [], fraction: f)

            // Motor sits in a cutout in the trailing edge (prop spins inside the cutout).
            func withMotorNotch(_ poly: [Vec2]) -> [Vec2] {
                guard single, let i = poly.firstIndex(where: { abs($0.y) < 1e-6 && abs($0.x - w.te(0)) < 1e-6 }) else { return poly }
                var p = poly
                p.replaceSubrange(i...i, with: [Vec2(w.te(-nw / 2), -nw / 2), Vec2(w.te(0) - nd, -nw / 2),
                                                Vec2(w.te(0) - nd, nw / 2), Vec2(w.te(nw / 2), nw / 2)])
                return p
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
            } else if finHeight > 5 {
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
            let k0 = 10.0, k1 = single ? w.te(0) - nd + 2 : w.te(0) - 12
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
            fpvCamera = [0, t / 2 + 8, 4]
            fpvVTX = [0, t / 2 + 4, c.rootChord * 0.5]
            if c.fpv != .none { features.append(.zone(Poly.rect(center: Vec2(8, 0), size: Vec2(14, 18)), "Cam")) }
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
            let central = c.hasAilerons && c.aileronServos == 1
            let a0 = central ? 3 : max(8, s * 0.3 - hw)
            let surfaces: [ClosedRange<Double>] = c.hasAilerons ? [a0...(span - 10)] : []
            let out = half.build(full: false, surfaces: surfaces, fraction: f)
            let ua = half.le(0), ub = half.te(0)
            let tabUs = [ua + (ub - ua) * 0.3, ua + (ub - ua) * 0.72]
            var outline = out.outline, main = out.main
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
                    let hingeRoot = half.te(0) - f * half.chord(0)
                    features.append(.label("TORQUE ROD", Vec2(hingeRoot - 4, 12)))
                    for side in [-1.0, 1.0] {
                        controls.append(ControlSurface(name: side < 0 ? "Left aileron" : "Right aileron",
                                                       hingeMid: [side * (hw + span / 2), 0, hingeRoot], hornPosition: [side * (hw + 4), -t, hingeRoot - 6],
                                                       servoPosition: [0, -t / 2 - 3 - sv.w / 2, c.rootChord - 6 - sv.l / 2],
                                                       area: area, chord: chord, servoID: "Ailerons (torque rods)",
                                                       armPosition: [side * (sv.h / 2 + 2), -t / 2 - 3 - sv.w / 2 + 10, c.rootChord - 11]))
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
            func hS(_ v: Double) -> Double { stab.te(v) - ef * stab.chord(v) }
            let w = wing

            // Wing halves keyed into the plate.
            let jointTabs = buildWingHalves(plateHalfWidth: hw, allowDihedral: true)
            let ua = w.le(hw), ub = w.te(hw)

            // --- Horizontal fuselage plate: nose strip + wing centre + tail boom + stabiliser in one piece.
            let rudderChord = max(0.4 * vsc, 18.0)
            let uH = hS(0)                       // rudder & elevator hinge line at the centre
            let uR = uH + rudderChord            // rudder trailing edge
            let a = t / 2 + 1                    // elevator inner edge at the hinge
            let nTe = max(a + 4, rudderChord * 0.55)   // V-cut at the elevator TE for rudder travel
            if stab.le(wb / 2) < ub + 10 { issues.append("Tail arm is too short – the stabiliser would reach the wing.") }

            func notch(_ u: Double) -> [Vec2] { [Vec2(u - 5.2, hw), Vec2(u - 5.2, hw - 6.2), Vec2(u + 5.2, hw - 6.2), Vec2(u + 5.2, hw)] }
            let noseSide = [Vec2(uN, W * 0.3), Vec2(uN + 6, hw)]
            let wingSide = [Vec2(ua, hw)] + notch(jointTabs[0]) + notch(jointTabs[1]) + [Vec2(ub, hw)]
            let boomSide = [Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh)]
            let fullTail = [Vec2(stab.te(sh), sh), Vec2(stab.te(nTe), nTe), Vec2(uH, a)]
            let fixedTail = [Vec2(hS(sh), sh), Vec2(uH, a)]
            func mirrored(_ r: [Vec2]) -> [Vec2] { r.reversed().map { Vec2($0.x, -$0.y) } }
            let rOutline = noseSide + wingSide + boomSide + fullTail
            let rMain = noseSide + wingSide + boomSide + fixedTail
            let plateOutline = Poly.ccw(rOutline + mirrored(rOutline))
            let plateMain = Poly.ccw(rMain + mirrored(rMain))
            let elevR = [Vec2(uH, a), Vec2(hS(sh), sh), Vec2(stab.te(sh), sh), Vec2(stab.te(nTe), nTe)]
            let elevL = elevR.reversed().map { Vec2($0.x, -$0.y) }
            if !Poly.isSimple(plateOutline) { issues.append("Fuselage plate outline intersects itself – check tail arm, stabiliser and wing chord.") }

            // --- Upper fuselage half (with fin & rudder) and lower half.
            let hWing = fh * 0.5 - t / 2
            let hNose = fh * 0.4 - t / 2
            let hBoom = c.boomTopHeight
            let finTop = hBoom + c.vStabHeight
            let finLE = uH - 1.25 * vsc
            if finLE < ub + 10 { issues.append("Fin is too long for the tail arm – fin leading edge reaches the wing.") }
            let upper: [Vec2] = [Vec2(uN, 0), Vec2(uR, 0), Vec2(uR, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                 Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, hNose * 0.65)]
            var upperMain: [Vec2] = [Vec2(uN, 0), Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.3 * vsc, finTop), Vec2(finLE, hBoom),
                                     Vec2(c.rootChord, hWing * 0.9), Vec2(c.rootChord * 0.15, hWing), Vec2(uN + 0.35 * c.noseLength, hNose), Vec2(uN, hNose * 0.65)]
            let rudder = [Vec2(uH, 0), Vec2(uR, 0), Vec2(uR, finTop), Vec2(uH, finTop)]
            let hasRudder = c.hasRudder
            if !hasRudder { upperMain = upper }
            let layers = Double(c.fuselageType.webLayers)
            let tw = t * layers
            let upTabs = [uN + max(32, c.noseLength * 0.45), c.rootChord * 0.45, (c.rootChord + finLE) / 2, finLE + vsc * 0.5].filter { $0 + 6 < uH }
            var upperOut = upper
            for tu in upTabs { upperOut = Poly.insertTab(upperOut, at: Vec2(tu, 0), width: 10, height: t); upperMain = Poly.insertTab(upperMain, at: Vec2(tu, 0), width: 10, height: t) }

            let uL = ta + hsc * 0.35
            let hLowWing = fh * 0.5 - t / 2
            let lower: [Vec2] = [Vec2(uN, 0), Vec2(uN, -hLowWing * 0.55), Vec2(uN + 0.3 * c.noseLength, -hLowWing), Vec2(c.rootChord * 0.85, -hLowWing),
                                 Vec2(uL, -c.lowerTailHeight), Vec2(uL, 0)]
            let loTabs = [uN + max(44, c.noseLength * 0.6), c.rootChord * 0.75, (c.rootChord + ta) / 2 + 15].filter { $0 + 6 < uL }
            var lowerOut = lower
            for tu in loTabs { lowerOut = Poly.insertTab(lowerOut, at: Vec2(tu, 0), width: 10, height: t) }

            // Plate slots for both halves (all on the centre line, at different stations).
            var plateHoles = (upTabs + loTabs).map { slot(minU: $0 - 5, maxU: $0 + 5, minV: -tw / 2, maxV: tw / 2) }
            // Elevator horn just outside the V-cut, as close to the fuselage as the cut allows.
            let eHornV = max(armOffset, a + (nTe - a) * 0.45 + 2.5)
            plateHoles.append(hornSlot(at: Vec2(hS(eHornV) + 6, eHornV)))

            // Servos in the upper half above the plate.
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.06 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            var upperHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: upperMain)]
            if hasRudder {
                upperHoles.append(servoCut("Rudder", center: s2, size: webServoCut, in: upperMain))
                upperHoles.append(hornSlot(at: Vec2(uH + 6, 10)))
            }
            var lowerHoles: [Hole] = []
            if c.hasAilerons && c.aileronServos == 1 {
                lowerHoles.append(servoCut("Ailerons", center: Vec2(c.rootChord - 6 - sv.l / 2, -(3 + sv.w / 2)), size: webServoCut, in: lower))
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
                              features: [.hinge(Vec2(uH, a), Vec2(hS(sh), sh)), .hinge(Vec2(uH, -a), Vec2(hS(sh), -sh)),
                                         .cut(Vec2(uH, a), Vec2(stab.te(nTe), nTe)), .cut(Vec2(uH, -a), Vec2(stab.te(nTe), -nTe)),
                                         .label("PLATE", Vec2(c.rootChord * 0.5, 0))] + sparFeatures(w, from: -hw, to: hw),
                              regions: [Region(polygon: plateMain, isControl: false), Region(polygon: elevR, isControl: true), Region(polygon: elevL, isControl: true)],
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
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [eHornV, t / 2 + 9, hS(eHornV) + 2],
                                           servoPosition: eBody, area: Poly.area(elevR) * 2, chord: ef * hsc * 0.9, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            if hasRudder {
                // Rudder horn on the left side of the rudder, servo arm on the left: pushrods never cross.
                let rBody: SIMD3<Double> = [0, t / 2 + s2.y, s2.x]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [-(tw / 2 + 8), t / 2 + 10, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: -1), hornAxis: [-1, 0, 0]))
            }

            batteryPos = [tw / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
            fpvCamera = [0, t / 2 + hNose + 8, uN + 14]
            fpvVTX = [-(tw / 2 + 3), t / 2 + hWing * 0.5, c.rootChord * 0.6]
        }

        // MARK: Sport jet (Ares style) – swept wing, prop spinning in a slot through the wing centre

        mutating func buildJet() {
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm, hsc = c.hStabChord, vsc = c.vStabChord
            let W = c.fuselagePlateWidth, hw = W / 2, wb = c.plateTailWidth
            let w = wing
            let zp = c.jetPropZ
            let slotHalf = propRadius + 4
            let gap = 8.0                                   // fuselage halves stop this far from the prop plane
            let layers = Double(c.fuselageType.webLayers), tw = t * layers
            let webX: [Double] = layers > 1 ? [-t / 2, t / 2] : [0]
            let layerNote = layers > 1 ? " · 2 layers laminated" : ""
            let te0 = w.te(0)

            // --- Wing (one piece) with prop slot, ailerons and joints for nose and tail plates.
            let fA = c.controlChordPct
            let a0 = max(slotHalf + 12, s * 0.35)
            let out = w.build(full: true, surfaces: c.hasAilerons ? [a0...(s - 8)] : [], fraction: fA)
            var wingOutline = out.outline, wingMain = out.main
            for v in [-hw * 0.5, hw * 0.5] {
                for u in [w.le(v), w.te(v)] {
                    wingOutline = Poly.insertTab(wingOutline, at: Vec2(u, v), width: 10, height: -6)
                    wingMain = Poly.insertTab(wingMain, at: Vec2(u, v), width: 10, height: -6)
                }
            }
            var wingHoles: [Hole] = [slot(minU: zp - 7, maxU: zp + 7, minV: -slotHalf, maxV: slotHalf)]
            wingHoles[0].note = "prop slot"
            if w.le(slotHalf) > zp - 14 || w.te(slotHalf) < zp + 14 {
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
            // X-bracing carbon rods (Ø0.8 mm) across the centre section, as in the kit.
            let bx = min(slotHalf + 30, s * 0.6)
            wingFeatures += [.spar(Vec2(w.le(bx) + 6, -bx), Vec2(te0 - 6, bx * 0.3), 0.8), .spar(Vec2(w.le(bx) + 6, bx), Vec2(te0 - 6, -bx * 0.3), 0.8)]

            // --- Nose plate (pointed) keyed into the leading edge.
            var nose = Poly.ccw([Vec2(uN, -2), Vec2(uN + 0.5 * c.noseLength, -hw * 0.85), Vec2(w.le(hw), -hw), Vec2(0, 0),
                                 Vec2(w.le(hw), hw), Vec2(uN + 0.5 * c.noseLength, hw * 0.85), Vec2(uN, 2)])
            for v in [-hw * 0.5, hw * 0.5] { nose = Poly.insertTab(nose, at: Vec2(w.le(v), v), width: 10, height: 6) }

            // --- Tail plate: boom + swept stabiliser, keyed into the trailing edge.
            let sh = c.hStabSpan / 2
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc * 0.55, sweep: hsc * 0.7, semiSpan: sh)
            func hS(_ v: Double) -> Double { stab.te(v) - 0.4 * stab.chord(v) }
            let rudderChord = max(0.4 * vsc, 18.0)
            let uH = hS(0), uR = uH + rudderChord
            let aIn = tw / 2 + 1, nTe = max(aIn + 4, rudderChord * 0.55)
            if stab.le(wb / 2) < w.te(hw) + 15 { issues.append("Tail arm is too short – the stabiliser would reach the wing.") }
            let rFull = [Vec2(w.te(hw), hw), Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh), Vec2(stab.te(sh), sh), Vec2(stab.te(nTe), nTe), Vec2(uH, aIn)]
            let rFixed = [Vec2(w.te(hw), hw), Vec2(stab.le(wb / 2), wb / 2), Vec2(stab.le(sh), sh), Vec2(hS(sh), sh), Vec2(uH, aIn)]
            func mirrored(_ r: [Vec2]) -> [Vec2] { r.reversed().map { Vec2($0.x, -$0.y) } }
            var tail = Poly.ccw([Vec2(te0, 0)] + rFull + mirrored(rFull))
            var tailMain = Poly.ccw([Vec2(te0, 0)] + rFixed + mirrored(rFixed))
            for v in [-hw * 0.5, hw * 0.5] {
                tail = Poly.insertTab(tail, at: Vec2(w.te(v), v), width: 10, height: 6)
                tailMain = Poly.insertTab(tailMain, at: Vec2(w.te(v), v), width: 10, height: 6)
            }
            let elevR = [Vec2(uH, aIn), Vec2(hS(sh), sh), Vec2(stab.te(sh), sh), Vec2(stab.te(nTe), nTe)]
            let elevL = elevR.reversed().map { Vec2($0.x, -$0.y) }

            // --- Vertical fuselage: front and rear halves, split at the prop slot.
            let hCanopy = fh * 0.5 - t / 2, hMid = fh * 0.32, hBoom = c.boomTopHeight
            let finTop = hBoom + c.vStabHeight
            let finLE = uH - 1.3 * vsc
            let fw = c.firewallZ
            var upFront = [Vec2(uN + 12, 0), Vec2(fw, 0), Vec2(fw, hMid), Vec2(c.rootChord * 0.2, hCanopy),
                           Vec2(-0.3 * c.noseLength, hCanopy * 0.85), Vec2(uN + 0.45 * c.noseLength, hCanopy * 0.4), Vec2(uN + 12, 3)]
            var upRear = [Vec2(zp + gap, 0), Vec2(uR, 0), Vec2(uR, finTop), Vec2(uH - 0.35 * vsc, finTop), Vec2(finLE, hBoom), Vec2(zp + gap + 15, hMid * 0.9), Vec2(zp + gap, hMid * 0.8)]
            var upRearMain = [Vec2(zp + gap, 0), Vec2(uH, 0), Vec2(uH, finTop), Vec2(uH - 0.35 * vsc, finTop), Vec2(finLE, hBoom), Vec2(zp + gap + 15, hMid * 0.9), Vec2(zp + gap, hMid * 0.8)]
            let rudder = [Vec2(uH, 0), Vec2(uR, 0), Vec2(uR, finTop), Vec2(uH, finTop)]
            if !c.hasRudder { upRearMain = upRear }
            if finLE < zp + gap + 20 { issues.append("Fin is too long for the tail arm.") }
            let hLow = fh * 0.3
            var loFront = Poly.ccw([Vec2(uN + 0.3 * c.noseLength, 0), Vec2(fw, 0), Vec2(fw, -hLow * 0.7), Vec2(c.rootChord * 0.2, -hLow), Vec2(uN + 0.5 * c.noseLength, -hLow * 0.5)])
            let uL = ta + hsc * 0.3
            var loRear = Poly.ccw([Vec2(zp + gap, 0), Vec2(uL, 0), Vec2(uL, -c.lowerTailHeight * 0.7), Vec2(zp + gap + 25, -hLow * 0.7), Vec2(zp + gap, -hLow * 0.7)])

            // Tabs → slots in whichever horizontal part lies underneath.
            var noseHoles: [Hole] = [], tailHoles: [Hole] = []
            func addSlots(_ us: [Double]) {
                for u in us {
                    let h = slot(minU: u - 5, maxU: u + 5, minV: -tw / 2, maxV: tw / 2)
                    if u < -6 { noseHoles.append(h) } else if u < te0 - 8 { wingHoles.append(h) } else if u > te0 + 8 { tailHoles.append(h) }
                }
            }
            let ufTabs = [uN + 0.6 * c.noseLength, c.rootChord * 0.15].filter { $0 + 8 < fw }
            let urTabs = [(te0 + ta) / 2, ta + hsc * 0.2].filter { $0 + 8 < uH && $0 > zp + gap + 8 }
            let lfTabs = [uN + 0.7 * c.noseLength, c.rootChord * 0.3].filter { $0 + 8 < fw }
            let lrTabs = [(te0 + uL) / 2].filter { $0 > zp + gap + 8 }
            for u in ufTabs { upFront = Poly.insertTab(upFront, at: Vec2(u, 0), width: 10, height: t) }
            for u in urTabs { upRear = Poly.insertTab(upRear, at: Vec2(u, 0), width: 10, height: t); upRearMain = Poly.insertTab(upRearMain, at: Vec2(u, 0), width: 10, height: t) }
            for u in lfTabs { loFront = Poly.insertTab(loFront, at: Vec2(u, 0), width: 10, height: t) }
            for u in lrTabs { loRear = Poly.insertTab(loRear, at: Vec2(u, 0), width: 10, height: t) }
            addSlots(ufTabs + urTabs + lfTabs + lrTabs)
            let eHornV = max(armOffset, aIn + (nTe - aIn) * 0.45 + 2.5)
            tailHoles.append(hornSlot(at: Vec2(hS(eHornV) + 6, eHornV)))

            // Servo box in the upper front half, over the wing.
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.05 + sv.l / 2, 3 + sv.w / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            var upFrontHoles = [servoCut("Elevator", center: s1, size: webServoCut, in: upFront)]
            var upRearHoles: [Hole] = []
            if c.hasRudder {
                upFrontHoles.append(servoCut("Rudder", center: s2, size: webServoCut, in: upFront))
                upRearHoles.append(hornSlot(at: Vec2(uH + 6, 10)))
            }
            let rearTruss = truss(from: zp + gap + 6, to: min(finLE + vsc * 0.5, uH - 6), low: { _ in 2.5 }, high: { [hMid, hBoom, zp, finLE] u in
                let k = (u - zp) / max(finLE - zp, 1)
                return hMid * 0.8 + (hBoom - hMid * 0.8) * min(max(k, 0), 1) - 2.5
            })

            parts.append(Part(name: "Wing", role: .wing, outline: wingOutline, holes: wingHoles, features: wingFeatures,
                              regions: c.hasAilerons ? [Region(polygon: wingMain, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) } : [],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Nose plate", role: .fuselage, outline: nose, holes: noseHoles,
                              features: [.label("NOSE", Vec2(uN * 0.45, 0))], instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Tail plate", role: .stabilizer, outline: tail, holes: tailHoles,
                              features: [.hinge(Vec2(uH, aIn), Vec2(hS(sh), sh)), .hinge(Vec2(uH, -aIn), Vec2(hS(sh), -sh)),
                                         .cut(Vec2(uH, aIn), Vec2(stab.te(nTe), nTe)), .cut(Vec2(uH, -aIn), Vec2(stab.te(nTe), -nTe))],
                              regions: [Region(polygon: tailMain, isControl: false), Region(polygon: elevR, isControl: true), Region(polygon: elevL, isControl: true)],
                              instances: [.horizontal(at: .zero)], material: c.material))
            parts.append(Part(name: "Fuselage top front\(layerNote)", role: .fuselage, outline: upFront, holes: upFrontHoles,
                              features: [.label("CANOPY", Vec2(c.rootChord * 0.05, hCanopy * 0.6))],
                              instances: webX.map { .vertical(at: [$0, t / 2, 0]) }, material: c.material))
            parts.append(Part(name: "Fuselage top rear\(layerNote)", role: .fuselage, outline: upRear, holes: upRearHoles,
                              features: (c.hasRudder ? [.hinge(Vec2(uH, 0), Vec2(uH, finTop))] : []) + rearTruss,
                              regions: c.hasRudder ? [Region(polygon: upRearMain, isControl: false), Region(polygon: rudder, isControl: true)] : [],
                              instances: webX.map { .vertical(at: [$0, t / 2, 0]) }, material: c.material))
            parts.append(Part(name: "Fuselage bottom front\(layerNote)", role: .fuselage, outline: loFront,
                              features: [.zone(Poly.rect(center: Vec2(c.batteryPosition, -c.battery.size.w / 2 - 1), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery")],
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))
            parts.append(Part(name: "Fuselage bottom rear\(layerNote)", role: .fuselage, outline: loRear,
                              instances: webX.map { .vertical(at: [$0, -t / 2, 0]) }, material: c.material))

            let eBody: SIMD3<Double> = [0, t / 2 + s1.y, s1.x]
            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, 0, uH], hornPosition: [eHornV, t / 2 + 9, hS(eHornV) + 2],
                                           servoPosition: eBody, area: Poly.area(elevR) * 2, chord: 0.4 * hsc * 0.8, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            if c.hasRudder {
                // Rudder horn on the left side of the rudder, servo arm on the left: pushrods never cross.
                let rBody: SIMD3<Double> = [0, t / 2 + s2.y, s2.x]
                controls.append(ControlSurface(name: "Rudder", hingeMid: [0, t / 2 + finTop / 2, uH], hornPosition: [-(tw / 2 + 8), t / 2 + 10, uH + 2],
                                               servoPosition: rBody, area: Poly.area(rudder), chord: rudderChord, servoID: "Rudder",
                                               armPosition: armTip(rBody, side: -1), hornAxis: [-1, 0, 0]))
            }
            batteryPos = [tw / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
            fpvCamera = [0, t / 2 + hCanopy * 0.55, -0.45 * c.noseLength]
            fpvVTX = [-(tw / 2 + 3), t / 2 + hMid * 0.5, c.rootChord * 0.3]
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
            let out = w.build(full: true, surfaces: c.hasAilerons ? [a0...(s - 10)] : [], fraction: fA)
            var wingOutline = out.outline
            for v in [-hw * 0.5, hw * 0.5] { wingOutline = Poly.insertTab(wingOutline, at: Vec2(w.le(v), v), width: 10, height: -6) }
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

            parts.append(Part(name: "Wing", role: .wing, outline: wingOutline, holes: wingHoles, features: wingFeatures,
                              regions: c.hasAilerons ? regions(out) : [], instances: [.horizontal(at: .zero)], material: c.material))
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
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc, sweep: 0, semiSpan: sh)
            let so = stab.build(full: true, surfaces: [1...(sh - 14)], fraction: 0.4)
            var stabHoles: [Hole] = []
            // Twin fins are end plates glued to the SIDE of the stabiliser tips (tip tabs into fin slots).
            let fin = sideFin(chord: c.vStabChord, height: c.vStabHeight, below: max(10, c.vStabHeight * 0.2), rudderFrac: c.hasRudder ? 0.4 : 0)
            let finU0 = ta + hsc - c.vStabChord
            var stabOutline = so.outline
            var stabRegions = regions(so)
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
                              features: so.features + [-xb, xb].map { .spar(Vec2(ta, $0), Vec2(ta + hsc * 0.55, $0), rod.widthMM) },
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
                                           servoPosition: eBody, area: Poly.area(so.controls.first ?? []) * 2, chord: 0.4 * hsc, servoID: "Elevator",
                                           armPosition: armTip(eBody, side: 1)))
            let rudderArea = (fin.rudder.map { Poly.area($0) } ?? 0) * 2
            if c.hasRudder { controls.append(ControlSurface(name: "Rudders", hingeMid: [sh + t / 2, stabY + c.vStabHeight / 2, finU0 + rHingeU],
                                           hornPosition: [-sh + 8, stabY + 14, finU0 + rHingeU + 2],
                                           servoPosition: [0, t / 2 + s2.y, s2.x], area: rudderArea, chord: 0.4 * c.vStabChord, servoID: "Rudders",
                                           armPosition: armTip([0, t / 2 + s2.y, s2.x], side: -1), hornAxis: [1, 0, 0])) }

            batteryPos = [t / 2 + c.battery.size.h / 2, -t / 2 - c.battery.size.w / 2 - 1, c.batteryPosition]
            fpvCamera = [0, t / 2 + hp * 0.5 + 8, uN + 10]
            fpvVTX = [-(t / 2 + 3), t / 2 + hp * 0.5, c.rootChord * 0.4]
        }

        // MARK: Electronics & hardware

        mutating func addElectronics() {
            let pusher = c.isPusher
            let motorZ = c.motorZ
            for (i, x) in c.motorXs.enumerated() {
                let tag = c.isDual ? (i == 0 ? " (left)" : " (right)") : ""
                components.append(MassItem(name: c.motor.name + tag, mass: c.motor.mass, position: [x, 0, motorZ], category: "Power"))
                components.append(MassItem(name: "Propeller\(tag)", mass: c.motor.propInches * 0.35, position: [x, 0, c.propPlaneZ], category: "Power"))
                components.append(MassItem(name: "Motor mount (printed)\(tag)", mass: 1.5 + c.motor.mass * 0.12, position: [x, 0, c.firewallZ], category: "Printed"))
                let escZ = c.isDual ? c.rootChord * 0.25 : (pusher ? c.rootChord * 0.15 : -c.noseLength * 0.3)
                components.append(MassItem(name: "ESC\(tag)", mass: c.motor.escMass, position: [x * 0.5, 0, escZ], category: "Power"))
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
            components.append(MassItem(name: "Receiver", mass: 2.5, position: [0, 0, pusher ? c.rootChord * 0.1 : c.rootChord * 0.3], category: "Radio"))
            components.append(MassItem(name: "Wiring & connectors", mass: c.isDual ? 4.5 : 3, position: [0, 0, c.rootChord * 0.15], category: "Radio"))
            components.append(MassItem(name: c.battery.name, mass: c.battery.mass, position: batteryPos, category: "Battery"))

            if c.fpv != .none {
                components.append(MassItem(name: "FPV camera (\(c.fpv.name))", mass: c.fpv.cameraMass, position: fpvCamera, category: "FPV"))
                components.append(MassItem(name: "FPV transmitter + antenna", mass: c.fpv.vtxMass, position: fpvVTX, category: "FPV"))
                components.append(MassItem(name: "Camera mount (printed)", mass: 0.8, position: fpvCamera - [0, 5, 0], category: "Printed"))
            }

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
                components.append(MassItem(name: "2 × \(c.sparSpec.name)", mass: 2 * c.sparLength / 1000 * c.sparSpec.gramsPerMeter,
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

