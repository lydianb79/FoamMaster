# FoamMaster

Native macOS app (SwiftUI + Metal) to design, check and build micro foam RC aircraft up to **600 mm span**.

## Build & run

```bash
./build_app.sh          # → build/FoamMaster.app
open build/FoamMaster.app
```

Requires Xcode / Swift 5.9+, macOS 14+. `swift run` also works for quick iteration.

## Features

- **Model gallery** – live 3D renders of Flying Wing, Delta Jet, Twin Boom, Sport Jet (swept wing, prop spinning in a slot through the wing centre), Park Trainer, 3D Plane and Micro Glider. Picking one opens a setup sheet for FPV system, fuselage structure and aileron servos; then customise every dimension.
- **FPV** – none, Analog, DJI O4 Lite or Walksnail; weight, CG position, power draw (flight time), BOM and a printed camera mount are included.
- **Multi-layer construction** (in the style of commercial flat-foam kits) – conventional aircraft get a full-length horizontal fuselage plate with the stabiliser built in, upper and lower fuselage halves glued on with tabs (a + section along the whole length), wing halves keyed into the plate sides, carbon spars on top and bottom, a carbon zig-zag truss on both fuselage sides and optional doubler layers. Flying wings get a centre keel and the motor sits in a trailing-edge cutout; the twin boom pusher has a pod built the same way.
- **Dual tractor** – optional on every type except the Sport Jet: two counter-rotating motors on the wing leading edge with wing-clamp mounts, as far inboard as the prop clearance allows and outside a 150° FPV camera view; thrust, weight, CG, BOM (Y-lead, 2 ESCs, CW/CCW props, LE carbon strip) and build steps follow.
- **Winglets** – on every type: side-mounted at the wing tips (tip tabs into winglet slots); tailless types alternatively a centre fin with adjustable position, or no fins at all.
- **AIO flight controller** – optional FC + receiver + ESC board on a 26 × 26 mm pattern: removes the separate ESC(s) and receiver, checks current and cell rating, adds a printed 26 × 26 mm standoff mount.
- **Linkages** – servos lie flat in the wing (only their width crosses the foam) and pass through the vertical fuselage halves, always with the shaft sideways; arm, straight pushrod and horn (holes above the hinge line) are placed so elevator and rudder pushrods never cross, and are drawn in 3D.
- **Propeller** – recommended diameter × pitch and blade count (2-blade where diameter is free, 3-blade where it is limited by a prop slot / cutout or for 3D), drawn as a real twisted prop.
- **Control layout** – chosen in the setup sheet: rudder + elevator, ailerons + elevator, or all four; ailerons on one central servo (torque rods) or one per side. The app shows how many surfaces and servos result and which servo drives what (joined elevator halves, linked twin rudders).
- **Metal 3D view** – orbit/pan/zoom, control-surface deflection preview, live CG marker with target range.
- **Materials** – Depron or EPP in 3 / 5 / 6 / 10 mm, optional carbon spar.
- **CG calculation** – mass build-up of every foam part and component, neutral point from wing + tail volume, recommended CG, auto-balance (battery position) and “fix with bigger battery” when the battery can't reach the CG.
- **Structure physics** – beam models for wing bending (3 g), fuselage twist under full rudder and tail bending under full elevator, using foam and carbon moduli. One fuselage construction, the RC Factory style cross: horizontal plate (≈ 8.5 % of span, 14 % on the Sport Jet) with upper and lower halves and a carbon Warren truss (chords + diagonals) on both faces – the truss is modelled as a sandwich cell for torsion. All wings are flat – no dihedral joints, which are hard to make stiff in foam.
- **Why not feasible?** – every error is explained and a background search proposes the smallest parameter changes (single or combined) that make the design work, each with an Apply button.
- **Feasibility checks** – geometry (self-intersection, cutouts that don't fit, prop strike, fuselage/tail overlap), wing loading, thrust/weight, motor/battery compatibility, CG reachability, tail volumes, wing stiffness, servo hinge moment.
- **Randomize** – generates random variants and keeps only feasible ones.
- **Plans** – 1:1 A4 PDF with optimised part placement (skyline packing, both orientations, fewest pages and page splits), oversize parts tiled across pages with registration crosses, page map and scale checks; servo cutouts, wing/tab slots, horn slots, alignment V-notches, hinge and spar lines, CG marks. Export or print directly.
- **Build instructions & BOM** – foam sheets, carbon spars/pushrods with lengths, hardware, electronics, printed parts.
- **STL export** – clamp-type motor mounts (bolt pattern per motor, jaws sized to the foam thickness, M2 clamp bolt, grip lips; + channel for fuselages, wing clamp for dual tractors – shown in the 3D view), control horns, servo frames, dihedral joiner, battery tray, FPV camera mount (saddle for the fuselage edge or flat wing base, up-tilt per aircraft type), VTX tray and antenna holder.

## Self-test

```bash
.build/debug/FoamMaster --selftest /tmp/foammaster-selftest
```

Builds every model type, prints the analysis, writes PDFs, STLs and offscreen Metal/UI renders.
