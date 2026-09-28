import Foundation
import Metal
import MilkDropCore

struct MilkDropShaderUniforms {
    var aspect = SIMD4<Float>(1, 1, 1, 1)
    var texsize = SIMD4<Float>(1, 1, 1, 1)
    var audio = SIMD4<Float>(repeating: 0)
    var audioAtt = SIMD4<Float>(repeating: 0)
    var timing = SIMD4<Float>(repeating: 0)
    var randFrame = SIMD4<Float>(repeating: 0)
    var randPreset = SIMD4<Float>(repeating: 0)
    var texsizeNoiseLQ = SIMD4<Float>(256, 256, 1.0 / 256, 1.0 / 256)
    var texsizeNoiseMQ = SIMD4<Float>(256, 256, 1.0 / 256, 1.0 / 256)
    var texsizeNoiseHQ = SIMD4<Float>(256, 256, 1.0 / 256, 1.0 / 256)
    var texsizeNoiseVolLQ = SIMD4<Float>(32, 32, 1.0 / 32, 1.0 / 32)
    var texsizeNoiseVolHQ = SIMD4<Float>(32, 32, 1.0 / 32, 1.0 / 32)
    var hue0 = SIMD4<Float>(1, 1, 1, 1); var hue1 = SIMD4<Float>(1, 1, 1, 1)
    var hue2 = SIMD4<Float>(1, 1, 1, 1); var hue3 = SIMD4<Float>(1, 1, 1, 1)
    var q0 = SIMD4<Float>(repeating: 0); var q1 = SIMD4<Float>(repeating: 0)
    var q2 = SIMD4<Float>(repeating: 0); var q3 = SIMD4<Float>(repeating: 0)
    var q4 = SIMD4<Float>(repeating: 0); var q5 = SIMD4<Float>(repeating: 0)
    var q6 = SIMD4<Float>(repeating: 0); var q7 = SIMD4<Float>(repeating: 0)
}

/// Strict, cached runtime compiler for the first unambiguous MilkDrop composite-shader tier.
/// Unsupported source returns a diagnostic and the renderer keeps its native composite fallback.
final class TranslatedShaderPipeline {
    enum Result {
        case pipeline(MTLRenderPipelineState)
        case unsupported(String)
    }

