import Foundation
import simd

/// Frame that maps a flat part's (u, v) plan coordinates into the 3D aircraft frame.
/// Aircraft frame: +X right wing, +Y up, +Z aft. Origin = root leading edge on the wing plane.
struct Placement {
    var origin: SIMD3<Double>
    var u: SIMD3<Double>
    var v: SIMD3<Double>

    var normal: SIMD3<Double> { simd_normalize(simd_cross(u, v)) }

    func point(_ p: Vec2, offset: Double = 0) -> SIMD3<Double> {
        origin + u * p.x + v * p.y + normal * offset
    }

    static func horizontal(at origin: SIMD3<Double>) -> Placement {
        Placement(origin: origin, u: [0, 0, 1], v: [1, 0, 0])
    }
    static func vertical(at origin: SIMD3<Double>) -> Placement {
        Placement(origin: origin, u: [0, 0, 1], v: [0, 1, 0])
    }
}

enum Feature {
    /// Hinge line: bevel 45° on the bottom, hinge with tape on top.
    case hinge(Vec2, Vec2)
    /// Through cut separating a control surface from the fixed part.
    case cut(Vec2, Vec2)
    /// Carbon groove for a boom / tube (centre line, width).
    case spar(Vec2, Vec2, Double)
    /// Wing spar: carbon rod (diameter) in a groove underneath, bottom flush with the underside.
    case rod(Vec2, Vec2, Double)
    /// Marker for the recommended centre of gravity.
    case cg(Vec2)
    /// Dashed outline for component placement (battery, receiver …).
    case zone([Vec2], String)
    case label(String, Vec2)
    /// Printed strut anchor: pad centre, rod direction on the plan, pad size (along × across), label (S1 …).
    case strutAnchor(Vec2, Vec2, Vec2, String)
    /// One-piece strut saddle: outline of its side plates on the web (from the bottom edge up), pair label (S1 …).
    case strutSaddle([Vec2], String)
    /// Joint pad of a double strut anchor (two rods side by side): outline and text.
    case strutPlate([Vec2], String)
}

enum HoleKind { case slot, servo, hornSlot, drill }

struct Hole {
    var kind: HoleKind
    var polygon: [Vec2]
    var note: String = ""
}

enum PartRole { case wing, fuselage, stabilizer, fin, winglet }

struct Region {
    var polygon: [Vec2]
    var isControl: Bool
}

struct Part: Identifiable {
    let id = UUID()
    var name: String
    var role: PartRole
    var outline: [Vec2]
    var holes: [Hole] = []
    var features: [Feature] = []
    /// Optional subdivision used to colour control surfaces in the 3D view.
    var regions: [Region] = []
    var instances: [Placement]
    var material: FoamMaterial
    var mirroredPair: Bool = false

    var quantity: Int { instances.count }
    var thickness: Double { material.thickness }

    var netArea: Double { Poly.area(outline) - holes.reduce(0) { $0 + Poly.area($1.polygon) } }

    /// grams
    var massEach: Double { netArea * 1e-6 * thickness * 1e-3 * material.density * 1000 }

    var centroid2D: Vec2 {
        let a = Poly.area(outline)
        var c = Poly.centroid(outline) * a
        var total = a
        for h in holes {
            let ha = Poly.area(h.polygon)
            c -= Poly.centroid(h.polygon) * ha
            total -= ha
        }
        return total > 0 ? c / total : Poly.centroid(outline)
    }

    var size: Vec2 { let b = Poly.bounds(outline); return b.max - b.min }
}

struct MassItem: Identifiable {
    let id = UUID()
    var name: String
    var mass: Double          // g
    var position: SIMD3<Double>
    var category: String
}

extension ControlSurface {
    var isDoubleArm: Bool { servoID.contains("double arm") }
    /// Output shaft at the servo case face (where the arm's hub sits), from the servo centre and the arm tip: on the
    /// side face for servos with the shaft sideways, on the bottom face for the standing (shaft-down) aileron servo.
    func shaft(_ s: ServoClass) -> SIMD3<Double> {
        guard armPosition != .zero else { return servoPosition }
        if isDoubleArm { return [servoPosition.x, servoPosition.y - s.size.h / 2, armPosition.z] }
        let side: Double = armPosition.x >= servoPosition.x ? 1 : -1
        return [servoPosition.x + side * s.size.h / 2, servoPosition.y, armPosition.z]
    }
}

struct ControlSurface {
    var name: String
    var hingeMid: SIMD3<Double>
    var hornPosition: SIMD3<Double>
    var servoPosition: SIMD3<Double>
    var area: Double
    var chord: Double = 20
    /// Controls sharing one servo (e.g. both ailerons on torque rods) carry the same id.
    var servoID: String = ""
    /// Tip of the servo arm (pushrod end at the servo) and the direction the horn sticks out of the surface.
    var armPosition: SIMD3<Double> = .zero
    var hornAxis: SIMD3<Double> = [0, 1, 0]
}

/// Complete derived design: parts plus the components that go into it.
extension Design {
    /// Overall length of the airframe (mm): nose to the aft-most foam edge (rudder / elevator), plus the
    /// propeller where it sticks out ahead of the nose or behind the tail.
    var overallLength: Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for part in parts {
            for inst in part.instances {
                for p in part.outline { let z = inst.point(p).z; lo = min(lo, z); hi = max(hi, z) }
            }
        }
        let prop = config.propPlaneZ
        return max(hi, prop) - min(lo, prop)
    }
}

struct Design {
    var config: AircraftConfig
    var parts: [Part]
    var components: [MassItem]
    var controls: [ControlSurface]
    var servoCutouts: [(part: String, rect: [Vec2])]
    var geometryIssues: [String]
    /// Carbon truss strip length (mm, both sides) for the BOM.
    var trussLength: Double = 0
    /// Carbon stabilisation struts (rods between wing and fuselage webs).
    var struts: [Strut] = []
    /// Why planned struts were left out (shown in the checks).
    var strutNotes: [String] = []
}
