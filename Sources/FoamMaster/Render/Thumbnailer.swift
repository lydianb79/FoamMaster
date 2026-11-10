import AppKit
import MetalKit

/// Offscreen Metal renders of designs for the gallery and setup sheet.
@MainActor
enum Thumbnailer {
    private static let renderer: Renderer? = {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: MTLCreateSystemDefaultDevice())
        return Renderer(view: view)
    }()
    private static var cache: [String: NSImage] = [:]

    static func image(for design: Design, key: String, size: CGSize = CGSize(width: 720, height: 420)) -> NSImage? {
        if let img = cache[key] { return img }
        guard let r = renderer else { return nil }
        r.setScene(SceneBuilder.aircraft(design, nil, deflection: 0, showCG: false), resetCamera: true)
        r.yaw = 0.62; r.pitch = 0.42; r.zoom = 0.95
        guard let cg = r.snapshot(width: Int(size.width), height: Int(size.height),
                                  clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: size.width / 2, height: size.height / 2))
        cache[key] = img
        return img
    }
}
