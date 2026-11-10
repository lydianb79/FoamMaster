import Foundation
import Metal
import MetalKit
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vtx { float4 pos; float4 nrm; float4 col; };
struct Uni { float4x4 viewProj; float4 light; float4 eye; };
struct Out { float4 pos [[position]]; float3 n; float3 w; float4 c; float lit; };

vertex Out vmain(const device Vtx* v [[buffer(0)]], constant Uni& u [[buffer(1)]], uint id [[vertex_id]]) {
    Out o;
    o.pos = u.viewProj * v[id].pos;
    o.n = v[id].nrm.xyz;
    o.w = v[id].pos.xyz;
    o.c = v[id].col;
    o.lit = v[id].nrm.w;
    return o;
}

fragment float4 fmain(Out in [[stage_in]], constant Uni& u [[buffer(1)]]) {
    if (in.lit < 0.5) { return in.c; }
    float3 n = normalize(in.n);
    float3 v = normalize(u.eye.xyz - in.w);
    if (dot(n, v) < 0) { n = -n; }
    float3 l = normalize(u.light.xyz);
    float3 l2 = normalize(float3(-0.6, 0.3, -0.5));
    float diff = max(dot(n, l), 0.0);
    float fill = max(dot(n, l2), 0.0) * 0.25;
    float3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.35;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.45;
    float3 col = in.c.rgb * (0.32 + 0.62 * diff + fill) + spec + rim * float3(0.35, 0.65, 1.0);
    return float4(col, in.c.a);
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
    var light: SIMD4<Float>
    var eye: SIMD4<Float>
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
