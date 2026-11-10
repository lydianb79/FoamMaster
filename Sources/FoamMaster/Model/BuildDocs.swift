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
            let pieces = (!c.kind.isTailless && c.dihedral >= 0.5) ? 2 : (c.sweep > 15 && c.kind.isTailless ? 2 : 1)
            let len = ceil(c.sparLength / Double(pieces) / 10) * 10
            items.append(BOMItem(category: "Carbon", item: spar.name, spec: "\(Int(len)) mm per piece, glued flush into a slit along the 30 % chord line", quantity: "\(pieces)×"))
        }
        let pushLen = d.controls.reduce(0) { $0 + simd_distance($1.servoPosition, $1.hornPosition) }
        items.append(BOMItem(category: "Carbon", item: "Carbon rod Ø1 mm (pushrods)", spec: "Total \(Int(ceil(pushLen / 10) * 10 + 40)) mm", quantity: "\(d.controls.count)×"))
        items.append(BOMItem(category: "Hardware", item: "Steel wire Ø0.8 mm", spec: "Z-bend ends, 2 × 35 mm per pushrod + heat-shrink", quantity: "\(d.controls.count * 2)×"))
        let servoCount = Set(d.controls.map(\.servoID)).count
        if c.kind.isTwinBoom {
            let len = c.tailArm + c.hStabChord * 0.55 - c.rootChord * 0.15
            items.append(BOMItem(category: "Carbon", item: CarbonSpar.tube4.name, spec: "Tail booms, \(Int(ceil(len / 10) * 10)) mm each, glued into grooves under wing and stabiliser", quantity: "2×"))
            items.append(BOMItem(category: "Carbon", item: "Carbon rod Ø1 mm", spec: "Elevator joiner (40 mm) + rudder link wire across the stab", quantity: "1×"))
        }
        if c.kind.hasAilerons && c.aileronServos == 1 {
            items.append(BOMItem(category: "Hardware", item: "Steel wire Ø1 mm torque rods", spec: "2 × 70 mm, L-bent into the aileron leading edges, brass tube bearings 2 × 15 mm", quantity: "2×"))
        }
        if c.kind.hasFuselage {
            items.append(BOMItem(category: "Carbon", item: "Carbon flat strip 3 × 0.5 mm", spec: "Fuselage boom stiffener, \(Int(c.tailArm + c.hStabChord)) mm, glued along the bottom edge", quantity: "1×"))
        }
        let hingeLen = d.parts.reduce(0.0) { sum, p in
            sum + p.features.reduce(0.0) { s2, f in if case let .hinge(a, b) = f { return s2 + simd_distance(a, b) * Double(p.quantity) }; return s2 }
        }
        items.append(BOMItem(category: "Hardware", item: "Hinge tape (Blenderm / clear tape)", spec: "\(Int(ceil(hingeLen * 1.1 / 10) * 10)) mm", quantity: "1 roll"))
        items.append(BOMItem(category: "Hardware", item: "Glue", spec: c.material.glue, quantity: "1"))
        items.append(BOMItem(category: "Hardware", item: "Velcro strip", spec: "15 × 40 mm for the battery", quantity: "1"))
        items.append(BOMItem(category: "Hardware", item: "Motor screws \(c.motor.screw)", spec: "Length 4–6 mm", quantity: "4×"))

        items.append(BOMItem(category: "Electronics", item: c.motor.name, spec: "\(c.motor.allowedCells.lowerBound)–\(c.motor.allowedCells.upperBound)S, ~\(Int(a.thrust)) g thrust", quantity: "1×"))
        items.append(BOMItem(category: "Electronics", item: "ESC", spec: "\(c.motor.escMass > 4 ? 12 : 6) A, \(c.battery.cells)S", quantity: "1×"))
        items.append(BOMItem(category: "Electronics", item: "Propeller \(String(format: "%.1f", c.motor.propInches))\"", spec: c.kind.isPusher ? "Pusher (reverse) prop" : "Tractor prop", quantity: "2× (spare)"))
        items.append(BOMItem(category: "Electronics", item: c.battery.name, spec: "\(c.battery.mass) g", quantity: "1×"))
        items.append(BOMItem(category: "Electronics", item: c.servo.name, spec: "\(c.servo.torque) kg·cm", quantity: "\(servoCount)×"))
        items.append(BOMItem(category: "Electronics", item: "Receiver", spec: "\(max(4, servoCount + 1))+ channels, micro", quantity: "1×"))
        if c.kind.hasAilerons && c.aileronServos == 2 { items.append(BOMItem(category: "Electronics", item: "Servo extension", spec: "100 mm (aileron servos)", quantity: "2×")) }
        if c.fpv != .none {
            items.append(BOMItem(category: "FPV", item: c.fpv.name, spec: "\(c.fpv.detail) · ≈\(String(format: "%.1f", c.fpv.mass)) g · ≈\(String(format: "%.1f", c.fpv.power)) W", quantity: "1×"))
            items.append(BOMItem(category: "FPV", item: "Antenna", spec: c.fpv == .analog ? "5.8 GHz dipole, mounted vertically" : "Stock antenna, route away from carbon parts", quantity: "1×"))
            items.append(BOMItem(category: "FPV", item: "Power lead", spec: "Solder to the ESC balance/main lead (\(c.battery.cells)S)", quantity: "1×"))
        }

        for p in PrintedParts.generate(d) {
            items.append(BOMItem(category: "3D printed", item: p.name, spec: "PETG/PLA, \(String(format: "%.1f", p.mass)) g, \(p.note)", quantity: "\(p.quantity)×"))
        }
        return items
    }

    static func steps(_ d: Design, _ a: Analysis) -> [BuildStep] {
        let c = d.config
        let cg = String(format: "%.0f", a.recommendedCG)
        var s: [BuildStep] = [
            BuildStep(title: "Print & assemble the plans", text: "Print the plan at 100 % (no scaling). Verify the 100 mm scale bar on the cover. Trim the tiles along the frame lines, align them with the registration crosses and tape them together.", symbol: "printer"),
            BuildStep(title: "Transfer & cut the foam", text: "Pin the plans onto the \(c.material.displayName) sheet and cut with a fresh snap-off blade along a metal ruler. Cut all slots, servo cutouts and horn slots (filled shapes) completely through. V-notches mark alignment points – cut them too.", symbol: "scissors"),
            BuildStep(title: "Prepare control surfaces", text: "Cut free each surface along the solid side cuts. On the dashed hinge line bevel the lower edge 45°, then hinge with tape on the top side. Check for at least ±30° deflection.", symbol: "rectangle.split.2x1")
        ]
        if c.sparEnabled {
            s.append(BuildStep(title: "Install the carbon spar", text: "Cut a slit along the green spar line about \(String(format: "%.1f", c.material.thickness * 0.6)) mm deep, fill with glue and press in the \(c.sparSpec.name). Wipe off excess glue and let cure flat.", symbol: "line.diagonal"))
        }
        if c.kind.hasFuselage && c.fuselageType != .profile {
            s.append(BuildStep(title: c.fuselageType == .cross ? "Glue the cross plates" : "Glue the X-brace strips",
                               text: c.fuselageType == .cross
                ? "Glue the front and rear cross plates flat against both fuselage sides along the marked centre line (notch = alignment mark). Use a square to keep them at 90° – together with the wing they form a stiff + section."
                : "Glue the four front and four rear strips at 45° along the marked centre line on both sides (one up, one down per side). Check the X is symmetric from the front before the glue sets.", symbol: c.fuselageType.symbol))
        }
        if c.kind.isTwinBoom {
            s.append(BuildStep(title: "Pod, booms & twin fins", text: "Slide the wing through the pod slot. Groove the wing and stabiliser undersides along the boom lines, glue in both Ø4 mm carbon booms parallel to the pod. Push the fin tabs through the stabiliser slots. Join the elevator halves with a 1 mm carbon rod and link both rudders with a wire across the stab.", symbol: "rectangle.split.3x1"))
            s.append(BuildStep(title: "Mount the pusher motor", text: "Slide the printed mount over the pod tail and glue. Prop clearance to the booms is checked by FoamMaster – verify it turns freely.", symbol: "fanblades"))
        } else if c.kind.isTailless {
            s.append(BuildStep(title: c.kind == .delta ? "Fit the centre fin" : "Fit the winglets", text: "Push the tabs through the matching slots in the wing until flush underneath. Check 90° to the wing with a square and glue.", symbol: "square.split.bottomrightquarter"))
            s.append(BuildStep(title: "Mount the motor", text: "Screw the motor onto the printed mount (\(c.motor.screw)). Slide the mount clamp over the trailing edge at the centre notch and glue. Motor axis parallel to the wing chord.", symbol: "fanblades"))
        } else {
            s.append(BuildStep(title: "Join the fuselage and wing", text: c.dihedral >= 0.5
                ? "Glue the printed dihedral joiner into the wing slot. Insert both wing halves (root notches face the fuselage) and set \(String(format: "%.0f", c.dihedral))° dihedral – the joiner sets the angle."
                : "Slide the wing through the fuselage slot until the LE/TE notches line up with the fuselage. Check the wing is square to the fuselage, then glue.", symbol: "airplane"))
            s.append(BuildStep(title: "Fit the stabiliser", text: "Press the stabiliser slots over the tabs under the tail boom. Check it is parallel to the wing when viewed from the front, then glue. Glue the 3 × 0.5 mm carbon strip along the fuselage bottom edge.", symbol: "arrow.left.and.right"))
            s.append(BuildStep(title: "Mount the motor", text: "Screw the motor onto the printed firewall (\(c.motor.screw)), slide its clamp over the nose and glue. 1–2° right thrust can be shimmed with a washer.", symbol: "fanblades"))
        }
        if c.kind.hasAilerons && c.aileronServos == 1 {
            s.append(BuildStep(title: "Aileron torque rods", text: "Bend two 1 mm wires into L-shapes, slide them through short brass tubes glued into the wing at the hinge line next to the fuselage and press the long legs into the aileron leading edges. The single aileron servo below the wing drives both rods with one pushrod each.", symbol: "arrow.triangle.branch"))
        }
        if c.fpv != .none {
            s.append(BuildStep(title: "Install the FPV system", text: "Mount the \(c.fpv.name) camera in the printed camera mount at the marked nose position (≈15° up-tilt). Fix the transmitter with double-sided tape, keep the antenna clear of carbon and the prop, and power it from the flight pack.", symbol: "video"))
        }
        s.append(BuildStep(title: "Install servos & linkages", text: "Glue the printed servo frames into the cutouts, push the servos in and centre them with the transmitter. Glue the horns into the horn slots (hole row over the hinge line). Make pushrods from Ø1 mm carbon with Z-bent 0.8 mm wire ends.", symbol: "gearshape.2"))
        s.append(BuildStep(title: "Electronics", text: "Connect ESC and servos to the receiver, fix the receiver with double-sided tape, route wires flat and tape them down. Fix velcro for the \(c.battery.name).", symbol: "bolt"))
        s.append(BuildStep(title: "Balance (CG)", text: "Mark the CG \(cg) mm behind the root leading edge (marked ⊕ on the plan). Move the battery until the model balances level on your fingertips at that mark. Recommended range: \(String(format: "%.0f–%.0f", a.cgRange.lowerBound, a.cgRange.upperBound)) mm.", symbol: "scalemass"))
        s.append(BuildStep(title: "Set throws & first flight", text: c.kind.isTailless
            ? "Elevon throws: ±8 mm pitch, ±6 mm roll, 30 % expo. Trim elevons 1–2 mm up. Hand-launch firmly level at ~70 % throttle."
            : "Throws: elevator ±8 mm, rudder ±12 mm\(c.kind.hasAilerons ? ", ailerons ±10 mm" : ""), 30 % expo. Hand-launch level at ~60 % throttle into the wind.", symbol: "paperplane"))
        return s
    }
}

import simd
