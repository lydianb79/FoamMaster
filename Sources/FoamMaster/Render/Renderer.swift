import Foundation
import Metal
import MetalKit
import simd

/// Shared by the editor's 3D view and the flight simulator. Vertices carry a group tag in nrm.w: 1 lit, 0 unlit
/// (lines), ±(2 + k) = member of moving group k (propeller or control surface; negative = unlit line), turned about
/// the group's axis by its angle (buffer 2: centre, axis + angle per group). `model` places the scene in the world
/// (identity in the editor); `tint.w > 0` draws everything in that flat colour (shadows).
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vtx { float4 pos; float4 nrm; float4 col; };
struct Uni { float4x4 viewProj; float4x4 model; float4 light; float4 eye; float4 tint; float4 sky; float4 fog; float4 ground; float4 clip; };
struct Out { float4 pos [[position]]; float3 n; float3 w; float4 c; float lit; float water; float clip [[clip_distance]]; };

// Rodrigues rotation of p about the unit axis k by angle a.
float3 rot(float3 p, float3 k, float a) { return p * cos(a) + cross(k, p) * sin(a) + k * dot(k, p) * (1 - cos(a)); }

vertex Out vmain(const device Vtx* v [[buffer(0)]], constant Uni& u [[buffer(1)]], constant float4* grp [[buffer(2)]], uint id [[vertex_id]]) {
    Out o;
    float3 p = v[id].pos.xyz, n = v[id].nrm.xyz;
    float tag = v[id].nrm.w;
    float lit = tag > 0.5 ? 1.0 : 0.0;
    float g = abs(tag);
    if (g > 1.5) {
        int k = int(g - 2.0 + 0.5);
        float3 c = grp[2 * k].xyz, ax = normalize(grp[2 * k + 1].xyz);
        float a = grp[2 * k + 1].w;
        p = c + rot(p - c, ax, a);
        n = rot(n, ax, a);
    }
    float4 wp = u.model * float4(p, 1);
    o.pos = u.viewProj * wp;
    o.n = (u.model * float4(n, 0)).xyz;
    o.w = wp.xyz;
    bool flat = u.tint.w > 0;
    o.c = flat ? u.tint : v[id].col;
    o.lit = flat ? 0.0 : lit;
    // Water surfaces carry the tag 0.75 (lit, plus ripples and reflections in the simulator).
    o.water = (tag > 0.6 && tag < 0.9) ? 1.0 : 0.0;
    // Clip plane (the simulator's mirrored reflection pass keeps only what is above the water): (0,0,0,1) keeps all.
    o.clip = dot(float4(wp.xyz, 1), u.clip);
    return o;
}

// Clears the depth (to far: 0 with reversed Z) inside the current viewport – the simulator's zoom inset.
vertex float4 vclear(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2 - 1, 0, 1);
}
fragment float4 fclear() { return float4(0); }

// Distance haze (simulator): colour fades towards the horizon colour, fog.w = density per metre.
float4 hazed(float4 c, float3 w, constant Uni& u) {
    if (u.fog.w <= 0) { return c; }
    float f = 1.0 - exp(-distance(w, u.eye.xyz) * u.fog.w);
    return float4(mix(c.rgb, u.fog.rgb, f), c.a);
}

// Value noise for the ground texture (simulator).
float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), s.x), mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), s.x), s.y);
}

// Lit colour of a fragment; `sun` = 1 in sunlight, 0 in full shadow (the sun's direct light and its highlight go,
// the sky light and ambient stay).
float4 shade(Out in, constant Uni& u, float sun) {
    if (in.lit < 0.5) { return hazed(in.c, in.w, u); }
    float3 n = normalize(in.n);
    float3 v = normalize(u.eye.xyz - in.w);
    if (dot(n, v) < 0) { n = -n; }
    float3 l = normalize(u.light.xyz);
    float3 l2 = normalize(float3(-0.6, 0.3, -0.5));
    float diff = max(dot(n, l), 0.0) * sun;
    float fill = max(dot(n, l2), 0.0) * 0.25;
    float3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.35 * sun;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.45 * u.sky.w;
    // sky.xyz: sky light from above (outdoors), adds a soft blue fill on up-facing surfaces.
    float skyFill = max(n.y, 0.0) * 0.25;
    float3 base = in.c.rgb;
    if (u.ground.x > 0 && n.y > 0.55) {
        // ground.x: grass texture strength – blotches of a few metres, finer tufts close by, fading with distance.
        float d = distance(in.w, u.eye.xyz);
        float2 q = in.w.xz;
        float big = vnoise(q * 0.13) * 0.45 + vnoise(q * 0.55) * 0.35 + vnoise(q * 2.1) * 0.2;
        float fine = vnoise(q * 7.0) * 0.6 + vnoise(q * 19.0) * 0.4;
        float nearF = clamp(1.0 - d / 90.0, 0.0, 1.0), midF = clamp(1.0 - d / 700.0, 0.0, 1.0);
        float k = (big - 0.5) * 0.45 * midF + (fine - 0.5) * 0.35 * nearF;
        base *= 1.0 + k * u.ground.x;
        base.g *= 1.0 + (big - 0.5) * 0.08 * u.ground.x * midF;
    }
    // In shade the occluder also hides part of the sky: the ambient and sky light drop a little too.
    float shadeAmb = mix(0.72, 1.0, sun);
    float3 col = base * (0.32 * shadeAmb + 0.62 * diff + fill) + spec + rim * float3(0.35, 0.65, 1.0) + base * u.sky.rgb * skyFill * shadeAmb;
    return hazed(float4(col, in.c.a), in.w, u);
}

