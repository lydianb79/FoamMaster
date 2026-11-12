import Foundation

struct BOMItem: Identifiable {
    let id = UUID()
    var category: String
    var item: String
    var spec: String
    var quantity: String
}

struct BuildStep: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var symbol: String
}

enum BuildDocs {
    static func billOfMaterials(_ d: Design, _ a: Analysis) -> [BOMItem] {
        let c = d.config
        var items: [BOMItem] = []
        let foamArea = d.parts.reduce(0) { $0 + Poly.area($1.outline) * Double($1.quantity) }
        let sheet = c.material.sheetSize
        let sheets = max(1, Int(ceil(foamArea * 1.35 / (sheet.w * sheet.h))))
        items.append(BOMItem(category: "Foam", item: c.material.displayName,
                             spec: "Sheet \(Int(sheet.w)) × \(Int(sheet.h)) mm · parts \(String(format: "%.1f", foamArea / 1e4)) dm²",
                             quantity: "\(sheets) sheet\(sheets > 1 ? "s" : "")"))

        if c.sparEnabled {
            let spar = c.sparSpec
            let pieces = c.kind.hasFuselage ? 1 : (c.sweep > 15 && c.kind.isTailless ? 2 : 1)
            let len = ceil(c.sparLength / Double(pieces) / 10) * 10
            items.append(BOMItem(category: "Carbon", item: spar.name, spec: "Wing spar, \(Int(len)) mm per piece – glued into a groove under the wing along the 30 % chord line (green band on the plan), bottom flush", quantity: "\(pieces)×"))
        }
        let pushLen = d.controls.reduce(0) { $0 + simd_distance($1.servoPosition, $1.hornPosition) }
        items.append(BOMItem(category: "Carbon", item: "Carbon rod Ø1 mm (pushrods)", spec: "Total \(Int(ceil(pushLen / 10) * 10 + 40)) mm", quantity: "\(d.controls.count)×"))
        items.append(BOMItem(category: "Hardware", item: "Steel wire Ø0.8 mm", spec: "Z-bend ends, 2 × 35 mm per pushrod + heat-shrink", quantity: "\(d.controls.count * 2)×"))
        let servoCount = Set(d.controls.map(\.servoID)).count
        if c.kind.isTwinBoom {
            let len = c.tailArm + c.hStabChord * 0.55 - c.rootChord * 0.15
            items.append(BOMItem(category: "Carbon", item: CarbonSpar.tube4.name, spec: "Tail booms, \(Int(ceil(len / 10) * 10)) mm each, glued into grooves under wing and stabiliser", quantity: "2×"))
        }
        if c.isDual {
            items.append(BOMItem(category: "Carbon", item: "Carbon flat strip 3 × 0.5 mm", spec: "Leading-edge reinforcement between the motors, \(Int(c.dualMotorX * 2 + 40)) mm", quantity: "1×"))
        }
        if c.hasAilerons && c.aileronServos == 1 && c.kind.allowsSingleAileronServo {
            items.append(BOMItem(category: "Hardware", item: "Double-ended servo arm", spec: "Comes with the servo – one pushrod from each end to the horn on each aileron", quantity: "1×"))
        }
        if d.trussLength > 0 {
            items.append(BOMItem(category: "Carbon", item: "Carbon flat strip 3 × 0.5 mm", spec: "Zig-zag truss on both sides of the fuselage halves, total \(Int(ceil(d.trussLength / 10) * 10)) mm", quantity: "\(Int(ceil(d.trussLength / 1000)))× 1 m"))
        }
        for (dia, group) in Dictionary(grouping: d.struts, by: \.diameter).sorted(by: { $0.key < $1.key }) {
            let lengths = group.map { Int(ceil($0.length)) }
            let total = lengths.reduce(0, +)
            let pairs = Dictionary(grouping: group, by: { String($0.label.dropLast()) }).sorted { $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count < $1.key.count }
                .map { "\($0.key) \(Int(ceil($0.value[0].length))) mm" }.joined(separator: ", ")
            items.append(BOMItem(category: "Carbon", item: "\(CarbonSpar.strutRod(dia).name) (struts)",
                                 spec: "Stabilisation struts, cut to length: \(pairs) (2× each, left + right) – total \(Int(ceil(Double(total) / 10) * 10 + 20)) mm, \(String(format: "%.1f", group.reduce(0) { $0 + $1.rodMass })) g",
                                 quantity: "\(group.count)×"))
        }
        let hingeLen = d.parts.reduce(0.0) { sum, p in
            sum + p.features.reduce(0.0) { s2, f in if case let .hinge(a, b) = f { return s2 + simd_distance(a, b) * Double(p.quantity) }; return s2 }
        }
        items.append(BOMItem(category: "Hardware", item: "Hinge tape (Blenderm / clear tape)", spec: "\(Int(ceil(hingeLen * 1.1 / 10) * 10)) mm", quantity: "1 roll"))
        items.append(BOMItem(category: "Hardware", item: "Glue", spec: c.material.glue, quantity: "1"))
        items.append(BOMItem(category: "Hardware", item: "Velcro strip", spec: "15 × 40 mm for the battery", quantity: "1"))
        let pat = c.motor.pattern
        items.append(BOMItem(category: "Hardware", item: "Motor screws \(pat.screw)", spec: "Cap/pan head, length = firewall + \(pat.thread >= 2 ? "3–4" : "2–3") mm thread engagement – \(pat.label) pattern", quantity: "\(pat.holes * c.motorCount)×"))

        items.append(BOMItem(category: "Electronics", item: c.motor.name, spec: "\(c.motor.allowedCells.lowerBound)–\(c.motor.allowedCells.upperBound)S, ~\(Int(a.thrust / Double(c.motorCount))) g thrust each, mount pattern \(c.motor.pattern.label)\(c.isDual ? ", one CW + one CCW" : "")", quantity: "\(c.motorCount)×"))
        items.append(BOMItem(category: "Electronics", item: "ESC", spec: "\(c.motor.escMass > 4 ? 12 : 6) A, \(c.battery.cells)S\(c.isDual ? " – both on the throttle channel via a Y-lead" : "")", quantity: "\(c.motorCount)×"))
        if c.isDual { items.append(BOMItem(category: "Electronics", item: "Y-lead + parallel battery adapter", spec: "Throttle signal to both ESCs, power from one pack", quantity: "1×")) }
        items.append(BOMItem(category: "Electronics", item: "Propeller \(c.propRecommendation)",
                             spec: "\(c.kind.propBladeReason) · for the \(c.motor.name) on \(c.battery.cells)S – balance before use", quantity: "2× (spare)"))
        items.append(BOMItem(category: "Electronics", item: c.battery.name, spec: "\(c.battery.mass) g", quantity: "1×"))
        items.append(BOMItem(category: "Electronics", item: c.servo.name, spec: "\(c.servo.torque) kg·cm", quantity: "\(servoCount)×"))
        items.append(BOMItem(category: "Electronics", item: "Receiver", spec: "\(d.channels)+ channels (\(servoCount) servo\(servoCount == 1 ? "" : "s") + throttle), micro", quantity: "1×"))
        if c.hasAilerons && c.aileronServos == 2 { items.append(BOMItem(category: "Electronics", item: "Servo extension", spec: "100 mm (aileron servos)", quantity: "2×")) }
        for p in PrintedParts.generate(d) {
            items.append(BOMItem(category: "3D printed", item: p.name, spec: "PETG/PLA, \(String(format: "%.1f", p.mass)) g, \(p.note)", quantity: "\(p.quantity)×"))
        }
        return items
    }

