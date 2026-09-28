import Foundation
import Metal
import MilkDropCore

private struct MilkGeometryVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var uv: SIMD2<Float>
    var textured: Float
}

private struct ShapeRuntime {
    var frame: EELEngine?
    var variables: [String: Double]
    var initialT: [Double]
}

private struct WaveRuntime {
    var frame: EELEngine?
    var point: EELEngine?
    var variables: [String: Double]
    var pointVariables: [String: Double]
    var initialT: [Double]
}

/// Native Metal implementation of MilkDrop's authored custom shape and custom wave stages.
final class MilkGeometryRenderer {
    private let alphaPipeline: MTLRenderPipelineState
    private let additivePipeline: MTLRenderPipelineState
    private var preset: MilkPreset
    private var shapes: [ShapeRuntime] = []
    private var waves: [WaveRuntime] = []

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, preset: MilkPreset) throws {
        self.preset = preset
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        func makePipeline(additive: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "milkGeometryVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "milkGeometryFragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        alphaPipeline = try makePipeline(additive: false)
        additivePipeline = try makePipeline(additive: true)
        try load(preset)
    }

    func load(_ preset: MilkPreset) throws {
        self.preset = preset
        shapes = try preset.customShapes.map { shape in
            var variables = shapeVariables(shape)
            if !shape.initEquations.isEmpty {
                let program = try EELEngine(source: shape.initEquations)
                try program.execute(variables: &variables)
            }
            return ShapeRuntime(
                frame: shape.perFrameEquations.isEmpty ? nil : try EELEngine(source: shape.perFrameEquations),
                variables: variables,
                initialT: (1...8).map { variables["t\($0)"] ?? 0 })
        }
        waves = try preset.customWaves.map { wave in
            var variables = waveVariables(wave)
            if !wave.initEquations.isEmpty {
                let program = try EELEngine(source: wave.initEquations)
                try program.execute(variables: &variables)
            }
            return WaveRuntime(
                frame: wave.perFrameEquations.isEmpty ? nil : try EELEngine(source: wave.perFrameEquations),
                point: wave.perPointEquations.isEmpty ? nil : try EELEngine(source: wave.perPointEquations),
                variables: variables,
                pointVariables: [:],
                initialT: (1...8).map { variables["t\($0)"] ?? 0 })
        }
    }

    func draw(command: MTLCommandBuffer, target: MTLTexture, source: MTLTexture,
              audio: AudioSnapshot, q: [String: Double], time: Double, fps: Double, frame: Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setFragmentTexture(source, index: 0)
        drawShapes(encoder, audio: audio, q: q, time: time, fps: fps, frame: frame)
        drawBuiltInWave(encoder, audio: audio, q: q, time: time)
        drawWaves(encoder, audio: audio, q: q, time: time, fps: fps, frame: frame)
        encoder.endEncoding()
    }

    private func drawShapes(_ encoder: MTLRenderCommandEncoder, audio: AudioSnapshot,
                            q: [String: Double], time: Double, fps: Double, frame: Int) {

        for index in preset.customShapes.indices where preset.customShapes[index].enabled && index < shapes.count {
            let authored = preset.customShapes[index]
            let count = MilkDropGeometryExecution.instanceCount(authored.instances)
            for instance in 0..<count {
                var runtime = shapes[index]
                var variables = runtime.variables
                MilkDropGeometryExecution.refresh(shapeVariables(authored), in: &variables)
                for t in 1...8 { variables["t\(t)"] = runtime.initialT[t - 1] }
                common(&variables, audio: audio, q: q, time: time, fps: fps, frame: frame)
                variables["instance"] = Double(instance)
                variables["instances"] = Double(count)
                do { try runtime.frame?.execute(variables: &variables) }
                catch { continue }
                runtime.variables = variables
                shapes[index] = runtime

                let sides = max(3, min(Int(variables["sides"] ?? Double(authored.sides)), 100))
                let x = Float(variables["x"] ?? 0.5) * 2 - 1
                let y = 1 - Float(variables["y"] ?? 0.5) * 2
                let radius = Float(variables["rad"] ?? Double(authored.radius))
                let angle = Float(variables["ang"] ?? Double(authored.angle))
                let inner = color(variables, prefix: "", fallback: authored.innerColor)
                let outer = color(variables, prefix: "2", fallback: authored.outerColor)

                let isTextured = (variables["textured"] ?? (authored.textured ? 1 : 0)) != 0
                let textureAngle = Float(variables["tex_ang"] ?? Double(authored.textureAngle))
                let textureZoom = max(Float(variables["tex_zoom"] ?? Double(authored.textureZoom)), 0.001)
                var vertices = [MilkGeometryVertex(position: SIMD2(x, y), color: inner,
                                                   uv: SIMD2(0.5, 0.5), textured: isTextured ? 1 : 0)]
                for side in 0...sides {
                    let t = Float(side % sides) / Float(sides)
                    let a = t * 2 * .pi + angle + .pi * 0.25
                    let ta = t * 2 * .pi + textureAngle + .pi * 0.25
                    vertices.append(MilkGeometryVertex(
                        position: SIMD2(x + radius * cos(a), y + radius * sin(a)), color: outer,
                        uv: SIMD2(0.5 + 0.5 * cos(ta) / textureZoom,
                                  0.5 - 0.5 * sin(ta) / textureZoom), textured: isTextured ? 1 : 0))
                }
                encoder.setRenderPipelineState((variables["additive"] ?? (authored.additive ? 1 : 0)) != 0 ? additivePipeline : alphaPipeline)
                var triangles: [MilkGeometryVertex] = []
                triangles.reserveCapacity(sides * 3)
                for side in 1...sides {
                    triangles.append(vertices[0]); triangles.append(vertices[side]); triangles.append(vertices[side + 1])
                }
                send(triangles, to: encoder)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)

                let border = SIMD4(Float(variables["border_r"] ?? Double(authored.borderColor.x)),
                                   Float(variables["border_g"] ?? Double(authored.borderColor.y)),
                                   Float(variables["border_b"] ?? Double(authored.borderColor.z)),
                                   Float(variables["border_a"] ?? Double(authored.borderColor.w)))
                if border.w > 0 {
                    let outline = vertices.dropFirst().map { MilkGeometryVertex(position: $0.position, color: border, uv: .zero, textured: 0) }
                    send(outline, to: encoder)
                    encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: outline.count)
                }
            }
        }

    }

    private func drawWaves(_ encoder: MTLRenderCommandEncoder, audio: AudioSnapshot,
                           q: [String: Double], time: Double, fps: Double, frame: Int) {
        guard !audio.waveform.isEmpty else { return }
        for index in preset.customWaves.indices where preset.customWaves[index].enabled && index < waves.count {
            let authored = preset.customWaves[index]
            var runtime = waves[index]
            var variables = runtime.variables
            MilkDropGeometryExecution.refresh(waveVariables(authored), in: &variables)
            for t in 1...8 { variables["t\(t)"] = runtime.initialT[t - 1] }
            common(&variables, audio: audio, q: q, time: time, fps: fps, frame: frame)
            do { try runtime.frame?.execute(variables: &variables) }
            catch { continue }
            runtime.variables = variables
            waves[index] = runtime

            let sampleCount = max(authored.dots ? 1 : 2,
                                  min(Int(variables["samples"] ?? Double(authored.samples)), 512))
            var vertices: [MilkGeometryVertex] = []
            vertices.reserveCapacity(sampleCount)
            var point = runtime.pointVariables
            var pointFrameInputs: [String: Double] = [:]
            for name in ["time", "fps", "frame", "progress", "bass", "mid", "treb", "bass_att", "mid_att", "treb_att"] {
                pointFrameInputs[name] = variables[name] ?? 0
            }
            for q in 1...32 { pointFrameInputs["q\(q)"] = variables["q\(q)"] ?? 0 }
            for t in 1...8 { pointFrameInputs["t\(t)"] = variables["t\(t)"] ?? 0 }
            MilkDropGeometryExecution.refresh(pointFrameInputs, in: &point)
            for sample in 0..<sampleCount {
                let normalized = sampleCount > 1 ? Double(sample) / Double(sampleCount - 1) : 0
                let sourceIndex = min(Int(normalized * Double(audio.waveform.count - 1)), audio.waveform.count - 1)
                let value = Double(audio.waveform[sourceIndex]) * Double(authored.scaling)
                point["sample"] = normalized
                point["value1"] = value
                point["value2"] = value
                point["x"] = 0.5 + value
                point["y"] = 0.5 + value
                point["r"] = variables["r"] ?? Double(authored.color.x)
                point["g"] = variables["g"] ?? Double(authored.color.y)
                point["b"] = variables["b"] ?? Double(authored.color.z)
                point["a"] = variables["a"] ?? Double(authored.color.w)
                do { try runtime.point?.execute(variables: &point) }
                catch { continue }
                vertices.append(MilkGeometryVertex(
                    position: SIMD2(Float(point["x"] ?? 0.5) * 2 - 1,
                                    1 - Float(point["y"] ?? 0.5) * 2),
                    color: SIMD4(Float(point["r"] ?? Double(authored.color.x)),
                                 Float(point["g"] ?? Double(authored.color.y)),
                                 Float(point["b"] ?? Double(authored.color.z)),
                                 Float(point["a"] ?? Double(authored.color.w))),
                    uv: .zero, textured: 0))
            }
            runtime.pointVariables = point
            waves[index] = runtime
            guard !vertices.isEmpty else { continue }
            encoder.setRenderPipelineState(authored.additive ? additivePipeline : alphaPipeline)
            send(vertices, to: encoder)
            encoder.drawPrimitives(type: authored.dots ? .point : .lineStrip,
                                   vertexStart: 0, vertexCount: vertices.count)
        }
    }

    private func drawBuiltInWave(_ encoder: MTLRenderCommandEncoder, audio: AudioSnapshot,
                                 q: [String: Double], time: Double) {
        guard audio.waveform.count >= 64 else { return }
        let mode = ((Int(q["wave_mode"] ?? Double(preset.waveMode)) % 8) + 8) % 8
        let center = SIMD2(Float(q["wave_x"] ?? Double(preset.wavePosition.x)) * 2 - 1,
                           Float(q["wave_y"] ?? Double(preset.wavePosition.y)) * 2 - 1)
        let mystery = Float(q["wave_mystery"] ?? 0)
        let scale = max(preset.waveScale, 0.001)
        let color = SIMD4(Float(q["wave_r"] ?? Double(preset.waveColor.x)),
                          Float(q["wave_g"] ?? Double(preset.waveColor.y)),
                          Float(q["wave_b"] ?? Double(preset.waveColor.z)),
                          max(0, min(Float(q["wave_a"] ?? Double(preset.waveColor.w)), 1)))
        var authoredColor = color
        if (q["wave_brighten"] ?? (preset.waveBrighten ? 1 : 0)) != 0 {
            let maximum = max(authoredColor.x, max(authoredColor.y, authoredColor.z))
            if maximum > 0.01 { authoredColor.x /= maximum; authoredColor.y /= maximum; authoredColor.z /= maximum }
        }
        guard authoredColor.w >= 0.004 else { return }
        let useDots = (q["wave_usedots"] ?? (preset.waveDots ? 1 : 0)) != 0
        let additive = (q["wave_additive"] ?? (preset.waveAdditive ? 1 : 0)) != 0
        let count = (mode == 0 || mode == 1 || mode >= 6) ? 256 : 512
        func sample(_ index: Int) -> Float {
            audio.waveform[max(0, min(index, audio.waveform.count - 1))] * scale
        }
        var primary: [MilkGeometryVertex] = []
        var secondary: [MilkGeometryVertex] = []
        primary.reserveCapacity(count + 1); secondary.reserveCapacity(count)
        let aspect = Float(720.0 / 1280.0)
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            let a = t * 2 * .pi
            let left = sample(i), right = sample(i + 32)
            let p: SIMD2<Float>
            switch mode {
            case 0:
                let radius = 0.5 + 0.4 * right + mystery
                p = center + SIMD2(radius * cos(a + Float(time) * 0.2) * aspect,
                                   radius * sin(a + Float(time) * 0.2))
            case 1:
                let radius = 0.53 + 0.43 * right + mystery
                let angle = left * 1.57 + Float(time) * 2.3
                p = center + SIMD2(radius * cos(angle) * aspect, radius * sin(angle))
            case 2, 3:
                p = center + SIMD2(right * aspect, left)
            case 4:
                p = center + SIMD2(-1 + 2 * t + sample(i + 25) * 0.44, left * 0.47)
            case 5:
                let shifted = sample(i + 32)
                let x0 = right * shifted + left * sample(i + 64)
                let y0 = right * right - shifted * shifted
                let c = cos(Float(time) * 0.3), s = sin(Float(time) * 0.3)
                p = center + SIMD2((x0 * c - y0 * s) * aspect, x0 * s + y0 * c)
            default:
                let angle = 1.57 * mystery, along = SIMD2(cos(angle), sin(angle))
                let perpendicular = SIMD2(-along.y, along.x)
                let base = along * (-1.1 + 2.2 * t) + perpendicular * center.x
                p = base + perpendicular * left * 0.25
                if mode == 7 {
                    let separation = pow(center.y * 0.5 + 0.5, 2)
                    secondary.append(MilkGeometryVertex(position: base - perpendicular * (right * 0.25 + separation), color: authoredColor, uv: .zero, textured: 0))
                }
            }
            primary.append(MilkGeometryVertex(position: p, color: authoredColor, uv: .zero, textured: 0))
        }
        if mode == 0, let first = primary.first { primary.append(first) }
        encoder.setRenderPipelineState(additive ? additivePipeline : alphaPipeline)
        send(primary, to: encoder)
        encoder.drawPrimitives(type: useDots ? .point : .lineStrip, vertexStart: 0, vertexCount: primary.count)
        if !secondary.isEmpty {
            send(secondary, to: encoder)
            encoder.drawPrimitives(type: useDots ? .point : .lineStrip, vertexStart: 0, vertexCount: secondary.count)
        }
    }

    private func send(_ vertices: [MilkGeometryVertex], to encoder: MTLRenderCommandEncoder) {
        vertices.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                encoder.setVertexBytes(base, length: bytes.count, index: 0)
            }
        }
    }

    private func common(_ variables: inout [String: Double], audio: AudioSnapshot,
                        q: [String: Double], time: Double, fps: Double, frame: Int) {
        variables["time"] = time
        variables["fps"] = fps
        variables["frame"] = Double(frame)
        variables["progress"] = 0
        variables["bass"] = Double(audio.bass)
        variables["mid"] = Double(audio.mid)
        variables["treb"] = Double(audio.treble)
        variables["bass_att"] = Double(audio.bassAttenuated)
        variables["mid_att"] = Double(audio.midAttenuated)
        variables["treb_att"] = Double(audio.trebleAttenuated)
        for index in 1...32 { variables["q\(index)"] = q["q\(index)"] ?? 0 }
    }

    private func shapeVariables(_ shape: CustomShape) -> [String: Double] {
        ["x": Double(shape.position.x), "y": Double(shape.position.y),
         "rad": Double(shape.radius), "ang": Double(shape.angle),
         "tex_ang": Double(shape.textureAngle), "tex_zoom": Double(shape.textureZoom),
         "sides": Double(shape.sides), "additive": shape.additive ? 1 : 0,
         "textured": shape.textured ? 1 : 0, "thick": shape.thickOutline ? 1 : 0,
         "instances": Double(shape.instances),
         "r": Double(shape.innerColor.x), "g": Double(shape.innerColor.y), "b": Double(shape.innerColor.z), "a": Double(shape.innerColor.w),
         "r2": Double(shape.outerColor.x), "g2": Double(shape.outerColor.y), "b2": Double(shape.outerColor.z), "a2": Double(shape.outerColor.w),
         "border_r": Double(shape.borderColor.x), "border_g": Double(shape.borderColor.y),
         "border_b": Double(shape.borderColor.z), "border_a": Double(shape.borderColor.w)]
    }

    private func waveVariables(_ wave: CustomWave) -> [String: Double] {
        ["samples": Double(wave.samples), "r": Double(wave.color.x), "g": Double(wave.color.y),
         "b": Double(wave.color.z), "a": Double(wave.color.w)]
    }

    private func color(_ variables: [String: Double], prefix: String, fallback: SIMD4<Float>) -> SIMD4<Float> {
        let suffix = prefix.isEmpty ? "" : prefix
        return SIMD4(Float(variables["r\(suffix)"] ?? Double(fallback.x)),
                     Float(variables["g\(suffix)"] ?? Double(fallback.y)),
                     Float(variables["b\(suffix)"] ?? Double(fallback.z)),
                     Float(variables["a\(suffix)"] ?? Double(fallback.w)))
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float2 position; float4 color; float2 uv; float textured; };
    struct Out { float4 position [[position]]; float4 color; float2 uv; float textured; float pointSize [[point_size]]; };
    vertex Out milkGeometryVertex(uint id [[vertex_id]], constant Vertex* vertices [[buffer(0)]]) {
        Vertex v=vertices[id]; Out o; o.position=float4(v.position,0,1); o.color=v.color; o.uv=v.uv; o.textured=v.textured; o.pointSize=3.0; return o;
    }
    fragment half4 milkGeometryFragment(Out in [[stage_in]], texture2d<half> feedback [[texture(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float3 rgb=in.color.rgb;
        if(in.textured>0.5) rgb*=float3(feedback.sample(s,in.uv).rgb);
        return half4(half3(rgb),half(in.color.a));
    }
    """
}
