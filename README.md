# FoamMaster

Native macOS app (SwiftUI + Metal) to design, check and build micro flat foam planes and wings up to **800 mm wingspan**.

Created by TriX aka Rock FPV – [YouTube](https://www.youtube.com/@RockFPV) · [GitHub](https://github.com/lydianb79/FoamMaster)

## Download

Get `FoamMaster-<version>-macOS.zip` from the [Releases](https://github.com/lydianb79/FoamMaster/releases) page, unzip it and move `FoamMaster.app` to *Applications*. Requires macOS 14 or newer (Apple silicon).

The app is not notarized: on the first start right-click it and choose **Open** (or allow it under *System Settings ▸ Privacy & Security*).

## Build & run

```bash
./build_app.sh          # → build/FoamMaster.app
open build/FoamMaster.app
```

Requires Xcode / Swift 5.9+, macOS 14+. `swift run` also works for quick iteration.

A credits splash with the Rock FPV logo (`Assets/RockFPV_logo.png`, copied into the app by `build_app.sh`), the YouTube and GitHub links appears at start-up; a click closes it (FoamMaster ▸ About shows it again).

## Features

- **Model gallery** – shows the recommended variant of each type (default airframe with the automatically chosen motor, ESC, prop and battery, balanced) with its total ready-to-fly weight split into airframe / electronics / battery, the power system, T/W and flight time; live 3D renders (model centred in the card) of Flying Wing, Delta Jet, Twin Boom, Sport Jet (swept wing, prop spinning in a slot through the wing centre), Park Trainer, 3D Plane, Micro Glider and NutBall. Picking one opens a setup sheet for control layout, fins/winglets, motors and aileron servos; then customise every dimension.
- **Multi-layer construction** (in the style of commercial flat-foam kits) – conventional aircraft get a full-length horizontal fuselage plate with the stabiliser built in, upper and lower fuselage halves glued on with tabs (a + section along the whole length), wing halves keyed into the plate sides, one solid carbon rod spar per wing in a groove underneath (sized for the wing: the thinnest of Ø1.5–5 mm that keeps the 3 g tip deflection below 3 %, never thicker than the foam allows), no carbon in the fuselage. Flying wings get a centre keel and the motor sits in a trailing-edge cutout; the twin boom pusher has a pod built the same way.
- **NutBall** – round (elliptic) flat disc wing with a nose tongue, one-piece elevator across the trailing edge (the rudder's lower edge is cut back so it can move underneath), spine with centre fin + rudder on top and a keel below – the + section carries the motor mount. Width, length, elevator depth, motor offset, spine height and fin size are adjustable; area, MAC and neutral point use the elliptic planform.
- **Dual tractor** – optional on every type except the Sport Jet and the NutBall: two counter-rotating motors on the wing leading edge with wing-clamp mounts, as far inboard as the prop clearance allows; thrust, weight, CG, BOM (Y-lead, 2 ESCs, CW/CCW props, LE carbon strip) and build steps follow.
- **Winglets** – on every type: side-mounted at the wing tips (tip tabs into winglet slots); tailless types alternatively a centre fin with adjustable position, or no fins at all.
- **Control-surface clearance** – 1.5 mm slots at both ends of every aileron/elevon; the elevator is one piece on a straight hinge across the whole tail (one servo moves all of it) and runs under the rudder, whose lower edge is cut back for 35° of up-elevator; hinge and side gaps visible in 3D.
- **Rounded edges** – planes with a tail: adjustable radius for the wing tips (leading- and trailing-edge corners; the ailerons end inboard of the rounding), the fin / rudder top corners and the elevator's trailing-edge tips – applied to the plans, the cut parts and the 3D view.
- **Fuselage cross width** – the horizontal fuselage plate can be made wider than the default (never narrower, which would cost torsional stiffness).
- **Themes** – Theme menu with Midnight (default), Ocean, Sunset, Forest and Graphite.
- **Info splash** – credits with the Rock FPV logo and the YouTube / GitHub links at start-up.
- **Control layouts** – Twin Boom: ailerons + elevator with fixed twin fins (no rudder); other tailed planes: ailerons + elevator, or ailerons + elevator + rudder (flat wings need ailerons); NutBall: always rudder + elevator. Receiver channels are counted as servos + throttle, and Controls & Servos lists the throttle and the AETR channel assignment. One aileron servo (trainer, 3D plane, glider): as on the RC Factory cartoon planes, the servo hangs upside down in the lower fuselage half under the wing, 5 mm ahead of the spar rod (behind it only when there is no room under the wing root; the battery always stays ahead of it), with a double-ended arm and one short pushrod to a horn under each aileron; a notch in the lower half gives the servo and arm room. The editor lists the full electronics (as under Materials) and the weight breakdown names the actual parts.
- **Nose protector** – dual-tractor layouts get a printed nose protector (STL): a + channel cap (flat + front, U-channels for the plate and both fuselage halves, sized to the foam thickness) on fuselage noses, a glue-on apex guard on flying wings / deltas.
- **Auto power system** – whenever the airframe changes (dimensions, material, foam thickness, layout …) motor, ESC, prop size/pitch/blades and battery are re-picked for the best power-to-weight ratio: the lightest feasible combination with at least 1.4 × the minimum thrust/weight of the type and ≥ 6 min flight time. Picking a motor or battery by hand switches it off. Dual tractors keep at least the single-motor version's motor and battery (two motors of that size, same or bigger pack), so switching to dual always adds the second motor, ESC and mounts to the weight.
- **Component layout** – ESC (green) and receiver (cyan) sit on the visible side where the leads reach (dual-tractor ESCs on the wing behind their motor, aft of the spar). The colour legend in the 3D view lists every colour with an explanation on hover, and hovering the model names the part under the mouse (foam part, control surface, motor, prop, mount with its bolt pattern, servo, ESC, receiver, battery, horn, carbon, CG). All models are for line-of-sight flying (no FPV gear).
- **Linkages** – servos lie flat in the wing (only their width crosses the foam; aileron / elevon servos and the Twin Boom elevator servo sit as far forward as possible – front edge 5 mm behind the spar groove – which moves the CG forward and lets the battery sit further aft) and pass through the vertical fuselage halves with the shaft sideways (the single aileron servo hangs upside down, shaft down); arm, straight pushrod and horn (pushrod hole exactly above the hinge line) are placed so elevator and rudder pushrods never cross, and are drawn in 3D. Pushrods are checked against the spinning prop like the foam: the Twin Boom's elevator servo lies flat in the right wing in one row with the aileron servos, so its pushrod runs beside the boom, and the Sport Jet's elevator and rudder servos sit behind the prop window.
- **Propeller** – recommended diameter × pitch and blade count (2-blade where diameter is free, 3-blade where it is limited by a prop slot / cutout or for 3D), drawn as a real twisted prop. Props keep 5 mm clearance to all foam – a geometric check samples every foam part around the spinning prop (tips, blade faces, spinner) and reports the closest part; dual tractors on swept wings get a printed motor standoff so the inboard blades clear the leading edge; the printed firewall always sits against the end of the foam. The Sport Jet uses a 4" 3-blade that spins in a window through the wing and the one-piece upper and lower fuselage halves, with an 8 mm foam frame above and below; the fuselage height can never be set lower than prop + clearance + frame.
- **Metal 3D view** – orbit/pan/zoom, control-surface deflection preview, live CG marker with target range, hover names. The carbon rod spar is shown in its groove under the wing and as a line of the same width on top (on both wing halves). Printed parts (motor mount, control horns, servo frames, battery tray, nose protector) are drawn from the same meshes as the STL export, the motor as stator, bell and shaft, and ESCs and the receiver are shown in place (outside the foam) with their leads.
- **Materials** – Depron or EPP in 3 / 5 / 6 / 10 mm, optional carbon rod spar.
- **CG calculation** – mass build-up of every foam part and component, neutral point from wing + tail volume, recommended CG, auto-balance (battery position) and “fix with bigger battery” when the battery can't reach the CG.
- **Structure physics** – beam models for wing bending (3 g, foam + carbon rod as a composite section), fuselage twist under full rudder (or a side gust without rudder) and tail bending under full elevator, using foam and carbon moduli. One fuselage construction, the RC Factory style cross: horizontal plate (≈ 8.5 % of span, 14 % on the Sport Jet) with upper and lower halves – foam only; carbon is used for the wing spar (one solid rod in a groove underneath). All wings are flat – no dihedral joints, which are hard to make stiff in foam.
- **Why not feasible?** – every error is explained and a background search proposes the smallest parameter changes (single or combined) that make the design work, each with an Apply button.
- **Feasibility checks** – geometry (self-intersection, cutouts that don't fit, prop strike, fuselage/tail overlap), wing loading, thrust/weight, motor/battery compatibility, CG reachability, tail volumes, wing stiffness, servo hinge moment.
- **Randomize** – generates random variants and keeps only feasible ones.
- **Plans** – 1:1 A4 PDF with optimised part placement (skyline packing, both orientations, fewest pages and page splits), oversize parts tiled across pages with registration crosses, page map and scale checks; servo cutouts, wing/tab slots, horn slots with the horn position (flange outline, pushrod hole on the hinge line), alignment V-notches, hinge lines, the carbon rod spar as a band with its size, CG marks. Export or print directly.
- **Build instructions & BOM** – foam sheets, carbon rod spar and pushrods with lengths, hardware (motor screws per mount pattern), electronics with receiver channels, printed parts.
- **STL export** – clamp-type motor mounts with the real hole pattern of the selected motor (0802 3 × M1.4 on Ø6.6, 1103 4 × M1.6 8.5 × 8.5, 1104 4 × M2 9 × 9, 1306 4 × M2 12 × 12, 1806 4 × M2 12 × 16, 2204 4 × M3 16 × 19 – typical values, check your motor), counterbored so the screw heads sit flush and with access bores through any jaw that covers a screw; jaws sized to the foam thickness, M2 clamp bolts (square channels), grip lips; + channel for fuselages, solid top jaw with keel slot for tailless wings, wing clamp for dual tractors (with a standoff on swept wings) – shown in the 3D view), nose protector for dual tractors, control horns (base flange, tab sized to the foam thickness, triangular plate with the pushrod hole exactly above the hinge line; nothing touches the fixed surface), servo frames and battery tray – each matched to the selected foam thickness.

## Self-test

```bash
.build/debug/FoamMaster --selftest /tmp/foammaster-selftest
```

Builds every model type, prints the analysis, writes PDFs, STLs and offscreen Metal/UI renders.
