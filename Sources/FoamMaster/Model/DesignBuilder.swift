import Foundation
import simd

/// Turns an `AircraftConfig` into flat foam parts, cutouts and component positions.
enum DesignBuilder {
    static let slotClearance = 0.15

    static func build(_ c: AircraftConfig) -> Design {
        var b = Builder(c: c)
        b.run()
        return Design(config: c, parts: b.parts, components: b.components, controls: b.controls,
                      servoCutouts: b.servoCutouts, geometryIssues: b.issues)
    }

    private struct Builder {
        let c: AircraftConfig
        var parts: [Part] = []
        var components: [MassItem] = []
        var controls: [ControlSurface] = []
        var servoCutouts: [(part: String, rect: [Vec2])] = []
        var issues: [String] = []

        var t: Double { c.material.thickness }
        var s: Double { c.semiSpan }
        var propRadius: Double { c.motor.propInches * 25.4 / 2 }

        var wing: TaperedPanel {
            TaperedPanel(rootChord: c.rootChord, tipChord: c.tipChord, sweep: c.sweep, semiSpan: s)
        }

        mutating func run() {
            if c.kind.isTailless { buildTailless() } else { buildTailed() }
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

        func hornSlot(at p: Vec2, alongU: Bool = true) -> Hole {
            let size = alongU ? Vec2(10, 1.6) : Vec2(1.6, 10)
            return Hole(kind: .hornSlot, polygon: Poly.rect(center: p, size: size), note: "horn")
        }

        func slot(minU: Double, maxU: Double, minV: Double, maxV: Double) -> Hole {
            Hole(kind: .slot, polygon: Poly.rect(minU: minU - slotClearance, maxU: maxU + slotClearance,
                                                 minV: minV - slotClearance, maxV: maxV + slotClearance))
        }

        func regions(_ out: TaperedPanel.Output) -> [Region] {
            [Region(polygon: out.main, isControl: false)] + out.controls.map { Region(polygon: $0, isControl: true) }
        }

        func sparFeatures(full: Bool) -> [Feature] {
            guard c.sparEnabled else { return [] }
            let w = wing
            let tipV = s * 0.9
            let root = Vec2(w.le(0) + 0.3 * w.chord(0), 0)
            let tip = Vec2(w.le(tipV) + 0.3 * w.chord(tipV), tipV)
            var f: [Feature] = [.spar(full ? Vec2(tip.x, -tipV) : root, tip, 3)]
            if full && abs(tip.x - root.x) > 1 { f = [.spar(Vec2(tip.x, -tipV), root, 3), .spar(root, tip, 3)] }
            return f
        }

        // MARK: Tailless (flying wing / delta)

        mutating func buildTailless() {
            let w = wing
            let f = c.controlChordPct
            let v0 = max(s * 0.12, propRadius + 8)
            let v1 = s - 14
            if v1 - v0 < 40 { issues.append("Elevons are too short: the propeller needs \(Int(propRadius + 8)) mm clearance at the centre.") }
            let out = w.build(full: true, surfaces: v1 > v0 + 10 ? [v0...v1] : [], fraction: f)

            var outline = out.outline
            for v in [-12.0, 12.0] {
                outline = Poly.insertNotch(outline, at: Vec2(w.le(v), v))
                outline = Poly.insertNotch(outline, at: Vec2(w.te(v), v))
            }

            var holes: [Hole] = []
            let features = out.features + sparFeatures(full: true)

            // Elevon servos and horns.
            let sv = c.servo.size
            for side in [-1.0, 1.0] where v1 > v0 + 10 {
                let vs = v0 + max(sv.w, 14)
                let hingeU = w.te(vs) - f * w.chord(vs)
                let center = Vec2(hingeU - 10 - sv.l / 2, side * vs)
                holes.append(servoCut(side < 0 ? "Left elevon" : "Right elevon", center: center, size: Vec2(sv.l, sv.w), in: out.main))
                let horn = Vec2(hingeU + 7, side * vs)
                holes.append(hornSlot(at: horn))
                controls.append(ControlSurface(name: side < 0 ? "Left elevon" : "Right elevon",
                                               hingeMid: [side * (v0 + v1) / 2, 0, w.te((v0 + v1) / 2) - f * w.chord((v0 + v1) / 2)],
                                               hornPosition: [horn.y, t / 2, horn.x], servoPosition: [center.y, 0, center.x],
                                               area: Poly.area(out.controls.first ?? []), chord: f * c.rootChord * (1 + c.taper) / 2))
            }

            // Vertical surfaces: winglets (flying wing) or a centre fin (delta).
            let finHeight = c.wingletHeight
            if finHeight > 5 {
                let isDelta = c.kind == .delta
                let fc = isDelta ? c.rootChord * 0.42 : c.tipChord * 0.85
                var fin = [Vec2(0, 0), Vec2(fc, 0), Vec2(fc + finHeight * 0.2, finHeight),
                           Vec2(min(finHeight * 0.55 + fc * 0.25, fc * 0.75 + finHeight * 0.2), finHeight)]
                let tabs = [fc * 0.25, fc * 0.62]
                for tu in tabs { fin = Poly.insertTab(fin, at: Vec2(tu, 0), width: 8, height: t) }
                var instances: [Placement] = []
                let stations: [Double] = isDelta ? [0] : [-(s - 6), s - 6]
                for v in stations {
                    let u0 = isDelta ? c.rootChord * 0.52 : w.le(v) + 0.08 * w.chord(v)
                    instances.append(Placement(origin: [v, t / 2, u0], u: [0, 0, 1], v: [0, 1, 0]))
                    for tu in tabs {
                        holes.append(slot(minU: u0 + tu - 4, maxU: u0 + tu + 4, minV: v - t / 2, maxV: v + t / 2))
                    }
                }
                parts.append(Part(name: isDelta ? "Centre fin" : "Winglet", role: isDelta ? .fin : .winglet,
                                  outline: fin, features: [.label(isDelta ? "FIN" : "WINGLET", Vec2(fc * 0.45, finHeight * 0.4))],
                                  instances: instances, material: c.material, mirroredPair: false))
            }

            // Centre keel: carries the battery ahead of the leading edge and keys into the wing with tabs.
            let nl = c.noseLength, hk = keelHeight
            var keel = [Vec2(-nl, 0), Vec2(-nl, -hk * 0.55), Vec2(-nl + 18, -hk), Vec2(c.rootChord * 0.5, -hk), Vec2(c.rootChord * 0.62, 0)]
            let keelTabs = [c.rootChord * 0.12, c.rootChord * 0.4]
            for tu in keelTabs {
                keel = Poly.insertTab(keel, at: Vec2(tu, 0), width: 8, height: t)
                holes.append(slot(minU: tu - 4, maxU: tu + 4, minV: -t / 2, maxV: t / 2))
            }
            keel = Poly.insertNotch(keel, at: Vec2(0, -hk), width: 3, depth: 2)
            parts.append(Part(name: "Keel / battery pod", role: .fuselage, outline: keel,
                              features: [.zone(Poly.rect(center: Vec2(c.batteryPosition, -hk / 2), size: Vec2(c.battery.size.l, c.battery.size.w)), "Battery"),
                                         .label("KEEL", Vec2(c.rootChord * 0.2, -hk * 0.5))],
                              instances: [.vertical(at: [0, -t / 2, 0])], material: c.material))
            parts.insert(Part(name: "Wing", role: .wing, outline: outline, holes: holes, features: features,
                              regions: regions(out), instances: [.horizontal(at: .zero)], material: c.material), at: 0)
        }

        // MARK: Tailed (profile fuselage)

        mutating func buildTailed() {
            let w = wing
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm
            let hsc = c.hStabChord, vsc = c.vStabChord
            let uT = ta + hsc
            let bh = max(20, fh * 0.32)
            let vtb = -bh * 0.3, vtt = vtb + bh
            let finTop = vtt + c.vStabHeight
            let elevFrac = 0.4
            let uH = uT - 0.4 * vsc
            let uEh = ta + hsc * (1 - elevFrac)
            let uE = min(uH, uEh)

            // --- Wing
            let f = c.controlChordPct
            let surfaces: [ClosedRange<Double>] = c.kind.hasAilerons ? [(s * 0.3)...(s - 10)] : []
            let full = c.dihedral < 0.5
            let out = w.build(full: full, surfaces: surfaces, fraction: f)
            var wingOutline = out.outline
            var wingHoles: [Hole] = []
            if full {
                for v in [-t / 2 - 0.5, t / 2 + 0.5] {
                    wingOutline = Poly.insertNotch(wingOutline, at: Vec2(w.le(v), v), width: 3, depth: 2)
                    wingOutline = Poly.insertNotch(wingOutline, at: Vec2(w.te(v), v), width: 3, depth: 2)
                }
            } else {
                wingOutline = Poly.insertNotch(wingOutline, at: Vec2(c.rootChord * 0.3, 0))
                wingOutline = Poly.insertNotch(wingOutline, at: Vec2(c.rootChord * 0.75, 0))
            }
            if c.kind.hasAilerons {
                let sv = c.servo.size
                let sides: [Double] = full ? [-1, 1] : [1]
                for side in sides {
                    let vs = s * 0.3 + 14
                    let hingeU = w.te(vs) - f * w.chord(vs)
                    let center = Vec2(hingeU - 8 - sv.l / 2, side * vs)
                    wingHoles.append(servoCut(side < 0 ? "Left aileron" : "Aileron", center: center, size: Vec2(sv.l, sv.w), in: out.main))
                    let horn = Vec2(hingeU + 7, side * vs)
                    wingHoles.append(hornSlot(at: horn))
                }
                for side in [-1.0, 1.0] {
                    let vs = s * 0.3 + 14
                    let hingeU = w.te(vs) - f * w.chord(vs)
                    controls.append(ControlSurface(name: side < 0 ? "Left aileron" : "Right aileron",
                                                   hingeMid: [side * s * 0.65, 0, hingeU], hornPosition: [side * vs, t / 2, hingeU + 7],
                                                   servoPosition: [side * vs, 0, hingeU - 8 - c.servo.size.l / 2],
                                                   area: Poly.area(out.controls.first ?? []), chord: f * c.rootChord * (1 + c.taper) / 2))
                }
            }
            let d = c.dihedral * .pi / 180
            let wingInstances: [Placement] = full ? [.horizontal(at: .zero)] : [
                Placement(origin: [t / 2, 0, 0], u: [0, 0, 1], v: [cos(d), sin(d), 0]),
                Placement(origin: [-t / 2, 0, 0], u: [0, 0, 1], v: [-cos(d), sin(d), 0])
            ]
            parts.append(Part(name: full ? "Wing" : "Wing half", role: .wing, outline: wingOutline, holes: wingHoles,
                              features: out.features + sparFeatures(full: full), regions: regions(out),
                              instances: wingInstances, material: c.material, mirroredPair: !full))

            // --- Fuselage profile (with integrated fin + rudder)
            let p0 = Vec2(uN, -fh * 0.3), p1 = Vec2(uN + 0.25 * c.noseLength, -fh * 0.5)
            let p2 = Vec2(c.rootChord * 0.9, -fh * 0.5), pb = Vec2(ta - 15, vtb)
            let p3 = Vec2(uE, vtb), p4 = Vec2(uE, vtt)
            let p6 = Vec2(uT, finTop), p7 = Vec2(uT - 0.75 * vsc, finTop), p8 = Vec2(uT - 1.5 * vsc, vtt)
            let top: [Vec2] = [Vec2(c.rootChord * 0.9, fh * 0.45), Vec2(0, fh * 0.5), Vec2(uN + 0.25 * c.noseLength, fh * 0.45), Vec2(uN, fh * 0.3)]
            var fus = [p0, p1, p2, pb, p3, p4, Vec2(uT, vtt), p6, p7, p8] + top
            var mainF = [p0, p1, p2, pb, p3, p4] + (uE < uH - 0.01 ? [Vec2(uH, vtt)] : []) + [Vec2(uH, finTop), p7, p8] + top
            let rudder = [Vec2(uH, vtt), Vec2(uT, vtt), Vec2(uT, finTop), Vec2(uH, finTop)]
            if pb.x <= p2.x + 5 { issues.append("Tail arm is too short for the wing chord – the fuselage boom would overlap the wing.") }
            if p8.x <= top[0].x + 5 { issues.append("Fin is too long for the tail arm – fin leading edge reaches the wing.") }
            if !Poly.isSimple(fus) { issues.append("Fuselage outline intersects itself – check tail arm, fin and nose dimensions.") }

            // Tabs locating the stabiliser under the boom.
            let tabUs = [ta + hsc * 0.15, ta + hsc * 0.42].filter { $0 + 5 < uE }
            for tu in tabUs { fus = Poly.insertTab(fus, at: Vec2(tu, vtb), width: 8, height: t); mainF = Poly.insertTab(mainF, at: Vec2(tu, vtb), width: 8, height: t) }
            fus = Poly.insertNotch(fus, at: Vec2(uN + 0.6 * c.noseLength, -fh * 0.5 + 0.1))

            var fHoles: [Hole] = [slot(minU: 0, maxU: c.rootChord, minV: -t / 2, maxV: t / 2)]
            if fh / 2 - t / 2 < 8 { issues.append("Fuselage height is too small around the wing slot.") }
            // Elevator & rudder servos above the wing slot.
            let sv = c.servo.size
            let vC = t / 2 + 3 + sv.h / 2
            let wingSlot = fHoles[0].polygon
            let s1 = Vec2(c.rootChord * 0.08 + sv.l / 2, vC), s2 = Vec2(s1.x + sv.l + 5, vC)
            fHoles.append(servoCut("Elevator", center: s1, size: Vec2(sv.l, sv.h), in: mainF, avoid: [wingSlot]))
            fHoles.append(servoCut("Rudder", center: s2, size: Vec2(sv.l, sv.h), in: mainF, avoid: [wingSlot]))
            let rudderHorn = Vec2(uH + 7, vtt + 8)
            fHoles.append(hornSlot(at: rudderHorn))
            let fFeatures: [Feature] = [
                .hinge(Vec2(uH, vtt), Vec2(uH, finTop)), .cut(Vec2(uH, vtt), Vec2(uT, vtt)),
                .label("FUSELAGE", Vec2(c.rootChord * 0.5, -fh * 0.3)),
                .zone(Poly.rect(center: Vec2(c.batteryPosition, -fh * 0.22), size: Vec2(c.battery.size.l, c.battery.size.h)), "Battery")
            ]
            parts.append(Part(name: "Fuselage", role: .fuselage, outline: fus, holes: fHoles, features: fFeatures,
                              regions: [Region(polygon: mainF, isControl: false), Region(polygon: rudder, isControl: true)],
                              instances: [.vertical(at: .zero)], material: c.material))

            // --- Horizontal stabiliser (glued under the boom, located by the tabs).
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc * 0.8, sweep: hsc * 0.1, semiSpan: c.hStabSpan / 2)
            let so = stab.buildFullSpanSurface(fraction: elevFrac)
            var stabOutline = Poly.insertNotch(so.outline, at: Vec2(stab.le(0) + 0.01, 3), width: 3, depth: 2)
            stabOutline = Poly.insertNotch(stabOutline, at: Vec2(stab.te(0), 0), width: 3, depth: 2)
            var sHoles = tabUs.map { slot(minU: $0 - 4, maxU: $0 + 4, minV: -t / 2, maxV: t / 2) }
            let eHorn = Vec2(stab.te(t / 2 + 7) - elevFrac * stab.chord(t / 2 + 7) + 7, t / 2 + 7)
            sHoles.append(hornSlot(at: eHorn))
            parts.append(Part(name: "Stabiliser", role: .stabilizer, outline: stabOutline, holes: sHoles, features: so.features,
                              regions: [Region(polygon: so.main, isControl: false)] + so.controls.map { Region(polygon: $0, isControl: true) },
                              instances: [.horizontal(at: [0, vtb - t / 2, 0])], material: c.material))

            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, vtb - t / 2, uEh], hornPosition: [eHorn.y, vtb - t, eHorn.x],
                                           servoPosition: [0, s1.y, s1.x], area: Poly.area(so.controls[0]) / 2, chord: elevFrac * hsc * 0.9))
            controls.append(ControlSurface(name: "Rudder", hingeMid: [0, (vtt + finTop) / 2, uH], hornPosition: [t / 2, rudderHorn.y, rudderHorn.x],
                                           servoPosition: [0, s2.y, s2.x], area: Poly.area(rudder), chord: 0.4 * vsc))
        }

        // MARK: Electronics & hardware

        mutating func addElectronics() {
            let pusher = c.kind.isPusher
            let motorZ = pusher ? c.rootChord + 18 : -c.noseLength - 12
            components.append(MassItem(name: c.motor.name, mass: c.motor.mass, position: [0, 0, motorZ], category: "Power"))
            components.append(MassItem(name: "Propeller \(String(format: "%.1f", c.motor.propInches))\"", mass: c.motor.propInches * 0.35,
                                       position: [0, 0, motorZ + (pusher ? 10 : -8)], category: "Power"))
            components.append(MassItem(name: "ESC", mass: c.motor.escMass, position: [0, 0, pusher ? c.rootChord * 0.25 : -c.noseLength * 0.3], category: "Power"))
            components.append(MassItem(name: "Receiver", mass: 2.5, position: [0, 0, pusher ? c.rootChord * 0.05 : c.rootChord * 0.3], category: "Radio"))
            components.append(MassItem(name: "Wiring & connectors", mass: 3, position: [0, 0, c.rootChord * 0.15], category: "Radio"))
            let batY = c.kind.isTailless ? -t / 2 - keelHeight / 2 : -c.fuselageHeight * 0.22
            components.append(MassItem(name: c.battery.name, mass: c.battery.mass, position: [0, batY, c.batteryPosition], category: "Battery"))
            components.append(MassItem(name: "Motor mount (printed)", mass: 1.2 + c.motor.mass * 0.12, position: [0, 0, motorZ + (pusher ? -10 : 10)], category: "Printed"))

            for ctrl in controls {
                components.append(MassItem(name: "Servo – \(ctrl.name)", mass: c.servo.mass, position: ctrl.servoPosition, category: "Radio"))
                components.append(MassItem(name: "Horn – \(ctrl.name)", mass: 0.3, position: ctrl.hornPosition, category: "Printed"))
                let len = simd_distance(ctrl.servoPosition, ctrl.hornPosition)
                components.append(MassItem(name: "Pushrod – \(ctrl.name)", mass: len / 1000 * 1.6 + 0.2,
                                           position: (ctrl.servoPosition + ctrl.hornPosition) / 2, category: "Hardware"))
            }
            if c.sparEnabled {
                let spar = sparSpec
                components.append(MassItem(name: spar.name, mass: sparLength / 1000 * spar.gramsPerMeter,
                                           position: [0, 0, c.rootChord * 0.3 + c.sweep * 0.45], category: "Hardware"))
            }
            if !c.kind.isTailless && c.dihedral >= 0.5 {
                components.append(MassItem(name: "Dihedral joiner (printed)", mass: 2.0, position: [0, -t, c.rootChord * 0.4], category: "Printed"))
            }
            // Glue, hinge tape, velcro ≈ 7 % of the foam.
            var foam = 0.0, moment = SIMD3<Double>.zero
            for p in parts {
                for inst in p.instances { foam += p.massEach; moment += inst.point(p.centroid2D) * p.massEach }
            }
            if foam > 0 {
                components.append(MassItem(name: "Glue, tape, velcro", mass: foam * 0.07, position: moment / foam, category: "Hardware"))
            }
        }

        var keelHeight: Double { max(c.battery.size.w + 8, 26) }
        var sparLength: Double { c.sparLength }
        var sparSpec: CarbonSpar { c.sparSpec }
    }
}