    private let device: MTLDevice
    private let pixelFormat: MTLPixelFormat
    private let translator = HLSLToMSLTranslator()
    private var cache: [String: Result] = [:]
    let sampler: MTLSamplerState
    let wrapSampler: MTLSamplerState
    let pointClampSampler: MTLSamplerState
    let pointWrapSampler: MTLSamplerState
    let noiseLQ: MTLTexture
    let noiseMQ: MTLTexture
    let noiseHQ: MTLTexture
    let noiseVolLQ: MTLTexture
    let noiseVolHQ: MTLTexture

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        precondition(MemoryLayout<MilkDropShaderUniforms>.stride == 384, "MilkDrop shader uniform ABI must remain 24 packed float4 values")
        self.device = device
        self.pixelFormat = pixelFormat
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: descriptor)!
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        self.wrapSampler = device.makeSamplerState(descriptor: descriptor)!
        descriptor.minFilter = .nearest; descriptor.magFilter = .nearest
        descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
        self.pointClampSampler = device.makeSamplerState(descriptor: descriptor)!
        descriptor.sAddressMode = .repeat; descriptor.tAddressMode = .repeat
        self.pointWrapSampler = device.makeSamplerState(descriptor: descriptor)!
        self.noiseLQ = Self.makeNoiseTexture(device: device, size: 256, zoom: 1)!
        self.noiseMQ = Self.makeNoiseTexture(device: device, size: 256, zoom: 4)!
        self.noiseHQ = Self.makeNoiseTexture(device: device, size: 256, zoom: 8)!
        self.noiseVolLQ = Self.makeNoiseVolume(device: device, size: 32, zoom: 1)!
        self.noiseVolHQ = Self.makeNoiseVolume(device: device, size: 32, zoom: 4)!
    }

    func composite(for source: String) -> Result {
        compile(source, vertexName: "milkdrop_fullscreen_vertex", cacheKey: "composite:\(source)", composite: true)
    }

    func warp(for source: String) -> Result {
        compile(source, vertexName: "milkdrop_mesh_vertex", cacheKey: "warp:\(source)", composite: false)
    }

    private func compile(_ source: String, vertexName: String, cacheKey: String, composite: Bool) -> Result {
        if let cached = cache[cacheKey] { return cached }
        let result: Result
        do {
            let fragmentSource = try translator.translateFragment(source, composite: composite)
            let librarySource = fragmentSource + "\n" + Self.vertexSource
            let library = try device.makeLibrary(source: librarySource, options: nil)
            guard let vertex = library.makeFunction(name: vertexName),
                  let fragment = library.makeFunction(name: "milkdrop_fragment") else {
                result = .unsupported("translated Metal entry point missing")
                cache[cacheKey] = result
                return result
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            result = .pipeline(try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            result = .unsupported(String(describing: error))
        }
        cache[cacheKey] = result
        return result
    }

    private static let vertexSource = """
    vertex MilkDropRasterData milkdrop_fullscreen_vertex(uint id [[vertex_id]]) {
        float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        MilkDropRasterData o;
        o.position = float4(p[id], 0, 1);
        o.uv = float2((p[id].x + 1.0) * 0.5, 1.0 - (p[id].y + 1.0) * 0.5);
        o.uv_orig = o.uv;
        return o;
    }
    struct MilkDropWarpVertex { float2 position; float2 uv; float2 uv_orig; };
    vertex MilkDropRasterData milkdrop_mesh_vertex(uint id [[vertex_id]], const device MilkDropWarpVertex* vertices [[buffer(2)]]) {
        MilkDropRasterData o;
        o.position = float4(vertices[id].position.x, -vertices[id].position.y, 0, 1);
        o.uv = vertices[id].uv;
        o.uv_orig = vertices[id].uv_orig;
        return o;
    }
    """

    private static func makeNoiseTexture(device: MTLDevice, size: Int, zoom: Int) -> MTLTexture? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let range = zoom > 1 ? 216 : 256
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: Int.random(in: 0..<range) + range / 2) }
        if zoom > 1 {
            func cubic(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> UInt8 {
                let a0 = y3 - y2 - y0 + y1, a1 = y0 - y1 - a0, a2 = y2 - y0
                return UInt8(clamping: Int((a0*t*t*t + a1*t*t + a2*t + y1).rounded()))
            }
            for y in stride(from: 0, to: size, by: zoom) {
                for x in 0..<size where x % zoom != 0 {
                    let base = (x / zoom) * zoom
                    let t = Float(x % zoom) / Float(zoom)
                    for c in 0..<4 {
                        func sample(_ sx: Int) -> Float { Float(bytes[(y * size + (sx + size) % size) * 4 + c]) }
                        bytes[(y * size + x) * 4 + c] = cubic(sample(base-zoom), sample(base), sample(base+zoom), sample(base+2*zoom), t)
                    }
                }
            }
            for x in 0..<size {
                for y in 0..<size where y % zoom != 0 {
                    let base = (y / zoom) * zoom
                    let t = Float(y % zoom) / Float(zoom)
                    for c in 0..<4 {
                        func sample(_ sy: Int) -> Float { Float(bytes[(((sy + size) % size) * size + x) * 4 + c]) }
                        bytes[(y * size + x) * 4 + c] = cubic(sample(base-zoom), sample(base), sample(base+zoom), sample(base+2*zoom), t)
                    }
                }
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)
        return texture
    }

    private static func makeNoiseVolume(device: MTLDevice, size: Int, zoom: Int) -> MTLTexture? {
        var bytes = [UInt8](repeating: 0, count: size * size * size * 4)
        let range = zoom > 1 ? 216 : 256
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: Int.random(in: 0..<range) + range / 2) }
        if zoom > 1 {
            func cubic(_ y0: Float, _ y1: Float, _ y2: Float, _ y3: Float, _ t: Float) -> UInt8 {
                let a0 = y3 - y2 - y0 + y1, a1 = y0 - y1 - a0, a2 = y2 - y0
                return UInt8(clamping: Int((a0*t*t*t + a1*t*t + a2*t + y1).rounded()))
            }
            func offset(_ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Int { (((z * size + y) * size + x) * 4 + c) }
            for z in stride(from: 0, to: size, by: zoom) { for y in stride(from: 0, to: size, by: zoom) { for x in 0..<size where x % zoom != 0 {
                let base = (x / zoom) * zoom, t = Float(x % zoom) / Float(zoom)
                for c in 0..<4 { func s(_ v:Int)->Float { Float(bytes[offset((v+size)%size,y,z,c)]) }; bytes[offset(x,y,z,c)] = cubic(s(base-zoom),s(base),s(base+zoom),s(base+2*zoom),t) }
            } } }
            for z in stride(from: 0, to: size, by: zoom) { for x in 0..<size { for y in 0..<size where y % zoom != 0 {
                let base = (y / zoom) * zoom, t = Float(y % zoom) / Float(zoom)
                for c in 0..<4 { func s(_ v:Int)->Float { Float(bytes[offset(x,(v+size)%size,z,c)]) }; bytes[offset(x,y,z,c)] = cubic(s(base-zoom),s(base),s(base+zoom),s(base+2*zoom),t) }
            } } }
            for y in 0..<size { for x in 0..<size { for z in 0..<size where z % zoom != 0 {
                let base = (z / zoom) * zoom, t = Float(z % zoom) / Float(zoom)
                for c in 0..<4 { func s(_ v:Int)->Float { Float(bytes[offset(x,y,(v+size)%size,c)]) }; bytes[offset(x,y,z,c)] = cubic(s(base-zoom),s(base),s(base+zoom),s(base+2*zoom),t) }
            } } }
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = size; descriptor.height = size; descriptor.depth = size
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: bytes, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        return texture
    }
}
