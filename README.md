# FoamMaster

Native macOS app (SwiftUI + Metal) to design, check and build micro foam RC aircraft up to **600 mm span**.

## Build & run

```bash
./build_app.sh          # → build/FoamMaster.app
open build/FoamMaster.app
```

Requires Xcode / Swift 5.9+, macOS 14+. `swift run` also works for quick iteration.

## Features

- **Model gallery** – live 3D renders of Flying Wing, Delta Jet, Twin Boom, Sport Jet (swept wing, prop spinning in a slot through the wing centre), Park Trainer, 3D Plane, Micro Glider and NutBall. Picking one opens a setup sheet for control layout, fins/winglets, motors and aileron servos; then customise every dimension.
- **Multi-layer construction** (in the style of commercial flat-foam kits) – conventional aircraft get a full-length horizontal fuselage plate with the stabiliser built in, upper and lower fuselage halves glued on with tabs (a + section along the whole length), wing halves keyed into the plate sides, carbon spars on top and bottom, no carbon in the fuselage. Flying wings get a centre keel and the motor sits in a trailing-edge cutout; the twin boom pusher has a pod built the same way.
- **NutBall** – round (elliptic) flat disc wing with a nose tongue, elevator across the trailing edge (split by a V-cut for the rudder), spine with centre fin + rudder on top and a keel below – the + section carries the motor mount. Width, length, elevator depth, motor offset, spine height and fin size are adjustable; area, MAC and neutral point use the elliptic planform.
- **Dual tractor** – optional on every type except the Sport Jet and the NutBall: two counter-rotating motors on the wing leading edge with wing-clamp mounts, as far inboard as the prop clearance allows; thrust, weight, CG, BOM (Y-lead, 2 ESCs, CW/CCW props, LE carbon strip) and build steps follow.
- **Winglets** – on every type: side-mounted at the wing tips (tip tabs into winglet slots); tailless types alternatively a centre fin with adjustable position, or no fins at all.
- **Control-surface clearance** – 1.5 mm slots at both ends of every aileron/elevon; the elevator is one piece on a straight hinge across the whole tail (one servo moves all of it) and runs under the rudder, whose lower edge is cut back for 35° of up-elevator; hinge and side gaps visible in 3D.
- **Control layouts** – tailed planes: ailerons + elevator, or ailerons + elevator + rudder (flat wings need ailerons); NutBall: always rudder + elevator.
- **Component layout** – ESC (green) and receiver (cyan) sit on the visible side where the leads reach. The colour legend in the 3D view lists every colour with an explanation on hover, and hovering the model names the part under the mouse (foam part, control surface, motor, prop, mount with its bolt pattern, servo, ESC, receiver, battery, horn, carbon, CG). All models are for line-of-sight flying (no FPV gear).
- **Linkages** – servos lie flat in the wing (only their width crosses the foam) and pass through the vertical fuselage halves, always with the shaft sideways; arm, straight pushrod and horn (holes above the hinge line) are placed so elevator and rudder pushrods never cross, and are drawn in 3D.
- **Propeller** – recommended diameter × pitch and blade count (2-blade where diameter is free, 3-blade where it is limited by a prop slot / cutout or for 3D), drawn as a real twisted prop.
- **Control layout** – chosen in the setup sheet: rudder + elevator, ailerons + elevator, or all four; ailerons on one central servo (torque rods) or one per side. The app shows how many surfaces and servos result and which servo drives what (joined elevator halves, linked twin rudders).
- **Metal 3D view** – orbit/pan/zoom, control-surface deflection preview, live CG marker with target range. Printed parts (motor mount, servo frames, battery tray) are drawn from the same meshes as the STL export, the motor as stator, bell and shaft, and ESCs and the receiver are shown in place (outside the foam) with their leads.
- **Materials** – Depron or EPP in 3 / 5 / 6 / 10 mm, optional carbon spar.
- **CG calculation** – mass build-up of every foam part and component, neutral point from wing + tail volume, recommended CG, auto-balance (battery position) and “fix with bigger battery” when the battery can't reach the CG.
- **Structure physics** – beam models for wing bending (3 g), fuselage twist under full rudder and tail bending under full elevator, using foam and carbon moduli. One fuselage construction, the RC Factory style cross: horizontal plate (≈ 8.5 % of span, 14 % on the Sport Jet) with upper and lower halves – foam only; carbon is used for the wing spar (top + bottom). All wings are flat – no dihedral joints, which are hard to make stiff in foam.
- **Why not feasible?** – every error is explained and a background search proposes the smallest parameter changes (single or combined) that make the design work, each with an Apply button.
- **Feasibility checks** – geometry (self-intersection, cutouts that don't fit, prop strike, fuselage/tail overlap), wing loading, thrust/weight, motor/battery compatibility, CG reachability, tail volumes, wing stiffness, servo hinge moment.
- **Randomize** – generates random variants and keeps only feasible ones.
- **Plans** – 1:1 A4 PDF with optimised part placement (skyline packing, both orientations, fewest pages and page splits), oversize parts tiled across pages with registration crosses, page map and scale checks; servo cutouts, wing/tab slots, horn slots, alignment V-notches, hinge and spar lines, CG marks. Export or print directly.
- **Build instructions & BOM** – foam sheets, carbon spars/pushrods with lengths, hardware, electronics, printed parts.
- **STL export** – clamp-type motor mounts with the real hole pattern of the selected motor (0802 3 × M1.4 on Ø6.6, 1103 4 × M1.6 8.5 × 8.5, 1104 4 × M2 9 × 9, 1306 4 × M2 12 × 12, 1806 4 × M2 12 × 16, 2204 4 × M3 16 × 19 – typical values, check your motor), counterbored so the screw heads sit flush and with access bores through any jaw that covers a screw; jaws sized to the foam thickness, M2 clamp bolts (square channels), grip lips; + channel for fuselages, solid top jaw with keel slot for tailless wings, wing clamp for dual tractors – shown in the 3D view), control horns, servo frames, dihedral joiner and battery tray.

## Self-test

```bash
.build/debug/FoamMaster --selftest /tmp/foammaster-selftest
```

Builds every model type, prints the analysis, writes PDFs, STLs and offscreen Metal/UI renders.
