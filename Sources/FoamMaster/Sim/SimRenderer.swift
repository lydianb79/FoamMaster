import Foundation
import Metal
import MetalKit
import simd

/// Where the simulator looks from.
enum SimCamera: String, CaseIterable, Identifiable, Codable {
    case pilot, chase, onboard
    var id: String { rawValue }
    var title: String { [.pilot: "Pilot", .chase: "Chase", .onboard: "Onboard"][self]! }
    var next: SimCamera { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
}

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
    private var clearDepthState: MTLDepthStencilState!
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
    /// Camera: the pilot's view (line of sight), behind the model (chase) or on board.
    var camera: SimCamera = .pilot
    /// Zoomed inset of the model (pilot view, model far out) and a smoke trail.
    var showInset = true, smoke = false
    /// The inset's place on screen (fractions of the view, from the top left).
    static let insetRect = (x: 0.70, y: 0.58, w: 0.28, h: 0.28)
    private(set) var insetVisible = false
    private var chaseEye: SIMD3<Float>?
    private var lastViewProj = matrix_identity_float4x4
    let effects = SimEffects()
    private var lastPhase: FlightState.Phase = .held
    // Pond reflection: the scene mirrored in the water plane, rendered for the current camera (half resolution).
    private var reflectPipeline: MTLRenderPipelineState?
    private var clearPipeline: MTLRenderPipelineState?
    private var linearSampler: MTLSamplerState!
    private var reflectColor: MTLTexture?, reflectDepth: MTLTexture?, dummyColor: MTLTexture?
    private var reflectSize = (0, 0)
    static let waterLevel: Float = 0.05
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
    struct ShadowUniforms { var worldVP: simd_float4x4; var modelVP: simd_float4x4; var params: SIMD4<Float>; var view: SIMD4<Float> = .zero }

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
            // The mirrored scene for the pond (one sample, its own target).
            let rd = MTLRenderPipelineDescriptor()
            rd.vertexFunction = d.vertexFunction; rd.fragmentFunction = d.fragmentFunction
            rd.depthAttachmentPixelFormat = .depth32Float
            rd.colorAttachments[0].pixelFormat = view.colorPixelFormat
            rd.colorAttachments[0].isBlendingEnabled = true
            rd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; rd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            reflectPipeline = try dev.makeRenderPipelineState(descriptor: rd)
            // Depth clear inside the inset (no colour written).
            let cd = MTLRenderPipelineDescriptor()
            cd.vertexFunction = lib.makeFunction(name: "vclear"); cd.fragmentFunction = lib.makeFunction(name: "fclear")
            cd.rasterSampleCount = view.sampleCount
            cd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            cd.colorAttachments[0].pixelFormat = view.colorPixelFormat
            cd.colorAttachments[0].writeMask = []
            clearPipeline = try dev.makeRenderPipelineState(descriptor: cd)
            // Depth only, from the sun.
            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = lib.makeFunction(name: "vmain"); sd.fragmentFunction = nil
            sd.depthAttachmentPixelFormat = .depth32Float
            shadowPipeline = try dev.makeRenderPipelineState(descriptor: sd)
        } catch { FileHandle.standardError.write("SimRenderer: \(error)\n".data(using: .utf8)!); return nil }
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
        let ls2 = MTLSamplerDescriptor(); ls2.minFilter = .linear; ls2.magFilter = .linear
        ls2.sAddressMode = .clampToEdge; ls2.tAddressMode = .clampToEdge
        linearSampler = dev.makeSamplerState(descriptor: ls2)
        let dt = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat, width: 1, height: 1, mipmapped: false)
        dt.usage = [.shaderRead]
        dummyColor = dev.makeTexture(descriptor: dt)
        let ds = MTLDepthStencilDescriptor(); ds.depthCompareFunction = .greater; ds.isDepthWriteEnabled = true
        depthState = dev.makeDepthStencilState(descriptor: ds)
        let ls = MTLDepthStencilDescriptor(); ls.depthCompareFunction = .greaterEqual; ls.isDepthWriteEnabled = false
        lineDepthState = dev.makeDepthStencilState(descriptor: ls)
        let ks = MTLDepthStencilDescriptor(); ks.depthCompareFunction = .always; ks.isDepthWriteEnabled = false
        skyDepthState = dev.makeDepthStencilState(descriptor: ks)
        let cs = MTLDepthStencilDescriptor(); cs.depthCompareFunction = .always; cs.isDepthWriteEnabled = true
        clearDepthState = dev.makeDepthStencilState(descriptor: cs)
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
            advanceEffects(sim, dt: Float(dt))
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let cmd = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        if let sim {
            encodeShadows(cmd, sim: sim)
            encodeReflection(cmd, sim: sim, width: Int(size.width), height: Int(size.height))
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let sim { encode(enc, sim: sim, width: Float(size.width), height: Float(size.height)) } else { enc.endEncoding() }
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

    /// Effects follow the flight: a crash, a landing, the pond, the smoke trail.
    private func advanceEffects(_ sim: FlightSim, dt: Float) {
        let st = sim.state
        let pos = SIMD3<Float>(st.position)
        if st.phase != lastPhase {
            let speed = Float(simd_length(st.velocity))
            switch st.phase {
            case .crashed:
                switch st.impact {
                case .water: effects.splash(at: pos, speed: max(speed, Float(lastSpeed)))
                case .ground: effects.crash(at: pos, speed: Float(lastSpeed), tree: false)
                case .tree: effects.crash(at: pos, speed: Float(lastSpeed), tree: true)
                default: break
                }
            case .landed: effects.landing(at: pos, speed: Float(lastSpeed))
            case .held: break
            case .flying: break
            }
            lastPhase = st.phase
        }
        if st.phase == .flying {
            lastSpeed = sim.airspeed
            if smoke {
                let tail = pos + simd_act(quat(st), [0, 0, Float(span) * 0.55])
                effects.smoke(from: tail, dt: dt)
            }
        }
        effects.update(dt)
    }
    private var lastSpeed = 0.0

    private func quat(_ st: FlightState) -> simd_quatf {
        simd_quatf(ix: Float(st.orientation.imag.x), iy: Float(st.orientation.imag.y), iz: Float(st.orientation.imag.z), r: Float(st.orientation.real))
    }

    /// Camera for the main view: eye, the point looked at, up, field of view.
    private func mainCamera(_ sim: FlightSim) -> (eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, fov: Float) {
        let st = sim.state
        let target = SIMD3<Float>(st.position)
        let q = quat(st)
        switch camera {
        case .pilot:
            // Line of sight from the pilot's eyes; optional auto zoom keeps a small model visible far out.
            let dist = Double(simd_length(target - eye))
            var fov: Float = 50 * .pi / 180
            if autoZoom {
                // The model spans about a third of the view height (never narrower than 6°, never wider than 60°).
                let want: Double = 2 * atan(span * 1.6 / max(dist, 0.5))
                let lo: Double = 6 * Double.pi / 180, hi: Double = 60 * Double.pi / 180
                fov = Float(min(max(want, lo), hi))
            }
            return (eye, target, [0, 1, 0], fov)
        case .chase:
            // Behind and a little above the model, following its heading smoothly.
            var fwd = q.act([0, 0, -1]); fwd.y = 0
            if simd_length(fwd) < 0.1 { fwd = [0, 0, -1] }
            fwd = simd_normalize(fwd)
            let d = Float(max(span * 4, 2.5))
            var want = target - fwd * d + SIMD3<Float>(0, d * 0.32, 0)
            let ground = Float(SimScenery.surfaceHeight(Double(want.x), Double(want.z))) + 0.4
            want.y = max(want.y, ground)
            let now = CACurrentMediaTime()
            let k = Float(min(max((now - lastChaseTime) * 4, 0), 1))
            lastChaseTime = now
            chaseEye = chaseEye.map { $0 + (want - $0) * (k == 0 ? 1 : k) } ?? want
            return (chaseEye!, target, [0, 1, 0], 55 * .pi / 180)
        case .onboard:
            // From the cockpit: just ahead of the CG, looking along the nose, rolling with the model.
            let e = target + q.act([0, 0.035, -Float(span) * 0.12])
            return (e, e + q.act([0, -0.08, -1]), q.act([0, 1, 0]), 75 * .pi / 180)
        }
    }
    private var lastChaseTime = CACurrentMediaTime()

    /// Mirror in the water plane (y = water level).
    private static var mirror: simd_float4x4 {
        translation([0, 2 * waterLevel, 0]) * simd_float4x4(diagonal: [1, -1, 1, 1])
    }

    /// The pond's reflection: the scene mirrored in the water, for the main camera, at half resolution.
    private func encodeReflection(_ cmd: MTLCommandBuffer, sim: FlightSim, width: Int, height: Int) {
        guard let reflectPipeline, camera != .onboard else { return }
        let w = max(width / 2, 1), h = max(height / 2, 1)
        if reflectSize != (w, h) || reflectColor == nil {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            cd.usage = [.renderTarget, .shaderRead]; cd.storageMode = .private
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            dd.usage = [.renderTarget]; dd.storageMode = .private
            reflectColor = device.makeTexture(descriptor: cd); reflectDepth = device.makeTexture(descriptor: dd)
            reflectSize = (w, h)
        }
        guard let reflectColor, let reflectDepth else { return }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = reflectColor; p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .store
        p.colorAttachments[0].clearColor = MTLClearColor(red: 0.74, green: 0.83, blue: 0.93, alpha: 1)
        p.depthAttachment.texture = reflectDepth; p.depthAttachment.loadAction = .clear; p.depthAttachment.clearDepth = 0
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: p) else { return }
        let cam = mainCamera(sim)
        let view = lookAt(eye: cam.eye, center: cam.center, up: cam.up) * Self.mirror
        let proj = reversedPerspective(fovY: cam.fov, aspect: Float(width) / Float(max(height, 1)), near: 0.05, far: 7000)
        enc.setRenderPipelineState(reflectPipeline)
        drawScene(enc, sim: sim, viewProj: proj * view, eye: cam.eye, model: true, reflection: true, targetSize: [Float(w), Float(h)])
        enc.endEncoding()
    }

    func encode(_ enc: MTLRenderCommandEncoder, sim: FlightSim, width: Float, height: Float) {
        let cam = mainCamera(sim)
        let viewM = lookAt(eye: cam.eye, center: cam.center, up: cam.up)
        let proj = reversedPerspective(fovY: cam.fov, aspect: width / max(height, 1), near: 0.05, far: 7000)
        lastViewProj = proj * viewM
        enc.setRenderPipelineState(pipeline)
        drawScene(enc, sim: sim, viewProj: lastViewProj, eye: cam.eye, model: camera != .onboard, reflection: false, targetSize: [width, height])
        // Zoom inset (pilot view): the model seen close up from the pilot's eye, in the lower right corner.
        let target = SIMD3<Float>(sim.state.position)
        let dist = simd_length(target - eye)
        insetVisible = camera == .pilot && showInset && dist > 25
        if insetVisible, let clearPipeline {
            let r = Self.insetRect
            let vp = MTLViewport(originX: r.x * Double(width), originY: r.y * Double(height), width: r.w * Double(width), height: r.h * Double(height), znear: 0, zfar: 1)
            enc.setViewport(vp)
            enc.setScissorRect(MTLScissorRect(x: Int(vp.originX), y: Int(vp.originY), width: Int(vp.width), height: Int(vp.height)))
            enc.setRenderPipelineState(clearPipeline)
            enc.setDepthStencilState(clearDepthState)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            let wantFov: Double = 2 * atan(span * 1.3 / Double(dist))
            let minFov: Double = Double.pi / 180, maxFov: Double = 30 * Double.pi / 180
            let fov = Float(min(max(wantFov, minFov), maxFov))
            let insetProj = reversedPerspective(fovY: fov, aspect: Float(vp.width / vp.height), near: 0.05, far: 7000)
            enc.setRenderPipelineState(pipeline)
            drawScene(enc, sim: sim, viewProj: insetProj * lookAt(eye: eye, center: target, up: [0, 1, 0]), eye: eye, model: true, reflection: false,
                      targetSize: [width, height], noReflection: true)
        }
        enc.endEncoding()
    }

    /// Sky, site, model and effects with one camera (main view, inset or the mirrored reflection).
    private func drawScene(_ enc: MTLRenderCommandEncoder, sim: FlightSim, viewProj: simd_float4x4, eye: SIMD3<Float>, model drawModel: Bool,
                           reflection: Bool, targetSize: SIMD2<Float>, noReflection: Bool = false) {
        let st = sim.state
        let target = SIMD3<Float>(st.position)
        var uni = Uniforms(viewProj: viewProj, light: SIMD4(SIMD3<Float>(SimScenery.sunDir), 0), eye: SIMD4(eye, 1))
        if reflection { uni.clip = [0, 1, 0, -(Self.waterLevel + 0.01)] }   // only what is above the water
        enc.setCullMode(.none)
        enc.setFragmentTexture(worldShadow, index: 0); enc.setFragmentTexture(modelShadow, index: 1)
        enc.setFragmentTexture(reflection || noReflection ? dummyColor : reflectColor, index: 2)
        enc.setFragmentSamplerState(compareSampler, index: 0); enc.setFragmentSamplerState(linearSampler, index: 1)
        let reflOn: Float = (reflection || noReflection || reflectColor == nil || camera == .onboard) ? 0 : 1
        var shadowU = ShadowUniforms(worldVP: worldShadowVP, modelVP: modelShadowVP,
                                     params: [worldShadowReady ? 1 : 0, 1, 1 / Float(Self.worldShadowSize), 1 / Float(Self.modelShadowSize)],
                                     view: [1 / targetSize.x, 1 / targetSize.y, worldTime, reflOn])
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
        if reflection { uni.clip = [0, 0, 0, 1] }
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let t = skyDome.tri { enc.setDepthStencilState(skyDepthState); enc.setVertexBuffer(t, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: skyDome.triCount) }
        if reflection { uni.clip = [0, 1, 0, -(Self.waterLevel + 0.01)] }
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
        // Aircraft: CG at its position, its attitude, mm → m; surfaces and props move. It does not shade itself.
        shadowU.params.y = 0
        enc.setFragmentBytes(&shadowU, length: MemoryLayout<ShadowUniforms>.stride, index: 3)
        if drawModel {
            let s = sim.surfaces
            let pa = propAngle
            var grp = groupBuffer(groups) { _, g in Self.groupAngle(g, s, prop: pa) }
            enc.setVertexBytes(&grp, length: MemoryLayout<SIMD4<Float>>.stride * grp.count, index: 2)
            uni.model = bodyMatrix(st)
            draw(plane)
        }
        _ = target
        // Effects: camera-facing quads, translucent, not writing depth.
        if !effects.particles.isEmpty {
            let inv = viewProj.inverse
            let right = simd_normalize(SIMD3<Float>(inv.columns.0.x, inv.columns.0.y, inv.columns.0.z))
            let up = simd_normalize(SIMD3<Float>(inv.columns.1.x, inv.columns.1.y, inv.columns.1.z))
            let verts = effects.vertices(right: right, up: up)
            if !verts.isEmpty, let buf = device.makeBuffer(bytes: verts, length: MemoryLayout<GPUVertex>.stride * verts.count) {
                uni.model = matrix_identity_float4x4
                enc.setVertexBytes(&none, length: MemoryLayout<SIMD4<Float>>.stride * none.count, index: 2)
                enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setDepthStencilState(lineDepthState)
                enc.setVertexBuffer(buf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            }
        }
    }

    /// Where the model's nose points on screen (radians, 0 = right, counter-clockwise) and whether it comes towards
    /// the pilot – for the HUD's direction arrow.
    func noseOnScreen(_ sim: FlightSim) -> (angle: Double, towards: Bool) {
        let st = sim.state
        let p = SIMD3<Float>(st.position), n = p + quat(st).act([0, 0, -Float(max(span, 0.3))])
        func screen(_ w: SIMD3<Float>) -> SIMD2<Float> { let c = lastViewProj * SIMD4(w, 1); return SIMD2(c.x, c.y) / max(abs(c.w), 1e-4) }
        let d = screen(n) - screen(p)
        let fwd = quat(st).act([0, 0, -1])
        let towards = simd_dot(fwd, simd_normalize(eye - p)) > 0
        return (Double(atan2(d.y, d.x)), towards)
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
        encodeReflection(cmd, sim: sim, width: width, height: height)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc, sim: sim, width: Float(width), height: Float(height))
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