fragment float4 fmain(Out in [[stage_in]], constant Uni& u [[buffer(1)]]) { return shade(in, u, 1.0); }

// Simulator: sun shadows from two shadow maps rendered from the sun – the field (static) and the model (follows it).
struct ShadowUni { float4x4 worldVP; float4x4 modelVP; float4 params; float4 view; };
// params: x world on, y model on, z / w texel size; view: xy = 1 / target size (pixels), z time (s), w reflection on
float shadowLookup(depth2d<float> map, sampler s, float4x4 vp, float3 w, float texel, float bias) {
    float4 p = vp * float4(w, 1);
    float3 q = p.xyz / p.w;
    float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 || q.z > 1 || q.z < 0) { return 1.0; }
    float sum = 0;
    for (int y = -1; y <= 1; y++) { for (int x = -1; x <= 1; x++) {
        sum += map.sample_compare(s, uv + float2(x, y) * texel, q.z - bias);
    } }
    return sum / 9.0;
}
// The pond: moving ripples, the mirrored scene (planar reflection, rendered for this camera) mixed in by Fresnel,
// sun glints on the ripples.
float4 waterShade(Out in, constant Uni& u, constant ShadowUni& sh, texture2d<float> reflection, sampler lin, float sun) {
    float t = sh.view.z;
    float2 q = in.w.xz;
    float2 g = float2(cos(q.x * 1.7 + t * 1.3) * 0.5 + cos((q.x + q.y) * 2.9 - t * 1.9) * 0.3 + cos(q.x * 6.1 - t * 3.1) * 0.12,
                      cos(q.y * 1.9 - t * 1.1) * 0.5 + cos((q.x - q.y) * 3.3 + t * 2.3) * 0.3 + cos(q.y * 5.3 + t * 2.7) * 0.12);
    float3 n = normalize(float3(-g.x * 0.07, 1, -g.y * 0.07));
    float3 v = normalize(u.eye.xyz - in.w);
    float3 l = normalize(u.light.xyz);
    float fres = 0.05 + 0.95 * pow(1.0 - max(dot(n, v), 0.0), 5.0);
    float3 refl = u.fog.rgb;
    if (sh.view.w > 0) { refl = reflection.sample(lin, in.pos.xy * sh.view.xy + n.xz * 0.025).rgb; }
    float3 body = in.c.rgb * (0.3 + 0.35 * max(dot(n, l), 0.0) * sun);
    float3 col = mix(body, refl, clamp(0.25 + fres * 0.75, 0.0, 1.0));
    float glint = pow(max(dot(reflect(-l, n), v), 0.0), 220.0) * 2.5 * sun;
    return hazed(float4(col + glint, 1), in.w, u);
}

