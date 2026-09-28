import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures += 1; print("FAIL: \(message)") }
}

@main
struct HLSLTranslatorTestRunner {
    static func main() throws {
        let translator = HLSLToMSLTranslator()
        let basic = try translator.translateFragment("""
        shader_body
        {
            float3 color = tex2D(sampler_main, uv).xyz;
            ret = color;
        }
        """)
        expect(basic.contains("fragment float4 milkdrop_fragment"), "shader_body wrapper")
        expect(basic.contains("float3 color = sampler_main.sample(sampler_main_sampler, uv).xyz;"), "tex2D main sample")
        expect(basic.contains("return float4(ret, 1.0);"), "float4 fragment return")

        let intrinsics = try translator.translateFragment("""
        shader_body {
            float2 p = frac(uv);
            float3 mixed = lerp(float3(0, 0, 0), float3(1, 1, 1), p.x);
            ret = saturate(mixed); // frac lerp saturate tex2D
            float fracValue = 1;
        }
        """)
        expect(intrinsics.contains("float2 p = fract(uv);"), "frac token")
        expect(intrinsics.contains("float3 mixed = mix(float3(0, 0, 0), float3(1, 1, 1), p.x);"), "lerp token")
        expect(intrinsics.contains("ret = clamp(mixed, 0.0, 1.0);"), "saturate expansion")
        expect(intrinsics.contains("// frac lerp saturate tex2D"), "comments untouched")
        expect(intrinsics.contains("float fracValue = 1;"), "longer identifiers untouched")

        do {
            _ = try translator.translateFragment("shader_body { ret = tex2D(sampler_noise_lq, uv).xyz; }")
            expect(false, "unsupported sampler rejected")
        } catch HLSLToMSLTranslator.Error.unsupportedSampler("sampler_noise_lq") {} catch {
            expect(false, "unexpected unsupported sampler error: \(error)")
        }

        do {
            _ = try translator.translateFragment("ret = tex2D(sampler_main, uv).xyz;")
            expect(false, "missing shader_body rejected")
        } catch HLSLToMSLTranslator.Error.missingShaderBody {} catch {
            expect(false, "unexpected missing body error: \(error)")
        }

        let fixture = try translator.translateFragment("shader_body { ret = tex2D(sampler_main, uv).xyz; }")
        expect(fixture.contains("sampler_main.sample") && fixture.contains("sampler_fc"), "synthetic composite fixture; no external preset required")

        if failures == 0 { print("PASS: 14 HLSL-to-MSL assertions") }
        else { Foundation.exit(1) }
    }
}
