import Foundation
import MilkDropCore

struct CheckError: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError(description: message) }
}

do {
    let source = "[preset00]\nfRating=4.5\nfDecay=0.97\nbTexWrap=1\nwavecode_0_enabled=1\nwavecode_0_sep=3\nwave_0_per_point_1=`x=sample;\nshapecode_0_enabled=1\nshapecode_0_sides=7\nshapecode_0_x=0.25\nshape_0_per_frame_1=`ang=time;\nper_frame_init_1=`q1=1;\nper_frame_1=`zoom=1.01;\nper_pixel_1=`rot=rad*0.01;\nwarp_1=`float3 ret=tex2D(sampler_main,uv).xyz;\nwarp_2=`ret*=1.2;\ncomp_1=`return float4(ret,1);"
    let preset = try MilkPreset.parse(source, name: "Test")
    try check(preset.rating == 4.5 && preset.decay == 0.97 && preset.wrap, "preset scalar parsing")
    try check(preset.customWaves[0].enabled, "custom wave parsing")
    try check(preset.customWaves[0].separation == 3 && preset.customWaves[0].perPointEquations == "x=sample;", "custom wave program parsing")
    try check(preset.customShapes[0].enabled && preset.customShapes[0].sides == 7 && preset.customShapes[0].position.x == 0.25 && preset.customShapes[0].perFrameEquations == "ang=time;", "custom shape parsing")
    try check(preset.warpShader.contains("tex2D") && preset.compositeShader.contains("float4"), "shader block parsing")
    try check(preset.perFrameInitEquations == "q1=1;" && preset.perFrameEquations == "zoom=1.01;" && preset.perPixelEquations == "rot=rad*0.01;", "equation block separation")
    let gap = try MilkPreset.parse("per_frame_1=a=1;\nper_frame_3=a=3;", name: "Gap")
    try check(gap.perFrameEquations == "a=1;", "numbered code stops at first gap")
    let ps200 = try MilkPreset.parse("MILKDROP_PRESET_VERSION=200\nPSVERSION=3", name: "PS200")
    try check(ps200.warpShaderVersion == 3 && ps200.compositeShaderVersion == 3, "version 200 shared shader profile")
    let ps201 = try MilkPreset.parse("MILKDROP_PRESET_VERSION=201\nPSVERSION_WARP=2\nPSVERSION_COMP=4", name: "PS201")
    try check(ps201.warpShaderVersion == 2 && ps201.compositeShaderVersion == 4, "version 201 split shader profiles")
    let mesh = WarpMesh(width: 1280, height: 960)
    try check(mesh.vertices.count == 49 * 37 && mesh.indices.count == 48 * 36 * 6, "warp mesh topology")
    let center = mesh.vertices[18 * 49 + 24]
    try check(abs(center.position.x) < 0.0001 && abs(center.position.y) < 0.0001 && abs(center.uv.x - 0.5) < 0.001 && abs(center.uv.y - 0.5) < 0.001 && center.radius < 0.001, "warp mesh center and UV")
    let pixelEngine = try EELEngine(source: "zoom=zoom+rad*0.1; dx=rad*0.01;")
    let warped = try mesh.evaluate(perPixel: pixelEngine, variables: ["q1": 0], motion: .init())
    try check(warped.count == mesh.vertices.count && warped[0].uv != mesh.vertices[0].uv && abs(warped[18 * 49 + 24].uv.x - 0.5) < 0.001, "per-pixel mesh execution: \(warped[0].uv) \(warped[18 * 49 + 24].uv)")
    let classic = try MilkPreset.parse("zoom=1.065\nrot=0.1\ncx=0.4\ncy=0.6\ndx=0.02\ndy=-0.03\nwarp=0.014\nsx=1.1\nsy=0.9\nwave_r=0.7\nwave_g=0.6\nwave_b=0.5\nfVideoEchoAlpha=0.4\nfVideoEchoZoom=1.2\nnVideoEchoOrientation=3\nob_size=0.02\nob_r=0.1\nob_g=0.2\nob_b=0.3\nob_a=0.8\nib_size=0.01\nnMotionVectorsX=16\nnMotionVectorsY=12\nmv_dx=0.02\nmv_dy=-0.03\nmv_a=0.7\nbDarkenCenter=1", name: "Classic")
    try check(classic.zoom == 1.065 && classic.rotation == 0.1 && classic.center.x == 0.4 && classic.translation.y == -0.03 && classic.warp == 0.014 && classic.waveColor.x == 0.7 && classic.hueShader == 0, "classic scalar names and hue shader default")
    try check(classic.videoEchoAlpha == 0.4 && classic.videoEchoZoom == 1.2 && classic.videoEchoOrientation == 3 && classic.outerBorderSize == 0.02 && classic.outerBorderColor == SIMD4(0.1, 0.2, 0.3, 0.8) && classic.innerBorderSize == 0.01 && classic.motionVectorGrid == SIMD2(16, 12) && classic.motionVectorOffset == SIMD2(0.02, -0.03) && classic.motionVectorColor.w == 0.7 && classic.darkenCenter && classic.waveMystery == 0 && !classic.waveDots && !classic.waveAdditive, "echo, border, motion vector, wave flags, and center state")
    let defaults = try MilkPreset.parse("[preset00]\n", name: "Empty")
    try check(defaults.decay == 0.98 && defaults.zoom == 1 && defaults.customWaves.count == 4, "preset defaults")
    let translated = try HLSLToMSLTranslator().translateFragment("shader_body { float3 c=tex2D(sampler_fc_main,uv).xyz + tex2D(sampler_fw_main,uv).xyz + tex2D(sampler_pc_main,uv).xyz; float3 p=tex2D(sampler_pw_main,uv_orig).xyz; float l=lum(c); ret=saturate(lerp(c+p+l,GetBlur1(uv)+GetBlur2(uv)+GetBlur3(uv),frac(rand_frame.x))); }")
    try check(translated.contains("sampler_main.sample(sampler_fc") && translated.contains("sampler_main.sample(sampler_fw") && translated.contains("sampler_main.sample(sampler_pc") && translated.contains("sampler_main.sample(sampler_pw") && translated.contains("sampler_blur1.sample") && translated.contains("sampler_blur2.sample") && translated.contains("sampler_blur3.sample") && translated.contains("float2 uv_orig") && translated.contains("float4 rand_frame") && translated.contains("dot(") && translated.contains("clamp(") && translated.contains("mix(") && translated.contains("fract("), "HLSL-to-MSL coordinate, random, four sampler modes, luminance, and blur ABI")
    let sampleComposite = try HLSLToMSLTranslator().translateFragment("shader_body { ret=tex2D(sampler_main,uv).xyz; }")
    try check(sampleComposite.contains("sampler_main.sample") && sampleComposite.contains("sampler_fc"), "synthetic composite translation (no external preset required)")
    let sampleWarp = try HLSLToMSLTranslator().translateFragment("shader_body { float3 a=tex2D(sampler_main,uv).xyz; ret=a; }")
    let kevlarMSL = sampleWarp
    try check(kevlarMSL.contains("sampler_main.sample"), "synthetic warp translation (no external preset required)")
    let noiseMSL = try HLSLToMSLTranslator().translateFragment("shader_body { float2 p=uv_orig*texsize.xy*texsize_noise_lq.zw+rand_frame.xy; ret=tex2D(sampler_noise_lq,p).xyz+tex2D(sampler_pw_noise_hq,p).xyz+tex2d(sampler_fc_main,p).xyz; }")
    try check(noiseMSL.contains("sampler_noise_lq.sample(sampler_fw") && noiseMSL.contains("sampler_noise_hq.sample(sampler_pw") && noiseMSL.contains("sampler_main.sample(sampler_fc") && noiseMSL.contains("float4 texsize_noise_lq"), "source-derived 2D noise and case-insensitive texture sampler ABI")
    let helperNameMSL = try HLSLToMSLTranslator().translateFragment("shader_body { float lum=lum(float3(1,1,1)); float1 scalar=lum; half1 compact=half1(scalar); ret=compact; }")
    try check(helperNameMSL.contains("float lum=hlsl_scalar(dot(") && helperNameMSL.contains("float scalar=hlsl_scalar(lum);") && helperNameMSL.contains("half compact=half(scalar);") && helperNameMSL.contains("ret=hlsl_float3(compact);"), "helper names may be identifiers and HLSL scalar aliases map exactly")
    let volumeMSL = try HLSLToMSLTranslator().translateFragment("shader_body { float3 p=uv.xyy*texsize_noisevol_hq.zww; ret=tex3D(sampler_noisevol_hq,p).xyz+tex3D(sampler_fw_noisevol_lq,p).xyz; }")
    try check(volumeMSL.contains("sampler_noisevol_hq.sample(sampler_fw") && volumeMSL.contains("sampler_noisevol_lq.sample(sampler_fw") && volumeMSL.contains("texture3d<float> sampler_noisevol_hq") && volumeMSL.contains("float4 texsize_noisevol_hq"), "source-derived 3D noise volume ABI")
    let scalarMSL = try HLSLToMSLTranslator().translateFragment("shader_body { float corr=texsize.xy*texsize_noise_lq.zw; float plain=2.0; ret=corr+plain; }")
    try check(scalarMSL.contains("float corr=hlsl_scalar(texsize.xy*texsize_noise_lq.zw);") && scalarMSL.contains("float plain=hlsl_scalar(2.0);"), "HLSL direct scalar declarations accept scalar or vector RHS")
    let uniformFields = ["aspect", "texsize", "audio", "audio_att", "timing", "rand_frame", "rand_preset", "texsize_noise_lq", "texsize_noise_mq", "texsize_noise_hq", "texsize_noisevol_lq", "texsize_noisevol_hq", "hue0", "hue1", "hue2", "hue3", "q0", "q1v", "q2v", "q3v", "q4v", "q5v", "q6v", "q7v"]
    try check(uniformFields.allSatisfy { scalarMSL.contains("float4 \($0)") }, "translated Metal uniform ABI contains all 24 packed float4 fields")
    let noHueWarp = try HLSLToMSLTranslator().translateFragment("shader_body { ret=hue_shader; }", composite: false)
    try check(scalarMSL.contains("float3 hue_shader") && !noHueWarp.contains("float3 hue_shader ="), "hue_shader exists only in composite wrapper")
    let qAliasMSL = try HLSLToMSLTranslator().translateFragment("shader_body { float2 zz=uv; zz=mul(zz,float2x2(_qa)); ret=zz.xyy+_qh.xyz+M_PI+M_PI_2+M_INV_PI_2; }")
    try check(qAliasMSL.contains("float4 _qa=uniforms.q0") && qAliasMSL.contains("_qh=uniforms.q7v") && qAliasMSL.contains("(float2x2(_qa.x, _qa.y, _qa.z, _qa.w) * zz)") && qAliasMSL.contains("3.14159265358979323846") && qAliasMSL.contains("1.57079632679489661923") && qAliasMSL.contains("0.63661977236758134308"), "q-vector aliases, packed 2x2 mul, and HLSL math constants")
    let vector3MSL = try HLSLToMSLTranslator().translateFragment("shader_body { float3 a=tex2D(sampler_noise_lq,uv); float3 b=0.5; ret=a+b; }")
    try check(vector3MSL.contains("float3 a=hlsl_float3(sampler_noise_lq.sample(sampler_fw, uv));") && vector3MSL.contains("float3 b=hlsl_float3(0.5);") && vector3MSL.contains("ret=hlsl_float3(a+b);"), "HLSL float3 declarations and wrapper ret accept float4 truncation and scalar splat")
    let preludeMSL = try HLSLToMSLTranslator().translateFragment("float3 ret1, neu;\nfloat2 uv1;\nfloat dx,dy;\nshader_body { uv1=uv; ret1=uv1.xyy+dx+dy; ret=ret1+neu; }")
    try check(preludeMSL.contains("float3 ret1 = hlsl_float3(float3(0.0));") && preludeMSL.contains("float3 neu = hlsl_float3(float3(0.0));") && preludeMSL.contains("float2 uv1 = float2(0.0);") && preludeMSL.contains("float dx = hlsl_scalar(0.0);") && preludeMSL.contains("float dy = hlsl_scalar(0.0);"), "simple numeric prelude declarations are preserved and zero-initialized")
    let shadowMSL = try HLSLToMSLTranslator().translateFragment("float2 uv1;\nshader_body {\nfloat2 uv1=uv;\nret=uv1.xyy;\n}")
    try check(shadowMSL.components(separatedBy: "float2 uv1").count == 2, "body declaration shadows and suppresses matching prelude declaration")


    try check(MilkDropRenderPlan.needsNativeInjection(hasPixelEngine: true, hasTranslatedWarp: false), "legacy per-pixel path retains native injection")
    try check(!MilkDropRenderPlan.needsNativeInjection(hasPixelEngine: true, hasTranslatedWarp: true), "translated authored warp does not receive a duplicate native injection pass")
    let backgroundLaunch = MilkDropLaunchPolicy(backgroundTest: true)
    try check(!backgroundLaunch.activatesApplication && !backgroundLaunch.entersFullscreen && !backgroundLaunch.makesWindowKey, "background test launch cannot steal focus or enter fullscreen")
    let normalLaunch = MilkDropLaunchPolicy(backgroundTest: false)
    try check(normalLaunch.activatesApplication && normalLaunch.entersFullscreen && normalLaunch.makesWindowKey, "normal launch retains native fullscreen activation")
    var geometryState: [String: Double] = ["implicit": 7, "x": 9, "t1": 4]
    MilkDropGeometryExecution.refresh(["x": 0.5, "t1": 1], in: &geometryState)
    try check(geometryState == ["implicit": 7, "x": 0.5, "t1": 1], "geometry refresh preserves implicit EEL state while restoring registered inputs")
    try check(MilkDropGeometryExecution.instanceCount(447) == 447, "custom shapes honor every authored instance")

    var parallelMotion = WarpMesh.Motion(); parallelMotion.zoom = 1.03; parallelMotion.rotation = 0.02
    let parallelMesh = WarpMesh(gridX: 8, gridY: 6, width: 1280, height: 720)
    let parallelPixel = try EELEngine(source: "rot=rot+0.2*sin(rad+ang); zoom=zoom-0.03*abs(sin(x*5+y*7)); dx=dx+0.01*cos(rad);")
    let serialWarp = try parallelMesh.evaluate(perPixel: parallelPixel, variables: [:], motion: parallelMotion)
    let concurrentWarp = try parallelMesh.evaluateConcurrent(perPixel: parallelPixel, variables: [:], motion: parallelMotion)
    try check(serialWarp == concurrentWarp, "concurrent warp mesh evaluation exactly matches serial EEL output")

    let vm = try EELEngine(source: "q1=2; q2=if(above(bass,1),q1*3,sin(pi/2)); zoom=clamp(q2,1,5); counter=counter+1;")
    var variables: [String: Double] = ["bass": 2, "zoom": 1]
    try vm.execute(variables: &variables)
    try check(variables["q1"] == 2 && variables["q2"] == 6 && variables["zoom"] == 5 && variables["counter"] == 1, "EEL assignment/functions")
    variables["bass"] = 0
    try vm.execute(variables: &variables)
    try check(abs((variables["q2"] ?? 0) - 1) < 0.0001 && variables["counter"] == 2, "EEL condition and persistent variable")
    let ops = try EELEngine(source: "x=1; x+=2; x*=3; y=equal(x,9); z=below(1,2)+above(3,2);")
    var opvars: [String: Double] = [:]
    try ops.execute(variables: &opvars)
    try check(opvars["x"] == 9 && opvars["y"] == 1 && opvars["z"] == 2, "EEL compound operators and comparisons")
    let advanced = try EELEngine(source: "x=bnot(0); nested=max(bnot(1),bnot(0)); gmegabuf(3)=7; gmegabuf(4)=gmegabuf(3)+2;")
    var advancedVars: [String: Double] = [:]
    try advanced.execute(variables: &advancedVars)
    let loopEngine = try EELEngine(source: "count=0; loop(3, count+=1);")
    var loopVars: [String: Double] = [:]
    try loopEngine.execute(variables: &loopVars)
    try check(advancedVars["gmegabuf[4]"] == 9 && advancedVars["x"] == 1 && advancedVars["nested"] == 1 && loopVars["count"] == 3, "EEL memory, lvalue calls, nested bnot, and loop: \(advancedVars) \(loopVars)")
    let persistent = try EELEngine(source: "zoom=zoom+0.1; q1=q1+1;")
    var persistentVars: [String: Double] = ["zoom": 1, "q1": 0]
    try persistent.execute(variables: &persistentVars); try persistent.execute(variables: &persistentVars)
    try check(abs((persistentVars["zoom"] ?? 0) - 1.2) < 0.000001 && persistentVars["q1"] == 2, "EEL persistent frame state: \(persistentVars)")
    let exec = try EELEngine(source: "x=exec2(a=2; a+=3, a*2); y=exec3(b=1; b+=2, b*=4, b+1);")
    var execVars: [String: Double] = [:]
    try exec.execute(variables: &execVars)
    try check(execVars["a"] == 5 && execVars["x"] == 10 && execVars["b"] == 12 && execVars["y"] == 13, "EEL exec2/exec3 sequencing: \(execVars)")
    let whileEngine = try EELEngine(source: "i=0; total=0; while(i<4, i+=1; total+=i);")
    var whileVars: [String: Double] = [:]
    try whileEngine.execute(variables: &whileVars)
    try check(whileVars["i"] == 4 && whileVars["total"] == 10, "EEL bounded while: \(whileVars)")
    let nestedWhile = try EELEngine(source: "i=0; total=0; while(exec2(i+=1, i<4), total+=i);")
    var nestedVars: [String: Double] = [:]
    try nestedWhile.execute(variables: &nestedVars)
    try check(nestedVars["i"] == 4 && nestedVars["total"] == 6, "EEL while exec2 idiom: \(nestedVars)")

    func settledTone(_ frequency: Double, amplitude: Double = 0.25) -> (AudioAnalyzer, AudioSnapshot) {
        let rate = 48_000.0, chunk = 2048
        let analyzer = AudioAnalyzer(sampleRate: rate)
        for block in 0..<100 {
            let samples = (0..<chunk).map { Float(sin(2 * .pi * frequency * Double(block * chunk + $0) / rate) * amplitude) }
            analyzer.consume(samples: samples)
        }
        return (analyzer, analyzer.snapshot())
    }
    let silence = AudioAnalyzer(sampleRate: 48_000); silence.consume(samples: Array(repeating: 0, count: 2048))
    try check(silence.snapshot().bass.isFinite && silence.snapshot().waveform.count == 512, "silence analysis")
    let (_, low) = settledTone(400), (_, mid) = settledTone(1500), (_, high) = settledTone(6000)
    try check(low.bass > low.mid && mid.mid > mid.bass && high.treble > high.mid, "source-derived FFT band response")
    try check(abs(low.bass - 1) < 0.2 && abs(mid.mid - 1) < 0.2 && abs(high.treble - 1) < 0.2, "sustained MilkDrop relative bands settle near one: \(low.bass), \(mid.mid), \(high.treble)")
    let (reactive, _) = settledTone(400, amplitude: 0.15)
    let louder = (0..<2048).map { Float(sin(2 * .pi * 400 * Double($0) / 48_000) * 0.6) }
    reactive.consume(samples: louder)
    let hit = reactive.snapshot()
    try check(hit.bass > 1.2 && hit.bassAttenuated > 1 && hit.bassAttenuated < hit.bass, "MilkDrop relative bands react above one with attenuated smoothing: \(hit.bass), \(hit.bassAttenuated)")
    print("PASS: parser, EEL interpreter, FFT bands, and waveform")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
