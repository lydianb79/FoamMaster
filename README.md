# FoamMaster

Native macOS app (SwiftUI + Metal) to design, check and build micro foam RC aircraft up to **600 mm span**.

## Build & run

```bash
./build_app.sh          # → build/FoamMaster.app
open build/FoamMaster.app
```

Requires Xcode / Swift 5.9+, macOS 14+. `swift run` also works for quick iteration.

## Features

- **Model gallery** – Flying Wing, Delta Jet, SkyKart, Park Trainer, 3D Profile, Micro Glider; then customise every dimension.
- **Metal 3D view** – orbit/pan/zoom, control-surface deflection preview, live CG marker with target range.
- **Materials** – Depron or EPP in 3 / 5 / 6 / 10 mm, optional carbon spar.
- **CG calculation** – mass build-up of every foam part and component, neutral point from wing + tail volume, recommended CG and auto-balance (battery position).
- **Feasibility checks** – geometry (self-intersection, cutouts that don't fit, prop strike, fuselage/tail overlap), wing loading, thrust/weight, motor/battery compatibility, CG reachability, tail volumes, wing stiffness, servo hinge moment.
- **Randomize** – generates random variants and keeps only feasible ones.
- **Plans** – 1:1 A4 PDF, oversize parts tiled across pages with registration crosses, page map and scale checks; servo cutouts, wing/tab slots, horn slots, alignment V-notches, hinge and spar lines, CG marks. Export or print directly.
- **Build instructions & BOM** – foam sheets, carbon spars/pushrods with lengths, hardware, electronics, printed parts.
- **STL export** – parametric motor mount (bolt pattern per motor, foam-thickness clamp), control horns, servo frames, dihedral joiner, battery tray.

## Self-test

```bash
.build/debug/FoamMaster --selftest /tmp/foammaster-selftest
```

Builds every model type, prints the analysis, writes PDFs, STLs and offscreen Metal/UI renders.