fragment float4 fsim(Out in [[stage_in]], constant Uni& u [[buffer(1)]], constant ShadowUni& sh [[buffer(3)]],
                     depth2d<float> worldMap [[texture(0)]], depth2d<float> modelMap [[texture(1)]], sampler cmp [[sampler(0)]],
                     texture2d<float> reflection [[texture(2)]], sampler lin [[sampler(1)]]) {
    float sun = 1.0;
    if (in.lit > 0.5) {
        // (biases in depth units: the field's map is 2400 m deep – 0.0003 ≈ 0.7 m; the model's 100 m – 0.002 = 0.2 m)
        if (sh.params.x > 0) { sun = min(sun, shadowLookup(worldMap, cmp, sh.worldVP, in.w, sh.params.z, 0.0003)); }
        if (sh.params.y > 0) { sun = min(sun, shadowLookup(modelMap, cmp, sh.modelVP, in.w, sh.params.w, 0.002)); }
    }
    if (in.water > 0.5) { return waterShade(in, u, sh, reflection, lin, sun); }
    return shade(in, u, sun);
}
"""

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var lineDepthState: MTLDepthStencilState!
    private var triBuffer: MTLBuffer?
    private var lineBuffer: MTLBuffer?
    private var triCount = 0
    private var lineCount = 0
    // CPU copy of the triangles for mouse picking.
    private var pickVerts: [SIMD3<Float>] = []
    private var pickLabels: [Int32] = []
    private var labelNames: [String] = []

    // Camera
    var yaw: Float = 0.75
    var pitch: Float = 0.45
    var zoom: Float = 1.0
    var target = SIMD3<Float>.zero
    var radius: Float = 300
    var autoRotate = false
    /// Motor running: the propellers spin (a visible ~5 turns per second – the real speed would only strobe).
    var motorOn = false
    private var spin: Float = 0
    private var groups: [SceneData.Group] = []
    private var lastTime = CACurrentMediaTime()

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        buildPipeline(view)
    }

    private func buildPipeline(_ view: MTKView) {
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain")
            d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.rasterSampleCount = view.sampleCount
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = view.colorPixelFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            fatalError("Metal pipeline failed: \(error)")
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)
        let ls = MTLDepthStencilDescriptor()
        ls.depthCompareFunction = .lessEqual
        ls.isDepthWriteEnabled = false
        lineDepthState = device.makeDepthStencilState(descriptor: ls)
    }

    func setScene(_ s: SceneData, resetCamera: Bool) {
        triCount = s.triangles.count
        lineCount = s.lines.count
        triBuffer = triCount > 0 ? device.makeBuffer(bytes: s.triangles, length: MemoryLayout<GPUVertex>.stride * triCount) : nil
        lineBuffer = lineCount > 0 ? device.makeBuffer(bytes: s.lines, length: MemoryLayout<GPUVertex>.stride * lineCount) : nil
        pickVerts = s.triangles.map { SIMD3($0.position.x, $0.position.y, $0.position.z) }
        pickLabels = s.triLabels
        groups = s.groups
        labelNames = s.labelNames
        if resetCamera {
            target = s.center
            radius = s.radius
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Renders the current scene into an image (used by the self-test and for snapshots).
    func snapshot(width: Int, height: Int, clear: MTLClearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1)) -> CGImage? {
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget]; cd.textureType = .type2DMultisample; cd.sampleCount = 4; cd.storageMode = .private
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]; rd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]; dd.textureType = .type2DMultisample; dd.sampleCount = 4; dd.storageMode = .private
        guard let msaa = device.makeTexture(descriptor: cd), let resolve = device.makeTexture(descriptor: rd),
              let depth = device.makeTexture(descriptor: dd), let cmd = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = clear
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc, aspect: Float(width) / Float(height))
        cmd.commit(); cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return ctx?.makeImage()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if autoRotate { yaw += Float(now - lastTime) * 0.35 }
        if motorOn { spin = (spin + Float(now - lastTime) * 2 * .pi * 5).truncatingRemainder(dividingBy: 2 * .pi * 1000) }
        lastTime = now

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let size = view.drawableSize
        encode(enc, aspect: Float(size.width / max(size.height, 1)))
        cmd.present(drawable)
        cmd.commit()
    }

    private func camera(aspect: Float) -> (viewProj: simd_float4x4, eye: SIMD3<Float>) {
        let dist = radius * 2.0 * zoom * max(1, 1.25 / max(aspect, 0.1))
        let eye = target + SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * dist
        let viewM = lookAt(eye: eye, center: target, up: [0, 1, 0])
        let proj = perspective(fovY: 0.7, aspect: aspect, near: max(dist * 0.02, 1), far: dist * 10)
        return (proj * viewM, eye)
    }

    /// Centres the model on screen and zooms so its projected outline fills `fill` of the view (thumbnails):
    /// the camera target moves to the centre of the projected bounding box (perspective – a few iterations).
    /// `centerY`: where the model's centre should land vertically (NDC, negative = lower, e.g. under overlay tags).
    func fitToView(aspect: Float, fill: Float = 0.86, centerY: Float = 0) {
        guard !pickVerts.isEmpty else { return }
        for _ in 0..<4 {
            let (vp, _) = camera(aspect: aspect)
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            var depth: Float = 0
            for v in pickVerts {
                let p = vp * SIMD4(v, 1)
                guard p.w > 1e-6 else { continue }
                let n = SIMD2(p.x, p.y) / p.w
                lo = simd_min(lo, n); hi = simd_max(hi, n)
            }
            let t = vp * SIMD4(target, 1); depth = t.z / t.w
            let c = (lo + hi) / 2
            let inv = vp.inverse
            let w = inv * SIMD4(c.x, c.y - centerY, depth, 1)
            target = SIMD3(w.x, w.y, w.z) / w.w
            let size = max((hi.x - lo.x) / 2, (hi.y - lo.y) / 2)
            if size > 1e-4 { zoom *= size / fill }
        }
    }

    /// Name of the nearest object under a point of the view (points, origin top-left), or nil.
    func pick(_ point: CGPoint, in size: CGSize) -> String? {
        guard size.width > 0, size.height > 0, !pickVerts.isEmpty else { return nil }
        let inv = camera(aspect: Float(size.width / size.height)).viewProj.inverse
        let nx = Float(2 * point.x / size.width - 1), ny = Float(1 - 2 * point.y / size.height)
        func unproject(_ z: Float) -> SIMD3<Float> { let p = inv * SIMD4(nx, ny, z, 1); return SIMD3(p.x, p.y, p.z) / p.w }
        let o = unproject(0), d = simd_normalize(unproject(1) - o)
        var best = Float.greatestFiniteMagnitude, hit = -1
        var i = 0
        let n = pickVerts.count - 2
        while i < n {
            // Möller–Trumbore ray / triangle intersection.
            let a = pickVerts[i], e1 = pickVerts[i + 1] - a, e2 = pickVerts[i + 2] - a
            let pv = simd_cross(d, e2)
            let det = simd_dot(e1, pv)
            if abs(det) > 1e-9 {
                let inv = 1 / det, tv = o - a
                let u = simd_dot(tv, pv) * inv
                if u >= 0 && u <= 1 {
                    let q = simd_cross(tv, e1)
                    let v = simd_dot(d, q) * inv
                    if v >= 0 && u + v <= 1 {
                        let t = simd_dot(e2, q) * inv
                        if t > 0 && t < best { best = t; hit = i / 3 }
                    }
                }
            }
            i += 3
        }
        guard hit >= 0, hit < pickLabels.count else { return nil }
        let name = labelNames[Int(pickLabels[hit])]
        return name.isEmpty ? nil : name
    }

    private func encode(_ enc: MTLRenderCommandEncoder, aspect: Float) {
        let (viewProj, eye) = camera(aspect: aspect)
        var uni = Uniforms(viewProj: viewProj, light: SIMD4(0.4, 0.9, 0.6, 0), eye: SIMD4(eye, 1))
        // Spinning propellers: each rotor turns at its own sense (counter-rotating pairs mirror each other).
        var grp = groupBuffer(groups) { _, g in g.kind == .prop ? spin * g.sense : 0 }
        enc.setVertexBytes(&grp, length: MemoryLayout<SIMD4<Float>>.stride * grp.count, index: 2)

        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let tb = triBuffer {
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(tb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triCount)
        }
        if let lb = lineBuffer {
            enc.setDepthStencilState(lineDepthState)
            enc.setVertexBuffer(lb, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
        }
        enc.endEncoding()
    }
}

struct Uniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4 = matrix_identity_float4x4
    var light: SIMD4<Float>
    var eye: SIMD4<Float>
    /// w > 0: flat colour for everything (shadow pass).
    var tint: SIMD4<Float> = .zero
    /// w: strength of the blue rim light (1 in the editor, lower outdoors); rgb: sky fill light.
    var sky: SIMD4<Float> = [0, 0, 0, 1]
    /// Distance haze: horizon colour, density per metre (0 = none).
    var fog: SIMD4<Float> = .zero
    var ground: SIMD4<Float> = .zero
    var clip: SIMD4<Float> = [0, 0, 0, 1]
}

/// Centre and axis + angle (w) of each moving group, as the shader reads them (buffer 2, 10 groups).
func groupBuffer(_ groups: [SceneData.Group], angle: (Int, SceneData.Group) -> Float) -> [SIMD4<Float>] {
    var out = [SIMD4<Float>](repeating: [0, 0, 1, 0], count: 2 * SceneData.maxGroups)
    for (k, g) in groups.prefix(SceneData.maxGroups).enumerated() {
        out[2 * k] = SIMD4(g.center, 1)
        out[2 * k + 1] = SIMD4(g.axis, angle(k, g))
    }
    return out
}

func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
    return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                   SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
}
