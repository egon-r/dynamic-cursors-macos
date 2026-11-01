import AppKit
import MetalKit

private struct CursorUniforms {
    var screen, tip, size, hotspot, delta, boundsMin, boundsMax: SIMD2<Float>
    var rotation, stretchAngle, stretch, scale: Float
    var samples, padding: UInt32
}

final class CursorRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private var sprite: MTLTexture?
    private var revision: UInt64?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "DynamicCursors", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"])
        }
        self.device = device
        self.queue = queue
        loader = MTKTextureLoader(device: device)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cursorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cursorFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func updateSprite(_ snapshot: CursorSnapshot) throws {
        guard revision != snapshot.revision else { return }
        sprite = try loader.newTexture(cgImage: snapshot.image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
        revision = snapshot.revision
    }

    private func uniforms(frame: CursorFrame, screen: CGRect) -> CursorUniforms {
        let tip = CGPoint(x: frame.position.x - screen.minX, y: screen.maxY - frame.position.y)
        let delta = CGPoint(x: frame.displacement.x, y: -frame.displacement.y)
        let c = cos(frame.rotation), s = sin(frame.rotation)
        let axis = CGPoint(x: cos(frame.stretchAngle), y: sin(frame.stretchAngle))
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        let squash = 1 - 0.5 * (frame.stretch - 1)
        for corner in 0..<4 {
            let x = corner & 1 == 0 ? 0 : frame.size.width
            let y = corner & 2 == 0 ? 0 : frame.size.height
            var q = CGPoint(x: (x - frame.hotspot.x) * frame.scale, y: (y - frame.hotspot.y) * frame.scale)
            let along = q.x * axis.x + q.y * axis.y
            let across = -q.x * axis.y + q.y * axis.x
            q = CGPoint(x: axis.x * along * frame.stretch - axis.y * across * squash,
                        y: axis.y * along * frame.stretch + axis.x * across * squash)
            let tx = tip.x + c * q.x - s * q.y
            let ty = tip.y + s * q.x + c * q.y
            minX = min(minX, tx, tx - delta.x)
            maxX = max(maxX, tx, tx - delta.x)
            minY = min(minY, ty, ty - delta.y)
            maxY = max(maxY, ty, ty - delta.y)
        }
        return CursorUniforms(
            screen: SIMD2(Float(screen.width), Float(screen.height)),
            tip: SIMD2(Float(tip.x), Float(tip.y)),
            size: SIMD2(Float(frame.size.width), Float(frame.size.height)),
            hotspot: SIMD2(Float(frame.hotspot.x), Float(frame.hotspot.y)),
            delta: SIMD2(Float(delta.x), Float(delta.y)),
            boundsMin: SIMD2(Float(minX - 2), Float(minY - 2)),
            boundsMax: SIMD2(Float(maxX + 2), Float(maxY + 2)),
            rotation: Float(frame.rotation), stretchAngle: Float(frame.stretchAngle),
            stretch: Float(frame.stretch), scale: Float(frame.scale),
            samples: UInt32(max(1, min(64, frame.samples))), padding: 0)
    }

    @discardableResult
    private func encode(pass: MTLRenderPassDescriptor, frame: CursorFrame?, screen: CGRect, command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let frame, let sprite {
            var uniforms = uniforms(frame: frame, screen: screen)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CursorUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CursorUniforms>.stride, index: 0)
            encoder.setFragmentTexture(sprite, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return true
    }

    func draw(view: MTKView, frame: CursorFrame?, screen: CGRect) -> Bool {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return false }
        guard encode(pass: pass, frame: frame, screen: screen, command: command) else { return false }
        command.present(drawable)
        command.commit()
        return true
    }

    // Uses the same graphics pipeline as the live overlays, not a second renderer.
    func export(frame: CursorFrame, screen: CGRect, to url: URL) throws {
        let width = Int(screen.width), height = Int(screen.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw NSError(domain: "DynamicCursors", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate render capture"])
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard encode(pass: pass, frame: frame, screen: screen, command: command) else {
            throw NSError(domain: "DynamicCursors", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot encode render capture"])
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float2 screen, tip, size, hotspot, delta, boundsMin, boundsMax;
        float rotation, stretchAngle, stretch, scale;
        uint samples, padding;
    };
    struct Vertex { float4 position [[position]]; float2 point; };
    vertex Vertex cursorVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        float2 corner = float2(id & 1, (id >> 1) & 1);
        float2 point = mix(u.boundsMin, u.boundsMax, corner);
        Vertex v;
        v.position = float4(point.x / u.screen.x * 2.0 - 1.0, 1.0 - point.y / u.screen.y * 2.0, 0, 1);
        v.point = point;
        return v;
    }
    fragment float4 cursorFragment(Vertex v [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> sprite [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        float c = cos(u.rotation), s = sin(u.rotation);
        float2 axis = float2(cos(u.stretchAngle), sin(u.stretchAngle));
        float4 accumulated = float4(0);
        for (uint i = 0; i < 64; ++i) {
            if (i >= u.samples) break;
            float2 q = v.point - u.tip + u.delta * (float(i) / float(u.samples));
            q = float2(c * q.x + s * q.y, -s * q.x + c * q.y);
            float along = dot(q, axis) / u.stretch;
            float across = dot(q, float2(-axis.y, axis.x)) / (1.0 - 0.5 * (u.stretch - 1.0));
            q = axis * along + float2(-axis.y, axis.x) * across;
            float2 uv = (q / u.scale + u.hotspot) / u.size;
            if (any(uv < 0.0) || any(uv > 1.0)) continue;
            accumulated += sprite.sample(linearSampler, uv);
        }
        return accumulated / float(u.samples);
    }
    """
}
