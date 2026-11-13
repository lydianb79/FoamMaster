import Foundation
import Metal
import MetalKit
import simd

/// Draws the flying field and the aircraft for the flight simulator and advances the simulation every frame.
final class SimRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var lineDepthState: MTLDepthStencilState!
    private var world: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int) = (nil, 0, nil, 0)
    private var plane: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int) = (nil, 0, nil, 0)
    private var groups: [SceneData.Group] = []
    private var cgMM = SIMD3<Float>.zero
    private var span: Double = 0.5
    private var propAngle: Float = 0
    private var lastTime = CACurrentMediaTime()
    var sim: FlightSim?
    var input: SimInputState?
    /// Called about 15 times a second with the latest state (for the HUD).
    var onTick: ((FlightSim, StickInput) -> Void)?
    private var tickAccum = 0.0
    var autoZoom = true

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.58, green: 0.76, blue: 0.94, alpha: 1)
        view.preferredFramesPerSecond = 60
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = view.colorPixelFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
        } catch { return nil }
        let ds = MTLDepthStencilDescriptor(); ds.depthCompareFunction = .less; ds.isDepthWriteEnabled = true
        depthState = dev.makeDepthStencilState(descriptor: ds)
        let ls = MTLDepthStencilDescriptor(); ls.depthCompareFunction = .lessEqual; ls.isDepthWriteEnabled = false
        lineDepthState = dev.makeDepthStencilState(descriptor: ls)
        let w = Self.field()
        world = buffers(w)
    }

    private func buffers(_ s: SceneData) -> (MTLBuffer?, Int, MTLBuffer?, Int) {
        (s.triangles.isEmpty ? nil : device.makeBuffer(bytes: s.triangles, length: MemoryLayout<GPUVertex>.stride * s.triangles.count), s.triangles.count,
         s.lines.isEmpty ? nil : device.makeBuffer(bytes: s.lines, length: MemoryLayout<GPUVertex>.stride * s.lines.count), s.lines.count)
    }

    /// The aircraft in its own (mm) frame with moving surfaces and props, rotated about its CG.
    func setAircraft(_ d: Design, _ a: Analysis) {
        let scene = SceneBuilder.aircraft(d, a, deflection: 0, showCG: false, animated: true)
        plane = buffers(scene)
        groups = scene.groups
        cgMM = SIMD3<Float>(a.cg)
        span = d.config.wingspan / 1000
    }

    /// Grass field (metres): mown strip, 10 m grid, a ring of trees, the pilot's spot.
    static func field() -> SceneData {
        var s = SceneData()
        let grass = SIMD4<Float>(0.33, 0.56, 0.26, 1), strip = SIMD4<Float>(0.45, 0.66, 0.33, 1)
        s.label = "Field"
        s.addMesh(.box(min: [-1500, -0.2, -1500], max: [1500, 0, 1500]), color: grass)
        s.addMesh(.box(min: [-6, 0, -70], max: [6, 0.004, 10]), color: strip)
        for k in stride(from: -200.0, through: 200.0, by: 10) {
            s.addLine([k, 0.01, -200], [k, 0.01, 200], color: SIMD4(1, 1, 1, 0.08))
            s.addLine([-200, 0.01, k], [200, 0.01, k], color: SIMD4(1, 1, 1, 0.08))
        }
        // Pilot's spot (a small mat) and a few cones on the strip as distance marks.
        s.addMesh(.box(min: [-0.6, 0, -0.6], max: [0.6, 0.02, 0.6]), color: SIMD4(0.85, 0.85, 0.8, 1))
        for z in [-20.0, -40.0, -60.0] {
            s.addMesh(SceneBuilder.cylinder(center: [6.5, 0.15, z], radius: 0.15, length: 0.3).rotated(.pi / 2, axis: [1, 0, 0]).translated([0, 0, 0]), color: SIMD4(1, 0.5, 0.1, 1))
        }
        // Trees around the field (fixed positions).
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var seed: UInt64 = 12345
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for _ in 0..<70 {
            let a = rnd() * 2 * .pi, r = 90 + rnd() * 160
            let x = cos(a) * r, z = sin(a) * r
            let h = 6 + rnd() * 9
            s.addMesh(SceneBuilder.cylinder(center: [x, h * 0.2, z], radius: 0.35, length: h * 0.4).rotated(.pi / 2, axis: [1, 0, 0]).translated([0, 0, 0]),
                      color: SIMD4(0.35, 0.25, 0.15, 1))
            let crown = SceneBuilder.sphere(center: [0, 0, 0], radius: 1).transformed { p in [x + p.x * h * 0.28, h * 0.62 + p.y * h * 0.4, z + p.z * h * 0.28] }
            s.addMesh(crown, color: SIMD4(0.16 + Float(rnd()) * 0.08, 0.36 + Float(rnd()) * 0.1, 0.16, 1))
        }
        return s
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.05)
        lastTime = now
        guard let sim, let input else { return }
        let stick = input.update(dt)
        sim.input = stick
        sim.step(dt)
        tickAccum += dt
        if tickAccum > 1.0 / 15 { tickAccum = 0; onTick?(sim, stick) }
        propAngle += Float(dt) * 2 * .pi * Float(20 * sim.surfaces.throttle)
        propAngle = propAngle.truncatingRemainder(dividingBy: 2 * .pi * 100)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        encode(enc, sim: sim, aspect: Float(size.width / max(size.height, 1)))
        cmd.present(drawable)
        cmd.commit()
    }

    /// Advance the propeller animation (for snapshots outside the view loop).
    func spinProp(_ dt: Double, throttle: Double) { propAngle += Float(dt) * 2 * .pi * Float(20 * throttle) }

    func encode(_ enc: MTLRenderCommandEncoder, sim: FlightSim, aspect: Float) {
        // Line of sight from the pilot's eyes; optional auto zoom keeps a small model visible far out.
        let eye = SIMD3<Float>(0, 1.7, 0)
        let st = sim.state
        let target = SIMD3<Float>(st.position)
        let dist = Double(simd_length(target - eye))
        var fov: Float = 50 * .pi / 180
        if autoZoom {
            // The model spans about a third of the view height (never narrower than 6°, never wider than 60°).
            let want: Double = 2 * atan(span * 1.6 / max(dist, 0.5))
            let lo: Double = 6 * Double.pi / 180, hi: Double = 60 * Double.pi / 180
            fov = Float(min(max(want, lo), hi))
        }
        let viewM = lookAt(eye: eye, center: target, up: [0, 1, 0])
        let proj = perspective(fovY: fov, aspect: aspect, near: 0.05, far: 4000)
        var uni = Uniforms(viewProj: proj * viewM, light: SIMD4(0.35, 0.9, 0.3, 0), eye: SIMD4(eye, 1))
        uni.sky = [0, 0, 0, 0.25]
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        var none = groupBuffer([]) { _, _ in 0 }
        func draw(_ b: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int), lines: Bool = true) {
            enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
            if let t = b.tri { enc.setDepthStencilState(depthState); enc.setVertexBuffer(t, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.triCount) }
            if lines, let l = b.line { enc.setDepthStencilState(lineDepthState); enc.setVertexBuffer(l, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: b.lineCount) }
        }
        enc.setVertexBytes(&none, length: MemoryLayout<SIMD4<Float>>.stride * none.count, index: 2)
        draw(world)
        // Aircraft: CG at its position, its attitude, mm → m; surfaces and props move.
        let s = sim.surfaces
        let pa = propAngle
        var grp = groupBuffer(groups) { _, g in Self.groupAngle(g, s, prop: pa) }
        enc.setVertexBytes(&grp, length: MemoryLayout<SIMD4<Float>>.stride * grp.count, index: 2)
        let q = simd_quatf(ix: Float(st.orientation.imag.x), iy: Float(st.orientation.imag.y), iz: Float(st.orientation.imag.z), r: Float(st.orientation.real))
        let body = simd_float4x4(q) * simd_float4x4(diagonal: [0.001, 0.001, 0.001, 1]) * translation(-cgMM)
        // Shadow on the grass (flattened, translucent), then the aircraft.
        uni.model = translation([target.x, 0.012, target.z]) * simd_float4x4(diagonal: [1, 0, 1, 1]) * body
        uni.tint = [0.05, 0.1, 0.03, 0.35]
        draw(plane, lines: false)
        uni.model = translation(target) * body
        uni.tint = .zero
        draw(plane)
        enc.endEncoding()
    }

    /// The current frame as an image (self-test).
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard let sim else { return nil }
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget]; cd.textureType = .type2DMultisample; cd.sampleCount = 4; cd.storageMode = .private
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]; rd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]; dd.textureType = .type2DMultisample; dd.sampleCount = 4; dd.storageMode = .private
        guard let msaa = device.makeTexture(descriptor: cd), let resolve = device.makeTexture(descriptor: rd),
              let depth = device.makeTexture(descriptor: dd), let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa; pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.58, green: 0.76, blue: 0.94, alpha: 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc, sim: sim, aspect: Float(width) / Float(height))
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return ctx?.makeImage()
    }
}

extension SimRenderer {
    /// Angle of a moving group: the prop spin, or the surface deflection from the stick mix.
    static func groupAngle(_ g: SceneData.Group, _ s: StickInput, prop: Float) -> Float {
        if g.kind == .prop { return prop * g.sense }
        let r = Double(g.roll) * s.roll
        let p = Double(g.pitch) * s.pitch
        let y = Double(g.yaw) * s.yaw
        let mix = min(max(r + p + y, -1.0), 1.0)
        return Float(mix) * g.maxAngle
    }
}

func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t, 1)
    return m
}
