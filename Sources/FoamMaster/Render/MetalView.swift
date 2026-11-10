import SwiftUI
import MetalKit

/// MTKView with orbit (drag), zoom (scroll / pinch) and double-click reset.
final class OrbitMTKView: MTKView {
    weak var renderer: Renderer?
    /// Called with the name of the object under the mouse (nil when there is none) and the mouse position
    /// (points, origin top-left).
    var onHover: ((String?, CGPoint) -> Void)?
    private var tracking: NSTrackingArea?
    private var lastPick = CACurrentMediaTime()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseMoved(with e: NSEvent) {
        guard let onHover, let r = renderer else { return }
        let now = CACurrentMediaTime()
        guard now - lastPick > 0.03 else { return }
        lastPick = now
        let p = convert(e.locationInWindow, from: nil)
        let top = CGPoint(x: p.x, y: bounds.height - p.y)
        onHover(r.pick(top, in: bounds.size), top)
    }
    override func mouseExited(with e: NSEvent) { onHover?(nil, .zero) }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func mouseDragged(with e: NSEvent) {
        onHover?(nil, .zero)
        guard let r = renderer else { return }
        r.yaw -= Float(e.deltaX) * 0.008
        r.pitch = min(1.5, max(-1.5, r.pitch + Float(e.deltaY) * 0.008))
    }
    override func rightMouseDragged(with e: NSEvent) { pan(e) }
    override func otherMouseDragged(with e: NSEvent) { pan(e) }

    private func pan(_ e: NSEvent) {
        guard let r = renderer else { return }
        let right = SIMD3<Float>(cos(r.yaw), 0, -sin(r.yaw))
        let k = r.radius * r.zoom * 0.004
        r.target += right * Float(-e.deltaX) * k + SIMD3<Float>(0, Float(e.deltaY), 0) * k
    }

    override func scrollWheel(with e: NSEvent) {
        guard let r = renderer else { return }
        r.zoom = min(4, max(0.25, r.zoom * (1 + Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.05))))
    }
    override func magnify(with e: NSEvent) {
        guard let r = renderer else { return }
        r.zoom = min(4, max(0.25, r.zoom * (1 - Float(e.magnification))))
    }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, let r = renderer { r.yaw = 0.75; r.pitch = 0.45; r.zoom = 1 }
    }
}

struct MetalView: NSViewRepresentable {
    var scene: SceneData
    var sceneID: Int
    var resetKey: String
    var autoRotate: Bool = false
    var onHover: ((String?, CGPoint) -> Void)? = nil

    final class Coordinator {
        var renderer: Renderer?
        var lastID = -1
        var lastReset = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OrbitMTKView {
        let v = OrbitMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.wantsLayer = true
        let r = Renderer(view: v)
        v.delegate = r
        v.renderer = r
        context.coordinator.renderer = r
        return v
    }

    func updateNSView(_ v: OrbitMTKView, context: Context) {
        let c = context.coordinator
        v.onHover = onHover
        c.renderer?.autoRotate = autoRotate
        if c.lastID != sceneID {
            let reset = c.lastReset != resetKey
            c.renderer?.setScene(scene, resetCamera: reset)
            c.lastID = sceneID
            c.lastReset = resetKey
        }
    }
}
