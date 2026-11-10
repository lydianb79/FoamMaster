import Foundation
import simd

extension AircraftConfig {
    /// z of the motor (aircraft frame, mm aft of the root leading edge).
    var motorZ: Double {
        if kind.isTailless { return rootChord + 18 }
        if kind.isTwinBoom { return podEnd + 16 }
        return -noseLength - 12
    }
    /// z of the propeller disc.
    var propPlaneZ: Double { kind.isPusher ? motorZ + 8 : motorZ - 10 }
    var podEnd: Double { rootChord + 10 }
    /// Lateral position of the twin booms / fins.
    var boomX: Double { hStabSpan / 2 - 7 }
}

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
        /// FPV camera / VTX mounting positions chosen by the airframe builder.
        var fpvCamera = SIMD3<Double>.zero
        var fpvVTX = SIMD3<Double>.zero
        var batteryPos = SIMD3<Double>.zero

        var t: Double { c.material.thickness }
        var s: Double { c.semiSpan }
        var propRadius: Double { c.motor.propInches * 25.4 / 2 }

        var wing: TaperedPanel {
            TaperedPanel(rootChord: c.rootChord, tipChord: c.tipChord, sweep: c.sweep, semiSpan: s)
        }

        mutating func run() {
            if c.kind.isTailless { buildTailless() }
            else if c.kind.isTwinBoom { buildTwinBoom() }
            else { buildTailed() }
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

        /// Vertical fin with locating tabs at the bottom edge (winglets, delta fin, twin-boom fins).
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
            var features = out.features + sparFeatures(full: true)

            let sv = c.servo.size
            for side in [-1.0, 1.0] where v1 > v0 + 10 {
                let vs = v0 + max(sv.w, 14)
                let hingeU = w.te(vs) - f * w.chord(vs)
                let center = Vec2(hingeU - 10 - sv.l / 2, side * vs)
                let name = side < 0 ? "Left elevon" : "Right elevon"
                holes.append(servoCut(name, center: center, size: Vec2(sv.l, sv.w), in: out.main))
                let horn = Vec2(hingeU + 7, side * vs)
                holes.append(hornSlot(at: horn))
                controls.append(ControlSurface(name: name,
                                               hingeMid: [side * (v0 + v1) / 2, 0, w.te((v0 + v1) / 2) - f * w.chord((v0 + v1) / 2)],
                                               hornPosition: [horn.y, t / 2, horn.x], servoPosition: [center.y, 0, center.x],
                                               area: Poly.area(out.controls.first ?? []), chord: f * c.rootChord * (1 + c.taper) / 2, servoID: name))
            }

            let finHeight = c.wingletHeight
            if finHeight > 5 {
                let isDelta = c.kind == .delta
                let fc = isDelta ? c.rootChord * 0.42 : c.tipChord * 0.85
                let fin = finOutline(chord: fc, height: finHeight)
                var instances: [Placement] = []
                let stations: [Double] = isDelta ? [0] : [-(s - 6), s - 6]
                for v in stations {
                    let u0 = isDelta ? c.rootChord * 0.52 : w.le(v) + 0.08 * w.chord(v)
                    instances.append(Placement(origin: [v, t / 2, u0], u: [0, 0, 1], v: [0, 1, 0]))
                    for tu in fin.tabs { holes.append(slot(minU: u0 + tu - 4, maxU: u0 + tu + 4, minV: v - t / 2, maxV: v + t / 2)) }
                }
                parts.append(Part(name: isDelta ? "Centre fin" : "Winglet", role: isDelta ? .fin : .winglet,
                                  outline: fin.outline, features: [.label(isDelta ? "FIN" : "WINGLET", Vec2(fc * 0.45, finHeight * 0.4))],
                                  instances: instances, material: c.material))
            }

            // Battery sits on top of the centre section; FPV camera at the apex, VTX behind it.
            let b = c.battery.size
            features.append(.zone(Poly.rect(center: Vec2(c.batteryPosition, 0), size: Vec2(b.l, b.w)), "Battery"))
            batteryPos = [0, t / 2 + b.h / 2, c.batteryPosition]
            fpvCamera = [0, t / 2 + 8, 4]
            fpvVTX = [0, t / 2 + 4, c.rootChord * 0.55]
            if c.fpv != .none {
                features.append(.zone(Poly.rect(center: Vec2(8, 0), size: Vec2(14, 18)), "Cam"))
            }
            parts.insert(Part(name: "Wing", role: .wing, outline: outline, holes: holes, features: features,
                              regions: regions(out), instances: [.horizontal(at: .zero)], material: c.material), at: 0)
        }

        // MARK: Wing for tailed aircraft (shared by conventional + twin boom)

        mutating func buildTailedWing(fuselageServoRegion: inout [Vec2]?, allowDihedral: Bool, extraFeatures: [Feature] = []) -> Bool {
            let w = wing
            let f = c.controlChordPct
            let full = !allowDihedral || c.dihedral < 0.5
            let central = c.kind.hasAilerons && c.aileronServos == 1
            let a0 = central ? t / 2 + 5 : s * 0.3
            let surfaces: [ClosedRange<Double>] = c.kind.hasAilerons ? [a0...(s - 10)] : []
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
            var features = out.features + sparFeatures(full: full) + extraFeatures
            if c.kind.hasAilerons {
                let sv = c.servo.size
                let area = Poly.area(out.controls.first ?? [])
                let chord = f * c.rootChord * (1 + c.taper) / 2
                if central {
                    // One servo in the fuselage below the wing drives both ailerons through torque rods.
                    let hingeRoot = w.te(0) - f * w.chord(0)
                    for side in [-1.0, 1.0] {
                        let v = side * (t / 2 + 5 + 4)
                        features.append(.zone(Poly.rect(center: Vec2(hingeRoot - 1, v), size: Vec2(2, 8)), ""))
                        controls.append(ControlSurface(name: side < 0 ? "Left aileron" : "Right aileron",
                                                       hingeMid: [side * s * 0.55, 0, hingeRoot], hornPosition: [side * (t / 2 + 6), -t, hingeRoot - 6],
                                                       servoPosition: [0, -t / 2 - 3 - sv.h / 2, c.rootChord - 6 - sv.l / 2],
                                                       area: area, chord: chord, servoID: "Ailerons (torque rods)"))
                    }
                    fuselageServoRegion = []   // signal: add the aileron servo below the wing slot
                } else {
                    let sides: [Double] = full ? [-1, 1] : [1]
                    let vs = s * 0.3 + 14
                    let hingeU = w.te(vs) - f * w.chord(vs)
                    for side in sides {
                        let center = Vec2(hingeU - 8 - sv.l / 2, side * vs)
                        wingHoles.append(servoCut(side < 0 ? "Left aileron" : "Aileron", center: center, size: Vec2(sv.l, sv.w), in: out.main))
                        wingHoles.append(hornSlot(at: Vec2(hingeU + 7, side * vs)))
                    }
                    for side in [-1.0, 1.0] {
                        let name = side < 0 ? "Left aileron" : "Right aileron"
                        controls.append(ControlSurface(name: name, hingeMid: [side * s * 0.65, 0, hingeU],
                                                       hornPosition: [side * vs, t / 2, hingeU + 7],
                                                       servoPosition: [side * vs, 0, hingeU - 8 - sv.l / 2],
                                                       area: area, chord: chord, servoID: name))
                    }
                }
            }
            let d = c.dihedral * .pi / 180
            let wingInstances: [Placement] = full ? [.horizontal(at: .zero)] : [
                Placement(origin: [t / 2, 0, 0], u: [0, 0, 1], v: [cos(d), sin(d), 0]),
                Placement(origin: [-t / 2, 0, 0], u: [0, 0, 1], v: [-cos(d), sin(d), 0])
            ]
            parts.append(Part(name: full ? "Wing" : "Wing half", role: .wing, outline: wingOutline, holes: wingHoles,
                              features: features, regions: regions(out),
                              instances: wingInstances, material: c.material, mirroredPair: !full))
            return central
        }

        // MARK: Conventional (profile fuselage, optional cross / X reinforcement)

        mutating func buildTailed() {
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

            var aileronServoFlag: [Vec2]? = nil
            let central = buildTailedWing(fuselageServoRegion: &aileronServoFlag, allowDihedral: true)

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

            let tabUs = [ta + hsc * 0.15, ta + hsc * 0.42].filter { $0 + 5 < uE }
            for tu in tabUs { fus = Poly.insertTab(fus, at: Vec2(tu, vtb), width: 8, height: t); mainF = Poly.insertTab(mainF, at: Vec2(tu, vtb), width: 8, height: t) }
            fus = Poly.insertNotch(fus, at: Vec2(uN + 0.6 * c.noseLength, -fh * 0.5 + 0.1))

            var fHoles: [Hole] = [slot(minU: 0, maxU: c.rootChord, minV: -t / 2, maxV: t / 2)]
            if fh / 2 - t / 2 < 8 { issues.append("Fuselage height is too small around the wing slot.") }
            let sv = c.servo.size
            let vC = t / 2 + 3 + sv.h / 2
            let wingSlot = fHoles[0].polygon
            let s1 = Vec2(c.rootChord * 0.08 + sv.l / 2, vC), s2 = Vec2(s1.x + sv.l + 5, vC)
            fHoles.append(servoCut("Elevator", center: s1, size: Vec2(sv.l, sv.h), in: mainF, avoid: [wingSlot]))
            fHoles.append(servoCut("Rudder", center: s2, size: Vec2(sv.l, sv.h), in: mainF, avoid: [wingSlot]))
            if central {
                let sa = Vec2(c.rootChord - 6 - sv.l / 2, -t / 2 - 3 - sv.h / 2)
                fHoles.append(servoCut("Ailerons", center: sa, size: Vec2(sv.l, sv.h), in: mainF, avoid: [wingSlot]))
            }
            let rudderHorn = Vec2(uH + 7, vtt + 8)
            fHoles.append(hornSlot(at: rudderHorn))
            var fFeatures: [Feature] = [
                .hinge(Vec2(uH, vtt), Vec2(uH, finTop)), .cut(Vec2(uH, vtt), Vec2(uT, vtt)),
                .label("FUSELAGE", Vec2(c.rootChord * 0.5, -fh * 0.3)),
                .zone(Poly.rect(center: Vec2(c.batteryPosition, -fh * 0.22), size: Vec2(c.battery.size.l, c.battery.size.h)), "Battery")
            ]
            if c.fuselageType != .profile {
                fFeatures.append(.zone(Poly.rect(minU: uN + 28, maxU: -2, minV: -0.6, maxV: 0.6), ""))
                fFeatures.append(.zone(Poly.rect(minU: c.rootChord + 2, maxU: ta - 12, minV: -0.6, maxV: 0.6), ""))
            }
            parts.append(Part(name: "Fuselage", role: .fuselage, outline: fus, holes: fHoles, features: fFeatures,
                              regions: [Region(polygon: mainF, isControl: false), Region(polygon: rudder, isControl: true)],
                              instances: [.vertical(at: .zero)], material: c.material))

            addFuselageBracing(uN: uN, fh: fh, bh: bh, ta: ta)

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
                                           servoPosition: [0, s1.y, s1.x], area: Poly.area(so.controls[0]) / 2, chord: elevFrac * hsc * 0.9, servoID: "Elevator"))
            controls.append(ControlSurface(name: "Rudder", hingeMid: [0, (vtt + finTop) / 2, uH], hornPosition: [t / 2, rudderHorn.y, rudderHorn.x],
                                           servoPosition: [0, s2.y, s2.x], area: Poly.area(rudder), chord: 0.4 * vsc, servoID: "Rudder"))

            batteryPos = [t / 2 + c.battery.size.h / 2, -fh * 0.22, c.batteryPosition]
            fpvCamera = [0, fh * 0.3 + 7, uN + 14]
            fpvVTX = [-(t / 2 + 3), fh * 0.12, c.rootChord * 0.55]
        }

        /// Cross (+) or X reinforcement strips glued along the fuselage sides, ahead of and behind the wing.
        mutating func addFuselageBracing(uN: Double, fh: Double, bh: Double, ta: Double) {
            guard c.fuselageType != .profile else { return }
            let isX = c.fuselageType == .xBrace
            let wFront = min(fh * (isX ? 0.28 : 0.36), 26), wRear = min(bh * (isX ? 0.5 : 0.7), 18)
            let f0 = uN + 28, f1 = -2.0
            let r0 = c.rootChord + 2, r1 = ta - 12
            let dirs: [SIMD3<Double>] = isX
                ? [[0.7071, 0.7071, 0], [0.7071, -0.7071, 0], [-0.7071, 0.7071, 0], [-0.7071, -0.7071, 0]]
                : [[1, 0, 0], [-1, 0, 0]]
            let inst = dirs.map { d in Placement(origin: [d.x > 0 ? t / 2 : -t / 2, 0, 0], u: [0, 0, 1], v: d) }
            let label = isX ? "X-brace" : "Cross plate"
            if f1 - f0 > 20 {
                var front = [Vec2(f0, 0), Vec2(f1, 0), Vec2(f1, wFront), Vec2(f0 + wFront * 0.8, wFront)]
                front = Poly.insertNotch(front, at: Vec2((f0 + f1) / 2, 0), width: 3, depth: 1.5)
                parts.append(Part(name: "\(label) – front", role: .fuselage, outline: front,
                                  features: [.label(isX ? "X" : "+", Vec2((f0 + f1) / 2, wFront / 2))],
                                  instances: inst, material: c.material))
            }
            if r1 - r0 > 20 {
                var rear = [Vec2(r0, 0), Vec2(r1, 0), Vec2(r1, wRear * 0.5), Vec2(r0, wRear)]
                rear = Poly.insertNotch(rear, at: Vec2((r0 + r1) / 2, 0), width: 3, depth: 1.5)
                parts.append(Part(name: "\(label) – rear", role: .fuselage, outline: rear,
                                  features: [.label(isX ? "X" : "+", Vec2((r0 + r1) / 2, wRear / 3))],
                                  instances: inst, material: c.material))
            }
        }

        // MARK: Twin boom pusher (SkyKart)

        mutating func buildTwinBoom() {
            let fh = c.fuselageHeight
            let uN = -c.noseLength
            let ta = c.tailArm, hsc = c.hStabChord
            let xb = c.boomX
            let boomY = -t / 2 - 2
            let rod = CarbonSpar.tube4

            var flag: [Vec2]? = nil
            let boomMarks: [Feature] = [-xb, xb].map { .spar(Vec2(c.rootChord * 0.15, $0), Vec2(wing.te($0) - 1, $0), rod.widthMM) }
            _ = buildTailedWing(fuselageServoRegion: &flag, allowDihedral: false, extraFeatures: boomMarks)

            // Pod: nose cone carrying battery, FPV and servos; motor at the tail end.
            let pe = c.podEnd
            var pod = [Vec2(uN, -fh * 0.25), Vec2(uN + 0.3 * c.noseLength, -fh * 0.5), Vec2(c.rootChord * 0.7, -fh * 0.5),
                       Vec2(pe, -fh * 0.22), Vec2(pe, fh * 0.22), Vec2(c.rootChord * 0.6, fh * 0.5), Vec2(uN + 0.35 * c.noseLength, fh * 0.45), Vec2(uN, fh * 0.2)]
            pod = Poly.insertNotch(pod, at: Vec2(uN + 0.6 * c.noseLength, -fh * 0.5 + 0.1))
            var holes: [Hole] = [slot(minU: 0, maxU: c.rootChord, minV: -t / 2, maxV: t / 2)]
            let sv = c.servo.size
            let s1 = Vec2(c.rootChord * 0.1 + sv.l / 2, t / 2 + 3 + sv.h / 2), s2 = Vec2(s1.x + sv.l + 5, s1.y)
            holes.append(servoCut("Elevator", center: s1, size: Vec2(sv.l, sv.h), in: pod, avoid: [holes[0].polygon]))
            holes.append(servoCut("Rudders", center: s2, size: Vec2(sv.l, sv.h), in: pod, avoid: [holes[0].polygon]))
            parts.append(Part(name: "Pod", role: .fuselage, outline: pod, holes: holes,
                              features: [.label("POD", Vec2(uN * 0.5, -fh * 0.25)),
                                         .zone(Poly.rect(center: Vec2(c.batteryPosition, -fh * 0.2), size: Vec2(c.battery.size.l, c.battery.size.h)), "Battery")],
                              instances: [.vertical(at: .zero)], material: c.material))
            if fh / 2 - t / 2 < 8 { issues.append("Pod height is too small around the wing slot.") }

            // Stabiliser resting on the booms, elevator stops short of the fins.
            let sh = c.hStabSpan / 2
            let stab = TaperedPanel(rootLE: ta, rootChord: hsc, tipChord: hsc, sweep: 0, semiSpan: sh)
            let so = stab.build(full: true, surfaces: [1...(sh - 14)], fraction: 0.4)
            var stabHoles: [Hole] = []
            let fin = finOutline(chord: c.vStabChord, height: c.vStabHeight, rudderFrac: 0.4)
            let finU0 = ta + hsc - c.vStabChord
            for x in [-xb, xb] {
                for tu in fin.tabs { stabHoles.append(slot(minU: finU0 + tu - 4, maxU: finU0 + tu + 4, minV: x - t / 2, maxV: x + t / 2)) }
            }
            let eHorn = Vec2(ta + hsc * 0.6 + 7, 8)
            stabHoles.append(hornSlot(at: eHorn))
            let stabY = boomY + 2 + t / 2
            parts.append(Part(name: "Stabiliser", role: .stabilizer, outline: so.outline, holes: stabHoles,
                              features: so.features + [-xb, xb].map { .spar(Vec2(ta, $0), Vec2(ta + hsc * 0.55, $0), rod.widthMM) },
                              regions: regions(so), instances: [.horizontal(at: [0, stabY, 0])], material: c.material))
            if finU0 < ta { issues.append("Fin chord is longer than the stabiliser chord.") }

            let finInst = [-xb, xb].map { Placement(origin: [$0, stabY + t / 2, finU0], u: [0, 0, 1], v: [0, 1, 0]) }
            var finRegions = [Region(polygon: fin.main, isControl: false)]
            if let r = fin.rudder { finRegions.append(Region(polygon: r, isControl: true)) }
            let rHingeU = c.vStabChord * 0.6
            parts.append(Part(name: "Fin", role: .fin, outline: fin.outline,
                              holes: [hornSlot(at: Vec2(rHingeU + 7, 10))],
                              features: [.hinge(Vec2(rHingeU, 0), Vec2(rHingeU, c.vStabHeight)), .label("FIN", Vec2(c.vStabChord * 0.3, c.vStabHeight * 0.4))],
                              regions: finRegions, instances: finInst, material: c.material))

            if xb < propRadius + 6 { issues.append("Booms are inside the propeller disc – increase the stabiliser span (boom spacing) or use a smaller prop.") }

            let boomLen = ta + hsc * 0.55 - c.rootChord * 0.15
            components.append(MassItem(name: "Tail booms (2 × \(rod.name))", mass: 2 * boomLen / 1000 * rod.gramsPerMeter,
                                       position: [0, boomY, c.rootChord * 0.15 + boomLen / 2], category: "Hardware"))

            controls.append(ControlSurface(name: "Elevator", hingeMid: [0, stabY, ta + hsc * 0.6], hornPosition: [eHorn.y, stabY + t, eHorn.x],
                                           servoPosition: [0, s1.y, s1.x], area: Poly.area(so.controls.first ?? []) * 2, chord: 0.4 * hsc, servoID: "Elevator"))
            let rudderArea = (fin.rudder.map { Poly.area($0) } ?? 0) * 2
            controls.append(ControlSurface(name: "Rudders", hingeMid: [xb, stabY + c.vStabHeight / 2, finU0 + rHingeU],
                                           hornPosition: [xb + t / 2, stabY + 10, finU0 + rHingeU + 7],
                                           servoPosition: [0, s2.y, s2.x], area: rudderArea, chord: 0.4 * c.vStabChord, servoID: "Rudders"))

            batteryPos = [t / 2 + c.battery.size.h / 2, -fh * 0.2, c.batteryPosition]
            fpvCamera = [0, fh * 0.2 + 6, uN + 10]
            fpvVTX = [-(t / 2 + 3), fh * 0.1, c.rootChord * 0.5]
        }

        // MARK: Electronics & hardware

        mutating func addElectronics() {
            let pusher = c.kind.isPusher
            let motorZ = c.motorZ
            components.append(MassItem(name: c.motor.name, mass: c.motor.mass, position: [0, 0, motorZ], category: "Power"))
            components.append(MassItem(name: "Propeller \(String(format: "%.1f", c.motor.propInches))\"", mass: c.motor.propInches * 0.35,
                                       position: [0, 0, c.propPlaneZ], category: "Power"))
            components.append(MassItem(name: "ESC", mass: c.motor.escMass, position: [0, 0, pusher ? c.rootChord * 0.15 : -c.noseLength * 0.3], category: "Power"))
            components.append(MassItem(name: "Receiver", mass: 2.5, position: [0, 0, pusher ? c.rootChord * 0.1 : c.rootChord * 0.3], category: "Radio"))
            components.append(MassItem(name: "Wiring & connectors", mass: 3, position: [0, 0, c.rootChord * 0.15], category: "Radio"))
            components.append(MassItem(name: c.battery.name, mass: c.battery.mass, position: batteryPos, category: "Battery"))
            components.append(MassItem(name: "Motor mount (printed)", mass: 1.2 + c.motor.mass * 0.12, position: [0, 0, motorZ + (pusher ? -10 : 10)], category: "Printed"))

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
                components.append(MassItem(name: "Horn – \(ctrl.name)", mass: 0.3, position: ctrl.hornPosition, category: "Printed"))
                let len = simd_distance(ctrl.servoPosition, ctrl.hornPosition)
                components.append(MassItem(name: "Pushrod – \(ctrl.name)", mass: len / 1000 * 1.6 + 0.2,
                                           position: (ctrl.servoPosition + ctrl.hornPosition) / 2, category: "Hardware"))
            }
            if c.sparEnabled {
                components.append(MassItem(name: c.sparSpec.name, mass: c.sparLength / 1000 * c.sparSpec.gramsPerMeter,
                                           position: [0, 0, c.rootChord * 0.3 + c.sweep * 0.45], category: "Hardware"))
            }
            if c.kind.hasFuselage && c.dihedral >= 0.5 {
                components.append(MassItem(name: "Dihedral joiner (printed)", mass: 2.0, position: [0, -t, c.rootChord * 0.4], category: "Printed"))
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
