import AppKit
import MetalKit
import MilkDropCore

private struct WarpGPUVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var originalUV: SIMD2<Float>
}

private struct BlurUniforms {
    var texel = SIMD2<Float>(1, 1)
    var direction = SIMD2<Float>(1, 0)
}

private struct Uniforms {
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var delta: Float = 0
    var audio = SIMD4<Float>(0, 0, 0, 0)
    var audioAtt = SIMD4<Float>(0, 0, 0, 0)
    var preset = SIMD4<Float>(0.98, 1, 0, 0)
    var color = SIMD4<Float>(1, 1, 1, 0.8)
    var transform = SIMD4<Float>(0.5, 0.5, 0, 0)
    var flags = SIMD4<UInt32>(0, 0, 0, 0)
    var post = SIMD4<Float>(0, 0, 0, 0)
    var echo = SIMD4<Float>(0, 2, 0, 0)
    var outerBorder = SIMD4<Float>(0, 0, 0, 0)
    var innerBorder = SIMD4<Float>(0, 0, 0, 0)
    var borderSizes = SIMD4<Float>(0, 0, 0, 0)
    var motion = SIMD4<Float>(12, 9, 0, 0)
    var motionColor = SIMD4<Float>(1, 1, 1, 0)
}

final class MilkDropRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let warpPipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLComputePipelineState
    private let translatedShaderPipeline: TranslatedShaderPipeline
    private var translatedComposite: MTLRenderPipelineState?
    private var translatedWarp: MTLRenderPipelineState?
    private var highestTranslatedBlurLevel = 0
    private var presetRandom = SIMD4<Float>(repeating: 0)
    private let huePhase = SIMD4<Float>(
        Float.random(in: 0..<648.41), Float.random(in: 0..<537.51),
        Float.random(in: 0..<426.61), Float.random(in: 0..<315.71))
    private var geometryRenderer: MilkGeometryRenderer!
    private var feedback: [MTLTexture?] = [nil, nil]
    private var geometrySnapshot: MTLTexture?
    private var blur1: MTLTexture?
    private var blur2: MTLTexture?
    private var blur3: MTLTexture?
    private var blurScratch: [MTLTexture?] = [nil, nil, nil]
    private var allocatedDrawableSize = CGSize.zero
    private var feedbackIndex = 0
    private var feedbackInitialized = false
    private var started = CACurrentMediaTime(), previous = CACurrentMediaTime()
    private var presetStarted = CACurrentMediaTime()
    private var frameCount = 0
    private var totalFrameCount = 0
    private var lastMeshEvaluation = -Double.infinity
    private let meshEvaluationInterval = 1.0 / 60.0
    private var fpsStarted = CACurrentMediaTime()
    private let analyzer: AudioAnalyzer
    var preset: MilkPreset { didSet { compilePresetPrograms() } }
    private var initEngine: EELEngine?
    private var frameEngine: EELEngine?
    private var pixelEngine: EELEngine?
    private var eelVariables: [String: Double] = [:]
    private var initializedQ: [String: Double] = [:]
    private var presetGeneration = 0
    private var lastAudioDiagnostic = CACurrentMediaTime()
    private var lastAudioBands = SIMD3<Float>(repeating: 0)
    private var warpMesh: WarpMesh
    private var warpVertexBuffer: MTLBuffer?
    private var warpIndexBuffer: MTLBuffer?
    private var warpVertices: [WarpGPUVertex] = []
    var onPerformance: ((String) -> Void)?

    init?(view: MTKView, analyzer: AudioAnalyzer, preset: MilkPreset) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device; self.queue = queue; self.analyzer = analyzer; self.preset = preset

        self.warpMesh = WarpMesh(width: 1280, height: 720)
        self.warpVertices = warpMesh.vertices.map { WarpGPUVertex(position: $0.position, uv: $0.uv, originalUV: $0.originalUV) }
        self.warpVertexBuffer = device.makeBuffer(bytes: warpVertices, length: warpVertices.count * MemoryLayout<WarpGPUVertex>.stride, options: .storageModeShared)
        self.warpIndexBuffer = device.makeBuffer(bytes: warpMesh.indices, length: warpMesh.indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        view.device = device
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        if let layer = view.layer as? CAMetalLayer {
            layer.maximumDrawableCount = 3
            layer.displaySyncEnabled = true
            layer.presentsWithTransaction = false
        }
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "milkdropFragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let warpDescriptor = MTLRenderPipelineDescriptor()
            warpDescriptor.vertexFunction = library.makeFunction(name: "warpVertex")
            warpDescriptor.fragmentFunction = library.makeFunction(name: "warpFragment")
            warpDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            self.warpPipeline = try device.makeRenderPipelineState(descriptor: warpDescriptor)
            let displayDescriptor = MTLRenderPipelineDescriptor()
            displayDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            displayDescriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
            displayDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            self.displayPipeline = try device.makeRenderPipelineState(descriptor: displayDescriptor)
            guard let blurFunction = library.makeFunction(name: "blurKernel") else { return nil }
            self.blurPipeline = try device.makeComputePipelineState(function: blurFunction)
        self.translatedShaderPipeline = TranslatedShaderPipeline(device: device, pixelFormat: view.colorPixelFormat)
        } catch { fputs("Metal shader error: \(error)\n", stderr); return nil }
        super.init(); view.delegate = self
        do { geometryRenderer = try MilkGeometryRenderer(device: device, pixelFormat: .rgba16Float, preset: preset) }
        catch { RuntimeLog.write("GEOMETRY INIT ERROR • \(error.localizedDescription)"); return nil }
        compilePresetPrograms()
    }

    private func compilePresetPrograms() {
        presetGeneration += 1
        presetStarted = CACurrentMediaTime()
        lastMeshEvaluation = -Double.infinity
        eelVariables = [:]
        initializedQ = [:]
        translatedComposite = nil
        translatedWarp = nil
        highestTranslatedBlurLevel = 0
        presetRandom = SIMD4(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
        if !preset.compositeShader.isEmpty {
            switch translatedShaderPipeline.composite(for: preset.compositeShader) {
            case let .pipeline(pipeline):
                translatedComposite = pipeline
                highestTranslatedBlurLevel = max(highestTranslatedBlurLevel, Self.blurLevel(in: preset.compositeShader))
                RuntimeLog.write("COMPOSITE MSL READY • \(preset.name)")
            case let .unsupported(reason):
                RuntimeLog.write("COMPOSITE MSL FALLBACK • \(preset.name) • \(reason)")
            }
        }
        if !preset.warpShader.isEmpty {
            switch translatedShaderPipeline.warp(for: preset.warpShader) {
            case let .pipeline(pipeline):
                translatedWarp = pipeline
                highestTranslatedBlurLevel = max(highestTranslatedBlurLevel, Self.blurLevel(in: preset.warpShader))
                RuntimeLog.write("WARP MSL READY • \(preset.name)")
            case let .unsupported(reason):
                RuntimeLog.write("WARP MSL FALLBACK • \(preset.name) • \(reason)")
            }
        }
        do {
            try geometryRenderer?.load(preset)
            initEngine = preset.perFrameInitEquations.isEmpty ? nil : try EELEngine(source: preset.perFrameInitEquations)
            frameEngine = preset.perFrameEquations.isEmpty ? nil : try EELEngine(source: preset.perFrameEquations)
            pixelEngine = preset.perPixelEquations.isEmpty ? nil : try EELEngine(source: preset.perPixelEquations)
            seedPresetVariables(audio: .silence, time: 0, fps: 120, frame: 0, resetPresetState: true)
            try initEngine?.execute(variables: &eelVariables)
            for index in 1...32 { initializedQ["q\(index)"] = eelVariables["q\(index)"] ?? 0 }
            let echoDiagnostic = String(format: "%.2f", preset.videoEchoAlpha)
            let borderDiagnostic = String(format: "%.3f/%.3f", preset.outerBorderSize, preset.innerBorderSize)
            RuntimeLog.write("PRESET EEL READY • \(preset.name) • init \(initEngine == nil ? 0 : 1) • frame \(frameEngine == nil ? 0 : 1) • pixel \(pixelEngine == nil ? 0 : 1) • shaders \((preset.warpShader.isEmpty && preset.compositeShader.isEmpty) ? 0 : 1) • wave \(preset.waveMode) • echo \(echoDiagnostic) • borders \(borderDiagnostic)")
        } catch {
            initEngine = nil; frameEngine = nil
            RuntimeLog.write("PRESET EEL UNSUPPORTED • \(preset.name) • \(error.localizedDescription)")
        }
    }

    private func seedPresetVariables(audio: AudioSnapshot, time: Double, fps: Double, frame: Int, resetPresetState: Bool = false) {
        let base: [String: Double] = [
            "time": time, "fps": fps, "frame": Double(frame), "progress": 0,
            "bass": Double(audio.bass), "mid": Double(audio.mid), "treb": Double(audio.treble),
            "bass_att": Double(audio.bassAttenuated), "mid_att": Double(audio.midAttenuated), "treb_att": Double(audio.trebleAttenuated),
            "zoom": Double(preset.zoom), "zoomexp": Double(preset.zoomExponent), "rot": Double(preset.rotation), "warp": Double(preset.warp),
            "cx": Double(preset.center.x), "cy": Double(preset.center.y), "dx": Double(preset.translation.x), "dy": Double(preset.translation.y),
            "sx": Double(preset.stretch.x), "sy": Double(preset.stretch.y), "decay": Double(preset.decay),
            "wave_r": Double(preset.waveColor.x), "wave_g": Double(preset.waveColor.y), "wave_b": Double(preset.waveColor.z), "wave_a": Double(preset.waveColor.w),
            "wave_x": Double(preset.wavePosition.x), "wave_y": Double(preset.wavePosition.y), "wave_mode": Double(preset.waveMode), "wave_mystery": Double(preset.waveMystery),
            "wave_usedots": preset.waveDots ? 1 : 0, "wave_thick": preset.waveThick ? 1 : 0,
            "wave_additive": preset.waveAdditive ? 1 : 0, "wave_brighten": preset.waveBrighten ? 1 : 0,
            "ob_size": Double(preset.outerBorderSize), "ob_r": Double(preset.outerBorderColor.x), "ob_g": Double(preset.outerBorderColor.y), "ob_b": Double(preset.outerBorderColor.z), "ob_a": Double(preset.outerBorderColor.w),
            "ib_size": Double(preset.innerBorderSize), "ib_r": Double(preset.innerBorderColor.x), "ib_g": Double(preset.innerBorderColor.y), "ib_b": Double(preset.innerBorderColor.z), "ib_a": Double(preset.innerBorderColor.w),
            "mv_x": Double(preset.motionVectorGrid.x), "mv_y": Double(preset.motionVectorGrid.y), "mv_dx": Double(preset.motionVectorOffset.x), "mv_dy": Double(preset.motionVectorOffset.y), "mv_l": Double(preset.motionVectorLength),
            "mv_r": Double(preset.motionVectorColor.x), "mv_g": Double(preset.motionVectorColor.y), "mv_b": Double(preset.motionVectorColor.z), "mv_a": Double(preset.motionVectorColor.w),
            "echo_zoom": Double(preset.videoEchoZoom), "echo_alpha": Double(preset.videoEchoAlpha), "echo_orient": Double(preset.videoEchoOrientation),
            "darken_center": preset.darkenCenter ? 1 : 0, "gamma": Double(preset.gamma), "shader": Double(preset.hueShader), "wrap": preset.wrap ? 1 : 0,
            "invert": preset.invert ? 1 : 0, "brighten": preset.brighten ? 1 : 0, "darken": preset.darken ? 1 : 0, "solarize": preset.solarize ? 1 : 0
        ]
        for (key, value) in base { eelVariables[key] = value }
        for q in 1...32 where eelVariables["q\(q)"] == nil { eelVariables["q\(q)"] = 0 }
    }

    func configureDisplay(view: MTKView, screen: NSScreen) {
        let maximumFPS = max(screen.maximumFramesPerSecond, 60)
        view.preferredFramesPerSecond = min(120, maximumFPS)
        view.colorspace = screen.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = view.colorspace
            layer.wantsExtendedDynamicRangeContent = screen.maximumExtendedDynamicRangeColorComponentValue > 1
            layer.maximumDrawableCount = 3
            layer.displaySyncEnabled = true
            layer.presentsWithTransaction = false
        }
        RuntimeLog.write(String(format: "DISPLAY %@ • max %d Hz • EDR %.2fx • requested %d FPS",
                                screen.localizedName, maximumFPS,
                                screen.maximumExtendedDynamicRangeColorComponentValue,
                                view.preferredFramesPerSecond))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { makeFeedback(size: size) }

    func draw(in view: MTKView) {
        autoreleasepool {
            guard let drawable = view.currentDrawable, let displayPass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer() else { return }
            if feedback[0] == nil || allocatedDrawableSize != view.drawableSize { makeFeedback(size: view.drawableSize) }
            guard let source = feedback[feedbackIndex], let target = feedback[1 - feedbackIndex] else { return }
            let now = CACurrentMediaTime(), audio = analyzer.snapshot()
            if now - lastAudioDiagnostic >= 2 {
                let bands = SIMD3(audio.bass, audio.mid, audio.treble)
                RuntimeLog.write(String(format: "AUDIO RENDER BANDS • bass %.4f mid %.4f treb %.4f delta %.4f", bands.x, bands.y, bands.z, length(bands - lastAudioBands)))
                lastAudioBands = bands; lastAudioDiagnostic = now
            }
            if !feedbackInitialized {
                for texture in [source, target] {
                    let clear = MTLRenderPassDescriptor()
                    clear.colorAttachments[0].texture = texture
                    clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                    clear.colorAttachments[0].storeAction = .store
                    command.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                }
                feedbackInitialized = true
            }
            let measuredFPS = previous < now ? 1.0 / max(now - previous, 1.0 / 240.0) : 120
            seedPresetVariables(audio: audio, time: now - started, fps: measuredFPS, frame: totalFrameCount)
            for (key, value) in initializedQ { eelVariables[key] = value }
            do { try frameEngine?.execute(variables: &eelVariables) }
            catch { RuntimeLog.write("PRESET EEL RUNTIME • \(preset.name) • \(error.localizedDescription)"); frameEngine = nil }
            if (pixelEngine != nil || translatedWarp != nil), now - lastMeshEvaluation >= meshEvaluationInterval {
                do {
                    var motion = WarpMesh.Motion()
                    motion.zoom = Float(eelVariables["zoom"] ?? Double(preset.zoom))
                    motion.zoomExponent = Float(eelVariables["zoomexp"] ?? Double(preset.zoomExponent))
                    motion.rotation = Float(eelVariables["rot"] ?? Double(preset.rotation))
                    motion.center = SIMD2(Float(eelVariables["cx"] ?? Double(preset.center.x)), Float(eelVariables["cy"] ?? Double(preset.center.y)))
                    motion.translation = SIMD2(Float(eelVariables["dx"] ?? Double(preset.translation.x)), Float(eelVariables["dy"] ?? Double(preset.translation.y)))
                    motion.stretch = SIMD2(Float(eelVariables["sx"] ?? Double(preset.stretch.x)), Float(eelVariables["sy"] ?? Double(preset.stretch.y)))
                    motion.warp = Float(eelVariables["warp"] ?? Double(preset.warp))
                    let evaluated = try warpMesh.evaluateConcurrent(perPixel: pixelEngine, variables: eelVariables, motion: motion)
                    for index in evaluated.indices {
                        warpVertices[index].position = evaluated[index].position
                        warpVertices[index].uv = evaluated[index].uv
                        warpVertices[index].originalUV = evaluated[index].originalUV
                    }
                    warpVertexBuffer?.contents().copyMemory(from: warpVertices, byteCount: warpVertices.count * MemoryLayout<WarpGPUVertex>.stride)
                    lastMeshEvaluation = now
                } catch { RuntimeLog.write("PRESET PIXEL RUNTIME • \(preset.name) • \(error.localizedDescription)") }
            }
            var u = Uniforms()
            u.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            u.time = Float(now - started); u.delta = Float(min(now - previous, 0.1)); previous = now
            u.audio = SIMD4(audio.bass, audio.mid, audio.treble, audio.peak)
            u.audioAtt = SIMD4(audio.bassAttenuated, audio.midAttenuated, audio.trebleAttenuated, 0)
            u.preset = SIMD4(Float(eelVariables["decay"] ?? Double(preset.decay)), Float(eelVariables["zoom"] ?? Double(preset.zoom)), Float(eelVariables["rot"] ?? Double(preset.rotation)), Float(eelVariables["warp"] ?? Double(preset.warp)))
            u.color = SIMD4(Float(eelVariables["wave_r"] ?? Double(preset.waveColor.x)), Float(eelVariables["wave_g"] ?? Double(preset.waveColor.y)), Float(eelVariables["wave_b"] ?? Double(preset.waveColor.z)), Float(eelVariables["wave_a"] ?? Double(preset.waveColor.w)))
            u.transform = SIMD4(Float(eelVariables["cx"] ?? Double(preset.center.x)), Float(eelVariables["cy"] ?? Double(preset.center.y)), Float(eelVariables["dx"] ?? Double(preset.translation.x)), Float(eelVariables["dy"] ?? Double(preset.translation.y)))
            u.flags = SIMD4((eelVariables["wrap"] ?? 0) != 0 ? 1 : 0, (eelVariables["invert"] ?? 0) != 0 ? 1 : 0, (eelVariables["solarize"] ?? 0) != 0 ? 1 : 0, (eelVariables["brighten"] ?? 0) != 0 ? 1 : 0)
            u.post = SIMD4((eelVariables["darken"] ?? 0) != 0 ? 1 : 0, Float(eelVariables["gamma"] ?? Double(preset.gamma)), (eelVariables["darken_center"] ?? 0) != 0 ? 1 : 0, Float(eelVariables["shader"] ?? Double(preset.hueShader)))
            u.echo = SIMD4(Float(eelVariables["echo_alpha"] ?? Double(preset.videoEchoAlpha)), Float(eelVariables["echo_zoom"] ?? Double(preset.videoEchoZoom)), Float(eelVariables["echo_orient"] ?? Double(preset.videoEchoOrientation)), 0)
            u.outerBorder = SIMD4(Float(eelVariables["ob_r"] ?? 0), Float(eelVariables["ob_g"] ?? 0), Float(eelVariables["ob_b"] ?? 0), Float(eelVariables["ob_a"] ?? 0))
            u.innerBorder = SIMD4(Float(eelVariables["ib_r"] ?? 0), Float(eelVariables["ib_g"] ?? 0), Float(eelVariables["ib_b"] ?? 0), Float(eelVariables["ib_a"] ?? 0))
            u.borderSizes = SIMD4(Float(eelVariables["ob_size"] ?? 0), Float(eelVariables["ib_size"] ?? 0), 0, 0)
            u.motion = SIMD4(Float(eelVariables["mv_x"] ?? 12), Float(eelVariables["mv_y"] ?? 9), Float(eelVariables["mv_dx"] ?? 0), Float(eelVariables["mv_dy"] ?? 0))
            u.motionColor = SIMD4(Float(eelVariables["mv_r"] ?? 1), Float(eelVariables["mv_g"] ?? 1), Float(eelVariables["mv_b"] ?? 1), Float(eelVariables["mv_a"] ?? 0))
            let aspectX: Float = view.drawableSize.height > view.drawableSize.width ? Float(view.drawableSize.width / view.drawableSize.height) : 1
            let aspectY: Float = view.drawableSize.width > view.drawableSize.height ? Float(view.drawableSize.height / view.drawableSize.width) : 1
            var shaderUniforms = MilkDropShaderUniforms()
            shaderUniforms.aspect = SIMD4(aspectX, aspectY, 1 / aspectX, 1 / aspectY)
            shaderUniforms.texsize = SIMD4(Float(target.width), Float(target.height), 1 / Float(target.width), 1 / Float(target.height))
            shaderUniforms.audio = SIMD4(audio.bass, audio.mid, audio.treble, (audio.bass + audio.mid + audio.treble) / 3)
            shaderUniforms.audioAtt = SIMD4(audio.bassAttenuated, audio.midAttenuated, audio.trebleAttenuated, (audio.bassAttenuated + audio.midAttenuated + audio.trebleAttenuated) / 3)
            shaderUniforms.timing = SIMD4(Float(now - presetStarted), Float(measuredFPS), Float(totalFrameCount), 0)
            shaderUniforms.randFrame = SIMD4(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
            shaderUniforms.randPreset = presetRandom
            func hueCorner(_ i: Int) -> SIMD4<Float> {
                let t = Float(now - started)
                var rgb = SIMD3<Float>(
                    0.6 + 0.3 * sin(t * 30 * 0.0143 + 3 + Float(i * 21) + huePhase.w),
                    0.6 + 0.3 * sin(t * 30 * 0.0107 + 1 + Float(i * 13) + huePhase.y),
                    0.6 + 0.3 * sin(t * 30 * 0.0129 + 6 + Float(i * 9) + huePhase.z))
                let maximum = max(rgb.x, max(rgb.y, rgb.z))
                rgb = SIMD3<Float>(repeating: 0.5) + 0.5 * rgb / maximum
                return SIMD4(rgb, 1)
            }
            shaderUniforms.hue0 = hueCorner(0); shaderUniforms.hue1 = hueCorner(1)
            shaderUniforms.hue2 = hueCorner(2); shaderUniforms.hue3 = hueCorner(3)
            func q(_ base: Int) -> SIMD4<Float> { SIMD4((0..<4).map { Float(eelVariables["q\(base + $0)"] ?? 0) }) }
            shaderUniforms.q0=q(1); shaderUniforms.q1=q(5); shaderUniforms.q2=q(9); shaderUniforms.q3=q(13)
            shaderUniforms.q4=q(17); shaderUniforms.q5=q(21); shaderUniforms.q6=q(25); shaderUniforms.q7=q(29)
            let feedbackPass = MTLRenderPassDescriptor()
            feedbackPass.colorAttachments[0].texture = target
            feedbackPass.colorAttachments[0].loadAction = .dontCare
            feedbackPass.colorAttachments[0].storeAction = .store
            guard let feedbackEncoder = command.makeRenderCommandEncoder(descriptor: feedbackPass) else { return }
            if let translatedWarp, let vertices = warpVertexBuffer, let indices = warpIndexBuffer {
                feedbackEncoder.setRenderPipelineState(translatedWarp)
                feedbackEncoder.setVertexBuffer(vertices, offset: 0, index: 2)
                feedbackEncoder.setFragmentBytes(&shaderUniforms, length: MemoryLayout<MilkDropShaderUniforms>.stride, index: 0)
                feedbackEncoder.setFragmentTexture(source, index: 0)
                feedbackEncoder.setFragmentTexture(blur1 ?? source, index: 1)
                feedbackEncoder.setFragmentTexture(blur2 ?? source, index: 2)
                feedbackEncoder.setFragmentTexture(blur3 ?? source, index: 3)
                feedbackEncoder.setFragmentTexture(translatedShaderPipeline.noiseLQ, index: 4)
                feedbackEncoder.setFragmentTexture(translatedShaderPipeline.noiseMQ, index: 5)
                feedbackEncoder.setFragmentTexture(translatedShaderPipeline.noiseHQ, index: 6)
                feedbackEncoder.setFragmentTexture(translatedShaderPipeline.noiseVolLQ, index: 7)
                feedbackEncoder.setFragmentTexture(translatedShaderPipeline.noiseVolHQ, index: 8)
                feedbackEncoder.setFragmentSamplerState(translatedShaderPipeline.sampler, index: 0)
                feedbackEncoder.setFragmentSamplerState(translatedShaderPipeline.wrapSampler, index: 1)
                feedbackEncoder.setFragmentSamplerState(translatedShaderPipeline.pointClampSampler, index: 2)
                feedbackEncoder.setFragmentSamplerState(translatedShaderPipeline.pointWrapSampler, index: 3)
                feedbackEncoder.drawIndexedPrimitives(type: .triangle, indexCount: warpMesh.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
            } else if pixelEngine != nil, let vertices = warpVertexBuffer, let indices = warpIndexBuffer {
                feedbackEncoder.setRenderPipelineState(warpPipeline)
                feedbackEncoder.setVertexBuffer(vertices, offset: 0, index: 2)
                feedbackEncoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                feedbackEncoder.setFragmentTexture(source, index: 0)
                feedbackEncoder.drawIndexedPrimitives(type: .triangle, indexCount: warpMesh.indices.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
            } else {
                feedbackEncoder.setRenderPipelineState(pipeline)
                feedbackEncoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                feedbackEncoder.setFragmentBytes(audio.waveform, length: audio.waveform.count * MemoryLayout<Float>.stride, index: 1)
                feedbackEncoder.setFragmentTexture(source, index: 0)
                feedbackEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            feedbackEncoder.endEncoding()
            if MilkDropRenderPlan.needsNativeInjection(hasPixelEngine: pixelEngine != nil, hasTranslatedWarp: translatedWarp != nil) {
                let injectPass = MTLRenderPassDescriptor()
                injectPass.colorAttachments[0].texture = target
                injectPass.colorAttachments[0].loadAction = .load
                injectPass.colorAttachments[0].storeAction = .store
                guard let injectEncoder = command.makeRenderCommandEncoder(descriptor: injectPass) else { return }
                injectEncoder.setRenderPipelineState(pipeline)
                injectEncoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                injectEncoder.setFragmentBytes(audio.waveform, length: audio.waveform.count * MemoryLayout<Float>.stride, index: 1)
                injectEncoder.setFragmentTexture(source, index: 0)
                injectEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                injectEncoder.endEncoding()
            }
            var geometrySource = source
            if preset.customShapes.contains(where: { $0.enabled && $0.textured }), let snapshot = geometrySnapshot,
               let blit = command.makeBlitCommandEncoder() {
                blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                          sourceSize: .init(width: target.width, height: target.height, depth: 1),
                          to: snapshot, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding()
                geometrySource = snapshot
            }
            geometryRenderer.draw(command: command, target: target, source: geometrySource, audio: audio,
                                  q: eelVariables, time: now - started, fps: measuredFPS, frame: totalFrameCount)
            if highestTranslatedBlurLevel > 0 { encodeBlurPyramid(command: command, source: target) }
            guard let displayEncoder = command.makeRenderCommandEncoder(descriptor: displayPass) else { return }
            if let translatedComposite {
                displayEncoder.setRenderPipelineState(translatedComposite)
                displayEncoder.setFragmentBytes(&shaderUniforms, length: MemoryLayout<MilkDropShaderUniforms>.stride, index: 0)
                displayEncoder.setFragmentTexture(target, index: 0)
                displayEncoder.setFragmentTexture(blur1 ?? target, index: 1)
                displayEncoder.setFragmentTexture(blur2 ?? target, index: 2)
                displayEncoder.setFragmentTexture(blur3 ?? target, index: 3)
                displayEncoder.setFragmentTexture(translatedShaderPipeline.noiseLQ, index: 4)
                displayEncoder.setFragmentTexture(translatedShaderPipeline.noiseMQ, index: 5)
                displayEncoder.setFragmentTexture(translatedShaderPipeline.noiseHQ, index: 6)
                displayEncoder.setFragmentTexture(translatedShaderPipeline.noiseVolLQ, index: 7)
                displayEncoder.setFragmentTexture(translatedShaderPipeline.noiseVolHQ, index: 8)
                displayEncoder.setFragmentSamplerState(translatedShaderPipeline.sampler, index: 0)
                displayEncoder.setFragmentSamplerState(translatedShaderPipeline.wrapSampler, index: 1)
                displayEncoder.setFragmentSamplerState(translatedShaderPipeline.pointClampSampler, index: 2)
                displayEncoder.setFragmentSamplerState(translatedShaderPipeline.pointWrapSampler, index: 3)
            } else {
                displayEncoder.setRenderPipelineState(displayPipeline)
                displayEncoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                displayEncoder.setFragmentTexture(target, index: 0)
            }
            displayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            displayEncoder.endEncoding()
            feedbackIndex = 1 - feedbackIndex
            command.present(drawable); command.commit()
            frameCount += 1
            totalFrameCount += 1
            if now - fpsStarted >= 1 {
                let fps = Double(frameCount) / (now - fpsStarted)
                let text = String(format: "%.0f FPS • %dx%d • RGBA16F EDR-ready", fps, drawable.texture.width, drawable.texture.height)
                DispatchQueue.main.async { self.onPerformance?(text) }
                frameCount = 0; fpsStarted = now
            }
        }
    }

    private func encodeBlurPyramid(command: MTLCommandBuffer, source: MTLTexture) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(blurPipeline)
        let outputs = [blur1, blur2, blur3]
        var input = source
        for level in 0..<min(highestTranslatedBlurLevel, 3) {
            guard let horizontal = blurScratch[level], let output = outputs[level] else { break }
            encodeBlurPass(encoder: encoder, source: input, destination: horizontal, direction: SIMD2(1, 0))
            encoder.memoryBarrier(resources: [horizontal])
            encodeBlurPass(encoder: encoder, source: horizontal, destination: output, direction: SIMD2(0, 1))
            encoder.memoryBarrier(resources: [output])
            input = output
        }
        encoder.endEncoding()
    }

    private func encodeBlurPass(encoder: MTLComputeCommandEncoder, source: MTLTexture, destination: MTLTexture, direction: SIMD2<Float>) {
        var uniforms = BlurUniforms(texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)), direction: direction)
        encoder.setBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        let width = blurPipeline.threadExecutionWidth
        let height = max(1, blurPipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    private static func blurLevel(in source: String) -> Int {
        if source.contains("GetBlur3") || source.contains("sampler_blur3") { return 3 }
        if source.contains("GetBlur2") || source.contains("sampler_blur2") { return 2 }
        if source.contains("GetBlur1") || source.contains("sampler_blur1") { return 1 }
        return 0
    }

    private func makeFeedback(size: CGSize) {
        // MilkDrop's feedback texture was intentionally independent of display size. A 720p
        // half-float feedback field keeps the recursive pass comfortably inside an 8.33 ms
        // 120 Hz budget while the final Metal pass still presents at native 4K.
        let scale = min(1.0, 1280.0 / max(size.width, 1.0))
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
        feedback = [device.makeTexture(descriptor: d), device.makeTexture(descriptor: d)]
        geometrySnapshot = device.makeTexture(descriptor: d)
        func blurTexture(_ w: Int, _ h: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w, 16), height: max(h, 16), mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        blurScratch[0] = blurTexture(width / 2, height / 2)
        blur1 = blurTexture(width / 4, height / 4)
        blurScratch[1] = blurTexture(width / 8, height / 8)
        blur2 = blurTexture(width / 8, height / 8)
        blurScratch[2] = blurTexture(width / 16, height / 16)
        blur3 = blurTexture(width / 16, height / 16)
        feedbackInitialized = false
        allocatedDrawableSize = size
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float2 resolution; float time; float delta; float4 audio; float4 audioAtt; float4 preset; float4 color; float4 transform; uint4 flags; float4 post; float4 echo; float4 outerBorder; float4 innerBorder; float4 borderSizes; float4 motion; float4 motionColor; };
    struct WarpVertex { float2 position; float2 uv; float2 originalUV; };
    vertex VOut warpVertex(uint id [[vertex_id]], const device WarpVertex* vertices [[buffer(2)]]) {
        WarpVertex v = vertices[id]; VOut o; o.position = float4(v.position.x, -v.position.y, 0, 1); o.uv = v.uv; return o;
    }
    fragment half4 warpFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture2d<half> previous [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::repeat, filter::linear);
        float pulse = 1.0 + u.audio.x * 0.012 + sin(u.time * 0.7) * u.preset.w * 0.001;
        half3 color = previous.sample(s, in.uv).rgb * half(clamp(u.preset.x * pulse, 0.0, 1.0));
        return half4(color, 1);
    }
    vertex VOut fullscreenVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2); VOut o; o.position=float4(p*2.0-1.0,0,1); o.uv=float2(p.x,1.0-p.y); return o;
    }
    struct BlurUniforms { float2 texel; float2 direction; };
    kernel void blurKernel(uint2 gid [[thread_position_in_grid]], constant BlurUniforms& b [[buffer(0)]], texture2d<half, access::sample> source [[texture(0)]], texture2d<half, access::write> destination [[texture(1)]]) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
        constexpr sampler clampLinear(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(destination.get_width(), destination.get_height());
        float3 color = 0;
        float total = 0;
        if (b.direction.x > 0.5) {
            // Original MilkDrop pairs adjacent weights into one bilinear lookup.
            constexpr float hw[4] = {7.8,6.4,3.1,1.0};
            constexpr float hd[4] = {0.974358974,2.90625,4.774193548,6.6};
            for (int i=0; i<4; i++) {
                float2 delta = b.direction * b.texel * hd[i];
                color += float3(source.sample(clampLinear, uv + delta).rgb + source.sample(clampLinear, uv - delta).rgb) * hw[i];
                total += 2.0 * hw[i];
            }
        } else {
            // The vertical pass pairs four horizontal groups into two bilinear lookups.
            constexpr float vw[2] = {14.2,4.1};
            constexpr float vd[2] = {0.901408451,2.487804878};
            for (int i=0; i<2; i++) {
                float2 delta = b.direction * b.texel * vd[i];
                color += float3(source.sample(clampLinear, uv + delta).rgb + source.sample(clampLinear, uv - delta).rgb) * vw[i];
                total += 2.0 * vw[i];
            }
        }
        destination.write(half4(half3(color / max(total, 0.0001)), 1), gid);
    }
    float hash21(float2 p) { p=fract(p*float2(123.34,345.45)); p+=dot(p,p+34.345); return fract(p.x*p.y); }
    fragment half4 milkdropFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant float* waveform [[buffer(1)]], texture2d<half> previous [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::repeat, filter::linear);
        float2 uv=in.uv, p=uv-u.transform.xy; float aspect=u.resolution.x/u.resolution.y; p.x*=aspect;
        float bass=u.audio.x, mid=u.audio.y, treb=u.audio.z, beat=max(0.0,bass-u.audioAtt.x*1.15);
        float angle=u.preset.z + sin(u.time*0.23)*u.preset.w*0.015 + beat*0.04;
        float cs=cos(angle), sn=sin(angle); p=float2(cs*p.x-sn*p.y,sn*p.x+cs*p.y);
        float zoom=max(0.85,u.preset.y + bass*0.008); p/=zoom; p.x/=aspect;
        float2 warped=p+u.transform.xy-u.transform.zw*0.01;
        warped += 0.004*u.preset.w*float2(sin(p.y*13.0+u.time+mid*2.0),cos(p.x*11.0-u.time*0.7+treb*2.0));
        half3 old=previous.sample(linearSampler,warped).rgb*half(clamp(u.preset.x,0.8,0.9995));
        float r=length(p); float a=atan2(p.y,p.x); float arms=0.5+0.5*cos(a*(5.0+floor(mid*2.0))-u.time*(0.3+bass));
        float ring=exp(-abs(r-(0.17+0.08*sin(u.time*0.7+arms*3.0)))*90.0);
        float filaments=pow(max(0.0,sin(a*12.0+r*65.0-u.time*(1.0+treb*2.0))),18.0)*exp(-r*2.2);
        uint waveIndex=min(uint(clamp(uv.x,0.0,0.999)*512.0),511u);
        float waveY=(0.5-u.transform.y)*2.0 + waveform[waveIndex]*0.32;
        float wave=exp(-abs(p.y-waveY)*220.0)*clamp(u.color.a,0.0,2.0);
        float3 hue=0.55+0.45*cos(float3(0,2,4)+u.time*0.25+a+float3(bass,mid,treb)*2.0);
        float energy=(ring*(0.025+bass*0.22)+filaments*(0.02+treb*0.15)+wave*0.35+beat*0.35*exp(-r*12.0));
        float3 color=float3(old)+hue*energy*max(u.color.rgb,float3(0.05));
        color += hash21(uv+u.time)*0.0005; color=max(color-float3(0.0025),0.0);
        color=color/(1.0+max(color-0.9,0.0)); return half4(half3(color),1);
    }
    fragment half4 displayFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture2d<half> image [[texture(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 color = float3(image.sample(s, in.uv).rgb);
        float echoAlpha = clamp(u.echo.x, 0.0, 1.0);
        if (echoAlpha > 0.0001) {
            float2 echoUV = (in.uv - 0.5) / max(u.echo.y, 0.001) + 0.5;
            uint orientation = uint(u.echo.z) & 3u;
            if ((orientation & 1u) != 0u) echoUV.x = 1.0 - echoUV.x;
            if ((orientation & 2u) != 0u) echoUV.y = 1.0 - echoUV.y;
            color = mix(color, float3(image.sample(s, echoUV).rgb), echoAlpha);
        }
        if (u.post.z != 0.0) {
            float centerMask = smoothstep(0.0, 0.72, length((in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0)));
            color *= mix(0.45, 1.0, centerMask);
        }
        float edge = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
        if (edge < u.borderSizes.x) color = mix(color, u.outerBorder.rgb, clamp(u.outerBorder.a, 0.0, 1.0));
        else if (edge < u.borderSizes.x + u.borderSizes.y) color = mix(color, u.innerBorder.rgb, clamp(u.innerBorder.a, 0.0, 1.0));
        if (u.motionColor.a > 0.0001 && u.motion.x > 0.0 && u.motion.y > 0.0) {
            float2 grid = fract((in.uv - u.motion.zw) * max(u.motion.xy, float2(1.0)));
            float dotMask = smoothstep(0.12, 0.0, length(grid - 0.5));
            color += u.motionColor.rgb * dotMask * u.motionColor.a;
        }
        if (u.post.w > 0.001) {
            float3 s0 = 0.6 + 0.3 * sin(float3(u.time * 0.429 + 3.0, u.time * 0.321 + 1.0, u.time * 0.387 + 6.0));
            float3 s1 = 0.6 + 0.3 * sin(float3(u.time * 0.429 + 24.0, u.time * 0.321 + 14.0, u.time * 0.387 + 15.0));
            float3 s2 = 0.6 + 0.3 * sin(float3(u.time * 0.429 + 45.0, u.time * 0.321 + 27.0, u.time * 0.387 + 24.0));
            float3 s3 = 0.6 + 0.3 * sin(float3(u.time * 0.429 + 66.0, u.time * 0.321 + 40.0, u.time * 0.387 + 33.0));
            s0 = 0.5 + 0.5 * s0 / max(max(s0.r, s0.g), s0.b);
            s1 = 0.5 + 0.5 * s1 / max(max(s1.r, s1.g), s1.b);
            s2 = 0.5 + 0.5 * s2 / max(max(s2.r, s2.g), s2.b);
            s3 = 0.5 + 0.5 * s3 / max(max(s3.r, s3.g), s3.b);
            float3 hue = s0 * in.uv.x * in.uv.y + s1 * (1.0-in.uv.x) * in.uv.y + s2 * in.uv.x * (1.0-in.uv.y) + s3 * (1.0-in.uv.x) * (1.0-in.uv.y);
            color *= mix(float3(1.0), hue, clamp(u.post.w, 0.0, 1.0));
        }
        if (u.flags.w != 0) { color = sqrt(max(color, 0.0)); }
        if (u.post.x != 0) { color *= color; }
        if (u.flags.z != 0) { color *= (1.0 - color) * 4.0; }
        if (u.flags.y != 0) { color = 1.0 - color; }
        color *= max(u.post.y, 0.0);
        return half4(half3(clamp(color, 0.0, 1.0)), 1);
    }
    """
}