    static func steps(_ d: Design, _ a: Analysis) -> [BuildStep] {
        let c = d.config
        let pat = c.motor.pattern
        let cg = String(format: "%.0f", a.recommendedCG)
        var s: [BuildStep] = [
            BuildStep(title: "Print & assemble the plans", text: "Print the plan at 100 % (no scaling). Verify the 100 mm scale bar on the cover. Trim the tiles along the frame lines, align them with the registration crosses and tape them together.", symbol: "printer"),
            BuildStep(title: "Transfer & cut the foam", text: "Pin the plans onto the \(c.material.displayName) sheet and cut with a fresh snap-off blade along a metal ruler. Cut all slots, servo cutouts and horn slots (filled shapes) completely through. V-notches mark alignment points – cut them too.", symbol: "scissors"),
            BuildStep(title: "Prepare control surfaces", text: "Cut free each surface along the solid side cuts. On the dashed hinge line bevel the lower edge 45°, then hinge with tape on the top side. Check for at least ±30° deflection.\(c.kind.isTailless ? "" : c.kind.isTwinBoom ? " The elevator is one piece between the two fins." : " The elevator is one piece across the whole tail; the fin and rudder's lower edge is cut back so the elevator can move up underneath it, and the rudder hinge sits behind the elevator horn so the rudder never touches it – check both at full throw (elevator and rudder together).")", symbol: "rectangle.split.2x1")
        ]
        if c.sparEnabled {
            s.append(BuildStep(title: "Install the carbon spar", text: "Mark the green spar band on the underside of the wing and cut a groove \(String(format: "%.1f", c.sparSpec.widthMM)) mm wide and \(String(format: "%.1f", c.sparSpec.widthMM)) mm deep along it (two knife cuts, peel out the strip, or melt it with a hot rod). Fill with foam-safe glue and press in the \(c.sparSpec.name) flush with the surface. Wipe off excess glue and let cure flat.", symbol: "line.diagonal"))
        }
        if c.kind.hasFuselage {
            s.append(BuildStep(title: "Join the wing halves to the fuselage plate", text: "Push the wing-half tabs into the notches in the plate sides and glue with foam-safe CA. Then cut the spar groove underneath, straight across both wing halves and the plate, and glue in the one-piece carbon rod – it runs across the plate and locks the joint.", symbol: "rectangle.split.3x1"))
            s.append(BuildStep(title: "Fuselage top & bottom halves", text: "Press the tabs of the top half into the centre-line slots of the plate, then the bottom half from below. Check both halves are exactly 90° to the plate and in line – this + section is what makes the fuselage stiff.", symbol: "plus"))
        }
        if c.kind.isJet {
            s.append(BuildStep(title: "Wing, nose and tail plates", text: "Glue the spar strips into the top and bottom of the wing. Key the pointed nose plate into the leading edge and the tail plate into the trailing edge – this gives one flat piece from nose to tail.", symbol: "rectangle.split.3x1"))
            s.append(BuildStep(title: "Fuselage halves & prop slot", text: "Glue the front and rear top halves and the bottom halves on with their tabs. The halves stop either side of the prop slot – keep the slot free so the prop spins through the wing.", symbol: "plus"))
            s.append(BuildStep(title: "Mid-mounted motor", text: "Push the + shaped motor mount onto the rear end of the front fuselage halves so the prop sits in the middle of the slot. Check the prop clears the slot edges all round.", symbol: "fanblades"))
        }
        if c.kind.isTwinBoom {
            s.append(BuildStep(title: "Pod, booms & twin fins", text: "Key the pod nose plate into the wing leading edge, then glue the pod top and bottom halves on with their tabs. Groove the wing and stabiliser undersides along the boom lines, glue in both Ø4 mm carbon booms parallel to the pod. Push the fin tabs through the stabiliser slots.", symbol: "rectangle.split.3x1"))
            s.append(BuildStep(title: "Mount the pusher motor", text: "Slide the printed mount over the pod tail and glue. Prop clearance to the booms is checked by FoamMaster – verify it turns freely.", symbol: "fanblades"))
        } else if c.kind.isNutBall {
            s.append(BuildStep(title: "Spine, fin & keel", text: "Press the tabs of the spine (with the fin) into the centre-line slots on top of the disc and the keel from below. Check both are exactly 90° to the disc – the + section keeps the disc flat and carries the motor mount.", symbol: "plus"))
            s.append(BuildStep(title: "Mount the motor", text: "Screw the motor onto the printed firewall (\(pat.label), heads sit flush in the counterbores) and push its + shaped clamp onto the nose tongue, spine and keel. 2–3° right and down thrust help a NutBall fly straight.", symbol: "fanblades"))
            if c.tailWinglets && c.wingletHeight > 5 {
                s.append(BuildStep(title: "Fit the winglets", text: "The disc edge is rounded, so the winglets stand on top of the disc, inboard of the edge: push their two tabs through the matching slots marked on the disc plan until flush underneath. Check 90° to the disc and parallel to the spine, then glue.", symbol: "square.split.bottomrightquarter"))
            }
        } else if c.kind.isTailless {
            s.append(BuildStep(title: c.kind == .delta ? "Fit the centre fin" : "Fit the winglets", text: "Push the tabs through the matching slots in the wing until flush underneath. Check 90° to the wing with a square and glue.", symbol: "square.split.bottomrightquarter"))
            s.append(BuildStep(title: "Centre keel & motor", text: "Glue the centre keel under the wing with its tabs. Screw the motor onto the printed mount (\(pat.label), heads sit flush in the counterbores) and push its + shaped clamp onto the wing and keel at the front of the trailing-edge cutout – the prop spins inside the cutout.", symbol: "fanblades"))
        } else {
            s.append(BuildStep(title: "Mount the motor", text: "Screw the motor onto the printed firewall (\(pat.label), heads sit flush in the counterbores) and push its + shaped clamp over the nose so it grips the plate and both fuselage halves. 1–2° right thrust can be shimmed with a washer.", symbol: "fanblades"))
        }
        if c.hasAilerons && c.aileronServos == 1 && c.kind.allowsSingleAileronServo {
            s.append(BuildStep(title: "Single aileron servo", text: "Glue the aileron servo upside down (shaft pointing down) into the notch in the lower fuselage half under the wing – the notch leaves room for the servo and its arm. Fit a double-ended arm across the fuselage, centre it, and run one short pushrod from each arm end aft to the horn under the inner end of each aileron. Check the arm swings freely at full throw without touching the fuselage.", symbol: "arrow.triangle.branch"))
        }
        if c.isDual {
            // Replace the single-motor step(s) with the twin-motor installation.
            s.removeAll { $0.symbol == "fanblades" }
            s.append(BuildStep(title: "Mount both motors", text: "\(c.kind.isTailless ? "Glue the centre keel under the wing with its tabs. " : "")Glue a 3 × 0.5 mm carbon strip into the leading edge between the two MOTOR marks, then push the wing-clamp motor mounts onto the leading edge at ±\(Int(c.dualMotorX)) mm and glue. Fit the CW prop on the right and the CCW prop on the left so both blow the same way, and check the props clear the fuselage.", symbol: "fanblades"))
        }
        if !d.struts.isEmpty {
            let wing = d.struts.contains { $0.group == .wing }, tail = d.struts.contains { $0.group == .tail }, fin = d.struts.contains { $0.group == .fin }
            let parts = [wing ? "the wing to the fuselage" : nil, tail ? "the tail boom to the wing" : nil, fin ? "the fin to the stabiliser" : nil].compactMap { $0 }
            let what = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts.joined()
            s.append(BuildStep(title: "Fit the carbon struts", text: "The struts brace \(what). Glue the printed strut anchors onto the purple S-pads on the plans (boss pointing along the arrow; a mark on a fuselage half means both sides).\(d.struts.contains { $0.b.saddle != nil } ? " Where the plan shows a saddle, the left and right ends share one printed saddle: slide it over the bottom edge of the fuselage at the mark (bridge or foot under the edge, one boss each side) and glue it." : "") Cut each rod to the length in the materials list, push it into both bosses with the plane resting flat and square, then fix it with a drop of thin CA at each end. Move every control surface to full throw (±\(Int(c.kind.maxSurfaceThrow))°) both ways and check it clears every rod and anchor.", symbol: "line.3.crossed.swirl.circle"))
        }
        s.append(BuildStep(title: "Install servos & linkages", text: "Glue the printed servo frames into the cutouts, push the servos in and centre them with the transmitter. Glue the horns into the horn slots (hole row over the hinge line). Make pushrods from Ø1 mm carbon with Z-bent 0.8 mm wire ends.", symbol: "gearshape.2"))
        s.append(BuildStep(title: "Electronics", text: "Connect ESC and servos to the receiver, fix the receiver with double-sided tape, route wires flat and tape them down. Fix velcro for the \(c.battery.name).", symbol: "bolt"))
        s.append(BuildStep(title: "Balance (CG)", text: "Mark the CG \(cg) mm behind the root leading edge (marked ⊕ on the plan). Move the battery until the model balances level on your fingertips at that mark. Recommended range: \(String(format: "%.0f–%.0f", a.cgRange.lowerBound, a.cgRange.upperBound)) mm.", symbol: "scalemass"))
        s.append(BuildStep(title: "Set throws & first flight", text: c.kind.isTailless
            ? "Elevon throws: ±8 mm pitch, ±6 mm roll, 30 % expo. Trim elevons 1–2 mm up. Hand-launch firmly level at ~70 % throttle."
            : c.kind.isNutBall ? "Throws: elevator ±12 mm, rudder ±20 mm, 40 % expo – a NutBall needs big throws and flies very slowly. Hand-launch level at ~50 % throttle."
            : "Throws: elevator ±8 mm\(c.hasRudder ? ", rudder ±12 mm" : "")\(c.hasAilerons ? ", ailerons ±10 mm" : ""), 30 % expo. Hand-launch level at ~60 % throttle into the wind.", symbol: "paperplane"))
        return s
    }
}

import simd
