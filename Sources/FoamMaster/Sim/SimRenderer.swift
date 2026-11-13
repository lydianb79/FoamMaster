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
    private var skyDome: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int) = (nil, 0, nil, 0)
    private var skyDepthState: MTLDepthStencilState!
    private static var sceneryCache: (world: SceneData, sky: SceneData)?
    private var plane: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int) = (nil, 0, nil, 0)
    private var groups: [SceneData.Group] = []
    private var cgMM = SIMD3<Float>.zero
    private var span: Double = 0.5
    private var propAngle: Float = 0
    private var worldGroups: [SceneData.Group] = []
    private var worldTime: Float = 0
    private var lastTime = CACurrentMediaTime()
    var sim: FlightSim?
    var input: SimInputState?
    /// Called about 15 times a second with the latest state (for the HUD).
    var onTick: ((FlightSim, StickInput) -> Void)?
    private var tickAccum = 0.0
    var autoZoom = true
    var audio: SimAudio?
    /// The pilot's eye (self-test overviews can raise it).
    var eye = SIMD3<Float>(0, 1.7, 0)
    // Sun shadows: depth maps rendered from the sun – the field (static, drawn once) and the model (every frame).
    private var shadowPipeline: MTLRenderPipelineState?
    private var shadowDepthState: MTLDepthStencilState!
    private var compareSampler: MTLSamplerState!
    private var worldShadow: MTLTexture?, modelShadow: MTLTexture?
    private var worldShadowReady = false
    private var worldShadowVP = matrix_identity_float4x4, modelShadowVP = matrix_identity_float4x4
    static let worldShadowSize = 4096, modelShadowSize = 1024
    /// Field covered by the static shadow map (m): the area the model flies over, trees and pits included.
    static let worldShadowCentre = SIMD3<Float>(0, 0, -60), worldShadowHalf: Float = 320
    struct ShadowUniforms { var worldVP: simd_float4x4; var modelVP: simd_float4x4; var params: SIMD4<Float> }

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.74, green: 0.83, blue: 0.93, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.clearDepth = 0            // reversed-Z: 1 at the near plane, 0 far away
        do {
            let lib = try dev.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fsim")
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = view.colorPixelFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try dev.makeRenderPipelineState(descriptor: d)
            // Depth only, from the sun.
            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = lib.makeFunction(name: "vmain"); sd.fragmentFunction = nil
            sd.depthAttachmentPixelFormat = .depth32Float
            shadowPipeline = try dev.makeRenderPipelineState(descriptor: sd)
        } catch { return nil }
        let sds = MTLDepthStencilDescriptor(); sds.depthCompareFunction = .less; sds.isDepthWriteEnabled = true
        shadowDepthState = dev.makeDepthStencilState(descriptor: sds)
        let smp = MTLSamplerDescriptor()
        smp.minFilter = .linear; smp.magFilter = .linear; smp.compareFunction = .lessEqual
        smp.sAddressMode = .clampToEdge; smp.tAddressMode = .clampToEdge
        compareSampler = dev.makeSamplerState(descriptor: smp)
        func depthMap(_ n: Int) -> MTLTexture? {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: n, height: n, mipmapped: false)
            t.usage = [.renderTarget, .shaderRead]; t.storageMode = .private
            return dev.makeTexture(descriptor: t)
        }
        worldShadow = depthMap(Self.worldShadowSize); modelShadow = depthMap(Self.modelShadowSize)
        let ds = MTLDepthStencilDescriptor(); ds.depthCompareFunction = .greater; ds.isDepthWriteEnabled = true
        depthState = dev.makeDepthStencilState(descriptor: ds)
        let ls = MTLDepthStencilDescriptor(); ls.depthCompareFunction = .greaterEqual; ls.isDepthWriteEnabled = false
        lineDepthState = dev.makeDepthStencilState(descriptor: ls)
        let ks = MTLDepthStencilDescriptor(); ks.depthCompareFunction = .always; ks.isDepthWriteEnabled = false
        skyDepthState = dev.makeDepthStencilState(descriptor: ks)
        let sc = Self.sceneryCache ?? (SimScenery.build(), SimScenery.sky())
        Self.sceneryCache = sc
        world = buffers(sc.world)
        worldGroups = sc.world.groups
        skyDome = buffers(sc.sky)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// False while the simulator window is closed: nothing flies on and no sound starts (frames are still drawn).
    var simulating = true

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.05)
        lastTime = now
        // The flight and its sound only advance while the simulator is on screen (closed, hidden, minimised or in a
        // full-screen space you switched away from: paused, the sound fades out by itself). Drawing never stops, so
        // the picture always shows the design that is loaded – never a frame left over from before.
        let onScreen = view.window.map { $0.isVisible && ($0.occlusionState.contains(.visible) || $0.isKeyWindow) } ?? false
        if let sim, let input, simulating, onScreen {
            let stick = input.update(dt)
            sim.input = stick
            sim.step(dt)
            // After a crash: a second to take it in (and hear it), then the model is back in the hand.
            if sim.state.phase == .crashed, sim.state.crashAge > 1 { sim.reset() }
            tickAccum += dt
            if tickAccum > 1.0 / 15 { tickAccum = 0; onTick?(sim, stick) }
            audio?.update(sim: sim, eye: [0, 1.7, 0], dt: dt)
            propAngle += Float(dt) * 2 * .pi * Float(20 * sim.surfaces.throttle)
            propAngle = propAngle.truncatingRemainder(dividingBy: 2 * .pi * 100)
            worldTime += Float(dt)
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { return }
        if let sim { encodeShadows(cmd, sim: sim) }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        if let sim { encode(enc, sim: sim, aspect: Float(size.width / max(size.height, 1))) } else { enc.endEncoding() }
        cmd.present(drawable)
        cmd.commit()
    }

    /// The model's placement in the world (CG at its position, its attitude, mm → m).
    private func bodyMatrix(_ st: FlightState) -> simd_float4x4 {
        let q = simd_quatf(ix: Float(st.orientation.imag.x), iy: Float(st.orientation.imag.y), iz: Float(st.orientation.imag.z), r: Float(st.orientation.real))
        return translation(SIMD3<Float>(st.position)) * simd_float4x4(q) * simd_float4x4(diagonal: [0.001, 0.001, 0.001, 1]) * translation(-cgMM)
    }

    /// Orthographic view from the sun onto a box around `centre` (half size `half`): depth 0 near the sun.
    private static func sunViewProj(centre: SIMD3<Float>, half: Float, depth: Float) -> simd_float4x4 {
        let sun = simd_normalize(SIMD3<Float>(SimScenery.sunDir))
        let view = lookAt(eye: centre + sun * depth / 2, center: centre, up: [0, 1, 0])
        let n: Float = 0, f = depth
        let proj = simd_float4x4(columns: (SIMD4(1 / half, 0, 0, 0), SIMD4(0, 1 / half, 0, 0), SIMD4(0, 0, -1 / (f - n), 0), SIMD4(0, 0, -n / (f - n), 1)))
        return proj * view
    }

    /// Sun shadow maps: the field once (trees, buildings, pits, clouds over it, the terrain), the model every frame.
    private func encodeShadows(_ cmd: MTLCommandBuffer, sim: FlightSim) {
        guard let shadowPipeline else { return }
        func pass(_ tex: MTLTexture?, _ body: (MTLRenderCommandEncoder) -> Void) {
            guard let tex else { return }
            let p = MTLRenderPassDescriptor()
            p.depthAttachment.texture = tex; p.depthAttachment.loadAction = .clear; p.depthAttachment.storeAction = .store; p.depthAttachment.clearDepth = 1
            guard let e = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
            e.setRenderPipelineState(shadowPipeline); e.setDepthStencilState(shadowDepthState); e.setCullMode(.none)
            e.setDepthBias(0, slopeScale: 1.5, clamp: 0.0004)    // (a slope-scaled nudge against acne, at most ≈ 1 m)
            body(e); e.endEncoding()
        }
        if !worldShadowReady, let tri = world.tri {
            worldShadowVP = Self.sunViewProj(centre: Self.worldShadowCentre, half: Self.worldShadowHalf, depth: 2400)
            pass(worldShadow) { e in
                var u = Uniforms(viewProj: worldShadowVP, light: .zero, eye: .zero)
                var g = groupBuffer(worldGroups) { _, _ in 0 }
                e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.setVertexBytes(&g, length: MemoryLayout<SIMD4<Float>>.stride * g.count, index: 2)
                e.setVertexBuffer(tri, offset: 0, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: world.triCount)
            }
            worldShadowReady = true
        }
        // The model: a small box around it, sharp.
        let st = sim.state
        let half = Float(max(span, 0.3)) * 0.8 + 0.2
        modelShadowVP = Self.sunViewProj(centre: SIMD3<Float>(st.position), half: half, depth: 100)
        if let tri = plane.tri {
            pass(modelShadow) { e in
                var u = Uniforms(viewProj: modelShadowVP, light: .zero, eye: .zero)
                u.model = bodyMatrix(st)
                let s = sim.surfaces, pa = propAngle
                var g = groupBuffer(groups) { _, gr in Self.groupAngle(gr, s, prop: pa) }
                e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.setVertexBytes(&g, length: MemoryLayout<SIMD4<Float>>.stride * g.count, index: 2)
                e.setVertexBuffer(tri, offset: 0, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plane.triCount)
            }
        }
    }

    /// Advance the propeller animation (for snapshots outside the view loop).
    func spinProp(_ dt: Double, throttle: Double) { propAngle += Float(dt) * 2 * .pi * Float(20 * throttle) }

    func encode(_ enc: MTLRenderCommandEncoder, sim: FlightSim, aspect: Float) {
        // Line of sight from the pilot's eyes; optional auto zoom keeps a small model visible far out.
        let eye = self.eye
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
        let proj = reversedPerspective(fovY: fov, aspect: aspect, near: 0.05, far: 7000)
        var uni = Uniforms(viewProj: proj * viewM, light: SIMD4(SIMD3<Float>(SimScenery.sunDir), 0), eye: SIMD4(eye, 1))
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setFragmentTexture(worldShadow, index: 0); enc.setFragmentTexture(modelShadow, index: 1)
        enc.setFragmentSamplerState(compareSampler, index: 0)
        var shadowU = ShadowUniforms(worldVP: worldShadowVP, modelVP: modelShadowVP,
                                     params: [worldShadowReady ? 1 : 0, 1, 1 / Float(Self.worldShadowSize), 1 / Float(Self.modelShadowSize)])
        enc.setFragmentBytes(&shadowU, length: MemoryLayout<ShadowUniforms>.stride, index: 3)
        var none = groupBuffer([]) { _, _ in 0 }
        func draw(_ b: (tri: MTLBuffer?, triCount: Int, line: MTLBuffer?, lineCount: Int), lines: Bool = true) {
            enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
            if let t = b.tri { enc.setDepthStencilState(depthState); enc.setVertexBuffer(t, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.triCount) }
            if lines, let l = b.line { enc.setDepthStencilState(lineDepthState); enc.setVertexBuffer(l, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: b.lineCount) }
        }
        enc.setVertexBytes(&none, length: MemoryLayout<SIMD4<Float>>.stride * none.count, index: 2)
        // Sky dome around the eye (no depth, no haze), then the site in the haze with a blue sky fill from above.
        uni.model = translation(eye) * simd_float4x4(diagonal: [0.25, 0.25, 0.25, 1])
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let t = skyDome.tri { enc.setDepthStencilState(skyDepthState); enc.setVertexBuffer(t, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: skyDome.triCount) }
        uni.model = matrix_identity_float4x4
        uni.sky = [0.55, 0.7, 1.0, 0.25]
        uni.fog = SIMD4(SimScenery.horizon.x, SimScenery.horizon.y, SimScenery.horizon.z, 0.00026)
        uni.ground = [1, 0, 0, 0]
        let t = worldTime
        var birds = groupBuffer(worldGroups) { _, g in t * g.sense }
        enc.setVertexBytes(&birds, length: MemoryLayout<SIMD4<Float>>.stride * birds.count, index: 2)
        draw(world)
        uni.ground = .zero
        uni.fog.w = 0.00012
        // Aircraft: CG at its position, its attitude, mm → m; surfaces and props move.
        let s = sim.surfaces
        let pa = propAngle
        var grp = groupBuffer(groups) { _, g in Self.groupAngle(g, s, prop: pa) }
        enc.setVertexBytes(&grp, length: MemoryLayout<SIMD4<Float>>.stride * grp.count, index: 2)
        let q = simd_quatf(ix: Float(st.orientation.imag.x), iy: Float(st.orientation.imag.y), iz: Float(st.orientation.imag.z), r: Float(st.orientation.real))
        let body = simd_float4x4(q) * simd_float4x4(diagonal: [0.001, 0.001, 0.001, 1]) * translation(-cgMM)
        // The aircraft (its shadow comes from the model shadow map; it does not shade itself).
        shadowU.params.y = 0
        enc.setFragmentBytes(&shadowU, length: MemoryLayout<ShadowUniforms>.stride, index: 3)
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
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.74, green: 0.83, blue: 0.93, alpha: 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.clearDepth = 0
        encodeShadows(cmd, sim: sim)
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

/// Reversed-Z projection (depth 1 at the near plane, 0 at the far one): with a float depth buffer this keeps
/// precision out to kilometres, so distant surfaces (mountains, clouds) don't flicker.
func reversedPerspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2), x = y / aspect
    let a = near / (far - near), b = far * near / (far - near)
    return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, a, -1), SIMD4(0, 0, b, 0)))
}
