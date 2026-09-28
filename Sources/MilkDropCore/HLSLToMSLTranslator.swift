import Foundation

/// A deliberately small, strict translator for first-tier MilkDrop pixel shaders.
/// It accepts a single `shader_body { ... }` and only the HLSL constructs that
/// map unambiguously to the generated Metal fragment wrapper.
public struct HLSLToMSLTranslator: Sendable {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case missingShaderBody
        case malformedShaderBody
        case malformedCall(String)
        case unsupportedSampler(String)
        case unsupportedConstruct(String)

        public var description: String {
            switch self {
            case .missingShaderBody: return "expected shader_body"
            case .malformedShaderBody: return "malformed shader_body block"
            case .malformedCall(let name): return "malformed \(name) call"
            case .unsupportedSampler(let name): return "unsupported tex2D sampler: \(name)"
            case .unsupportedConstruct(let name): return "unsupported HLSL construct: \(name)"
            }
        }
    }

    public init() {}

    public func translateFragment(_ source: String, composite: Bool = true) throws -> String {
        let body = try extractShaderBody(source)
        let prelude = try extractSimplePreludeDeclarations(source)
        let translatedSource = prelude.isEmpty ? body : prelude + "\n" + body
        let translated = applyRetAssignmentCoercion(applyVector3DeclarationCoercion(applyScalarDeclarationCoercion(applyDirectTextureNarrowing(try transform(translatedSource)))))
        let hueSetup = composite ? """
            float3 hue_shader = uniforms.hue0.xyz*(uv.x)*(uv.y)
                              + uniforms.hue1.xyz*(1.0-uv.x)*(uv.y)
                              + uniforms.hue2.xyz*(uv.x)*(1.0-uv.y)
                              + uniforms.hue3.xyz*(1.0-uv.x)*(1.0-uv.y);
        """ : ""
        return """
        #include <metal_stdlib>
        using namespace metal;

        inline float hlsl_scalar(float v) { return v; }
        inline float hlsl_scalar(float2 v) { return v.x; }
        inline float hlsl_scalar(float3 v) { return v.x; }
        inline float hlsl_scalar(float4 v) { return v.x; }
        inline float3 hlsl_float3(float v) { return float3(v); }
        inline float3 hlsl_float3(float3 v) { return v; }
        inline float3 hlsl_float3(float4 v) { return v.xyz; }

        struct MilkDropRasterData {
            float4 position [[position]];
            float2 uv [[user(texturecoord)]];
            float2 uv_orig [[user(texturecoord_orig)]];
        };
        struct MilkDropShaderUniforms {
            float4 aspect;
            float4 texsize;
            float4 audio;
            float4 audio_att;
            float4 timing;
            float4 rand_frame;
            float4 rand_preset;
            float4 texsize_noise_lq;
            float4 texsize_noise_mq;
            float4 texsize_noise_hq;
            float4 texsize_noisevol_lq;
            float4 texsize_noisevol_hq;
            float4 hue0; float4 hue1; float4 hue2; float4 hue3;
            float4 q0; float4 q1v; float4 q2v; float4 q3v;
            float4 q4v; float4 q5v; float4 q6v; float4 q7v;
        };

        fragment float4 milkdrop_fragment(
            MilkDropRasterData in [[stage_in]],
            constant MilkDropShaderUniforms& uniforms [[buffer(0)]],
            texture2d<float> sampler_main [[texture(0)]],
            texture2d<float> sampler_blur1 [[texture(1)]],
            texture2d<float> sampler_blur2 [[texture(2)]],
            texture2d<float> sampler_blur3 [[texture(3)]],
            texture2d<float> sampler_noise_lq [[texture(4)]],
            texture2d<float> sampler_noise_mq [[texture(5)]],
            texture2d<float> sampler_noise_hq [[texture(6)]],
            texture3d<float> sampler_noisevol_lq [[texture(7)]],
            texture3d<float> sampler_noisevol_hq [[texture(8)]],
            sampler sampler_fc [[sampler(0)]], sampler sampler_fw [[sampler(1)]],
            sampler sampler_pc [[sampler(2)]], sampler sampler_pw [[sampler(3)]])
        {
            float2 uv = in.uv;
            float2 uv_orig = in.uv_orig;
            float2 centered = (uv - 0.5) * uniforms.aspect.xy;
            float rad = length(centered);
            float ang = atan2(centered.y, centered.x);
            float4 aspect = uniforms.aspect;
            float4 texsize = uniforms.texsize;
            float time = uniforms.timing.x, fps = uniforms.timing.y;
            float frame = uniforms.timing.z, progress = uniforms.timing.w;
            float4 rand_frame = uniforms.rand_frame, rand_preset = uniforms.rand_preset;
            float4 texsize_noise_lq = uniforms.texsize_noise_lq;
            float4 texsize_noise_mq = uniforms.texsize_noise_mq;
            float4 texsize_noise_hq = uniforms.texsize_noise_hq;
            float4 texsize_noisevol_lq = uniforms.texsize_noisevol_lq;
            float4 texsize_noisevol_hq = uniforms.texsize_noisevol_hq;
            \(hueSetup)
            float bass = uniforms.audio.x, mid = uniforms.audio.y, treb = uniforms.audio.z, vol = uniforms.audio.w;
            float bass_att = uniforms.audio_att.x, mid_att = uniforms.audio_att.y, treb_att = uniforms.audio_att.z, vol_att = uniforms.audio_att.w;
            float q1=uniforms.q0.x,q2=uniforms.q0.y,q3=uniforms.q0.z,q4=uniforms.q0.w;
            float q5=uniforms.q1v.x,q6=uniforms.q1v.y,q7=uniforms.q1v.z,q8=uniforms.q1v.w;
            float q9=uniforms.q2v.x,q10=uniforms.q2v.y,q11=uniforms.q2v.z,q12=uniforms.q2v.w;
            float q13=uniforms.q3v.x,q14=uniforms.q3v.y,q15=uniforms.q3v.z,q16=uniforms.q3v.w;
            float q17=uniforms.q4v.x,q18=uniforms.q4v.y,q19=uniforms.q4v.z,q20=uniforms.q4v.w;
            float q21=uniforms.q5v.x,q22=uniforms.q5v.y,q23=uniforms.q5v.z,q24=uniforms.q5v.w;
            float q25=uniforms.q6v.x,q26=uniforms.q6v.y,q27=uniforms.q6v.z,q28=uniforms.q6v.w;
            float q29=uniforms.q7v.x,q30=uniforms.q7v.y,q31=uniforms.q7v.z,q32=uniforms.q7v.w;
            float4 _qa=uniforms.q0, _qb=uniforms.q1v, _qc=uniforms.q2v, _qd=uniforms.q3v;
            float4 _qe=uniforms.q4v, _qf=uniforms.q5v, _qg=uniforms.q6v, _qh=uniforms.q7v;
            float3 ret = float3(0.0);
        \(translated)
            return float4(clamp(ret, 0.0, 1.0), 1.0);
        }
        """
    }

    /// HLSL permits direct float4-to-float3 assignment by dropping the final component.
    /// Metal requires explicit narrowing. Restrict this to direct texture-sample declaration
    /// initializers; compound-expression type inference remains strict.
    private func applyDirectTextureNarrowing(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\bfloat3\s+[A-Za-z_]\w*\s*=\s*sampler_main\.sample\([^;\n]+\))(\s*;)"#
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "$1.xyz$2")
    }

    /// HLSL permits a vector expression to initialize a scalar by taking its first
    /// component. Metal requires that coercion to be explicit. Restrict the rewrite
    /// to direct float declarations; assignments and compound statements remain strict.
    private func applyScalarDeclarationCoercion(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\bfloat\s+[A-Za-z_]\w*\s*=\s*)([^;\n]+)(\s*;)"#
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "$1hlsl_scalar($2)$3")
    }

    private func applyVector3DeclarationCoercion(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\bfloat3\s+[A-Za-z_]\w*\s*=\s*)([^;\n]+)(\s*;)"#
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "$1hlsl_float3($2)$3")
    }

    /// The generated MilkDrop wrapper declares `ret` as float3. HLSL permits
    /// float4 texture expressions on its RHS by dropping alpha; Metal does not.
    private func applyRetAssignmentCoercion(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\bret\s*[+\-*/]?=\s*)([^;\n]+)(\s*;)"#
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "$1hlsl_float3($2)$3")
    }

    private func extractSimplePreludeDeclarations(_ source: String) throws -> String {
        guard let marker = identifierRange(named: "shader_body", in: source) else {
            throw Error.missingShaderBody
        }
        let prefix = String(source[..<marker.lowerBound])
        let body = try extractShaderBody(source)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^\s*(float(?:[1-4])?|int)\s+([^;\n]+);\s*$"#
        ) else { return "" }
        let bodyMatches = regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
        var bodyNames = Set<String>()
        for match in bodyMatches {
            guard let itemsRange = Range(match.range(at: 2), in: body) else { continue }
            for rawItem in splitArguments(String(body[itemsRange])) {
                let name = rawItem.split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespacesAndNewlines)
                if name.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil { bodyNames.insert(name) }
            }
        }
        let matches = regex.matches(in: prefix, range: NSRange(prefix.startIndex..<prefix.endIndex, in: prefix))
        var declarations: [String] = []
        for match in matches {
            guard let typeRange = Range(match.range(at: 1), in: prefix),
                  let itemsRange = Range(match.range(at: 2), in: prefix) else { continue }
            let type = String(prefix[typeRange])
            for rawItem in splitArguments(String(prefix[itemsRange])) {
                let item = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
                let pieces = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil else {
                    throw Error.unsupportedConstruct("prelude declaration")
                }
                if bodyNames.contains(name) { continue }
                let zero = type == "int" ? "0" : (type == "float" || type == "float1" ? "0.0" : "\(type)(0.0)")
                let value = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : zero
                declarations.append("\(type) \(name) = \(value);")
            }
        }
        return declarations.joined(separator: "\n")
    }

    private func extractShaderBody(_ source: String) throws -> String {
        guard let marker = identifierRange(named: "shader_body", in: source) else {
            throw Error.missingShaderBody
        }
        var index = marker.upperBound
        skipTrivia(in: source, index: &index)
        guard index < source.endIndex, source[index] == "{" else { throw Error.malformedShaderBody }
        let close = try matchingClose(in: source, open: index)
        return String(source[source.index(after: index)..<close])
    }

    private func transform(_ source: String) throws -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "/", let next = nextIndex(in: source, after: index) {
                if source[next] == "/" {
                    let end = source[index...].firstIndex(of: "\n") ?? source.endIndex
                    result += source[index..<end]
                    index = end
                    continue
                }
                if source[next] == "*", let end = source.range(of: "*/", range: next..<source.endIndex)?.upperBound {
                    result += source[index..<end]
                    index = end
                    continue
                }
            }
            if source[index] == "\"" || source[index] == "'" {
                let end = quotedEnd(in: source, start: index)
                result += source[index..<end]
                index = end
                continue
            }
            if isIdentifierStart(source[index]) {
                let start = index
                index = identifierEnd(in: source, start: start)
                let name = String(source[start..<index])
                if name == "float1" { result += "float"; continue }
                if name == "half1" { result += "half"; continue }
                if name == "double1" { result += "double"; continue }
                if name == "M_PI" { result += "3.14159265358979323846"; continue }
                if name == "M_PI_2" { result += "1.57079632679489661923"; continue }
                if name == "M_INV_PI_2" { result += "0.63661977236758134308"; continue }
                if name == "float2x2" {
                    var open = index
                    skipWhitespace(in: source, index: &open)
                    guard open < source.endIndex, source[open] == "(" else { result += name; continue }
                    let close = try matchingClose(in: source, open: open)
                    let args = splitArguments(String(source[source.index(after: open)..<close]))
                    guard args.count == 1, args[0].trimmingCharacters(in: .whitespacesAndNewlines) == "_qa" else { throw Error.unsupportedConstruct(name) }
                    result += "float2x2(_qa.x, _qa.y, _qa.z, _qa.w)"
                    index = source.index(after: close)
                    continue
                }
                if name == "mul" {
                    var open = index
                    skipWhitespace(in: source, index: &open)
                    guard open < source.endIndex, source[open] == "(" else { result += name; continue }
                    let close = try matchingClose(in: source, open: open)
                    let args = splitArguments(String(source[source.index(after: open)..<close]))
                    guard args.count == 2 else { throw Error.unsupportedConstruct(name) }
                    result += "(\(try transform(args[1])) * \(try transform(args[0])))"
                    index = source.index(after: close)
                    continue
                }
                if name == "frac" { result += "fract"; continue }
                if name == "lerp" { result += "mix"; continue }
                if name == "saturate" || name == "tex2D" || name == "tex2d" || name == "tex3D" || name == "tex3d" || name == "GetBlur1" || name == "GetBlur2" || name == "GetBlur3" || name == "lum" {
                    var open = index
                    skipWhitespace(in: source, index: &open)
                    guard open < source.endIndex, source[open] == "(" else {
                        result += name
                        continue
                    }
                    let close = try matchingClose(in: source, open: open)
                    let arguments = splitArguments(String(source[source.index(after: open)..<close]))
                    if name == "saturate" {
                        guard arguments.count == 1 else { throw Error.malformedCall(name) }
                        result += "clamp(\(try transform(arguments[0])), 0.0, 1.0)"
                    } else if name == "lum" {
                        guard arguments.count == 1 else { throw Error.malformedCall(name) }
                        result += "dot(\(try transform(arguments[0])), float3(0.32, 0.49, 0.29))"
                    } else if name == "GetBlur1" || name == "GetBlur2" || name == "GetBlur3" {
                        guard arguments.count == 1 else { throw Error.malformedCall(name) }
                        let level = name == "GetBlur1" ? "1" : (name == "GetBlur2" ? "2" : "3")
                        result += "sampler_blur\(level).sample(sampler_fc, \(try transform(arguments[0]).trimmingCharacters(in: .whitespacesAndNewlines))).xyz"
                    } else if name == "tex3D" || name == "tex3d" {
                        guard arguments.count == 2 else { throw Error.malformedCall(name) }
                        let sampler = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let coordinate = try transform(arguments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let volumeMap: [String: (String, String)] = [
                            "sampler_noisevol_lq": ("sampler_noisevol_lq", "sampler_fw"), "sampler_fw_noisevol_lq": ("sampler_noisevol_lq", "sampler_fw"), "sampler_fc_noisevol_lq": ("sampler_noisevol_lq", "sampler_fc"), "sampler_pw_noisevol_lq": ("sampler_noisevol_lq", "sampler_pw"), "sampler_pc_noisevol_lq": ("sampler_noisevol_lq", "sampler_pc"),
                            "sampler_noisevol_hq": ("sampler_noisevol_hq", "sampler_fw"), "sampler_fw_noisevol_hq": ("sampler_noisevol_hq", "sampler_fw"), "sampler_fc_noisevol_hq": ("sampler_noisevol_hq", "sampler_fc"), "sampler_pw_noisevol_hq": ("sampler_noisevol_hq", "sampler_pw"), "sampler_pc_noisevol_hq": ("sampler_noisevol_hq", "sampler_pc")
                        ]
                        guard let (texture, mode) = volumeMap[sampler] else { throw Error.unsupportedSampler(sampler) }
                        result += "\(texture).sample(\(mode), \(coordinate))"
                    } else {
                        guard arguments.count == 2 else { throw Error.malformedCall(name) }
                        let sampler = arguments[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        let coordinate = try transform(arguments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let noiseMap: [String: (String, String)] = [
                            "sampler_noise_lq": ("sampler_noise_lq", "sampler_fw"), "sampler_fw_noise_lq": ("sampler_noise_lq", "sampler_fw"), "sampler_fc_noise_lq": ("sampler_noise_lq", "sampler_fc"), "sampler_pw_noise_lq": ("sampler_noise_lq", "sampler_pw"), "sampler_pc_noise_lq": ("sampler_noise_lq", "sampler_pc"),
                            "sampler_noise_mq": ("sampler_noise_mq", "sampler_fw"), "sampler_fw_noise_mq": ("sampler_noise_mq", "sampler_fw"), "sampler_fc_noise_mq": ("sampler_noise_mq", "sampler_fc"), "sampler_pw_noise_mq": ("sampler_noise_mq", "sampler_pw"), "sampler_pc_noise_mq": ("sampler_noise_mq", "sampler_pc"),
                            "sampler_noise_hq": ("sampler_noise_hq", "sampler_fw"), "sampler_fw_noise_hq": ("sampler_noise_hq", "sampler_fw"), "sampler_fc_noise_hq": ("sampler_noise_hq", "sampler_fc"), "sampler_pw_noise_hq": ("sampler_noise_hq", "sampler_pw"), "sampler_pc_noise_hq": ("sampler_noise_hq", "sampler_pc")
                        ]
                        if let (texture, mode) = noiseMap[sampler] {
                            result += "\(texture).sample(\(mode), \(coordinate))"
                            index = source.index(after: close)
                            continue
                        }
                        switch sampler {
                        case "sampler_main", "sampler_fc_main", "sampler_cf_main": result += "sampler_main.sample(sampler_fc, \(coordinate))"
                        case "sampler_fw_main", "sampler_wf_main": result += "sampler_main.sample(sampler_fw, \(coordinate))"
                        case "sampler_pc_main", "sampler_cp_main": result += "sampler_main.sample(sampler_pc, \(coordinate))"
                        case "sampler_pw_main", "sampler_wp_main": result += "sampler_main.sample(sampler_pw, \(coordinate))"
                        default:
                            throw Error.unsupportedSampler(sampler)
                        }
                    }
                    index = source.index(after: close)
                    continue
                }
                // Metal uses the same float/float2/float3/float4 type and constructor spellings.
                result += name
                continue
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    private func identifierRange(named name: String, in source: String) -> Range<String.Index>? {
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "/", let next = nextIndex(in: source, after: index), source[next] == "/" {
                index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                continue
            }
            if isIdentifierStart(source[index]) {
                let end = identifierEnd(in: source, start: index)
                if source[index..<end] == name { return index..<end }
                index = end
            } else { index = source.index(after: index) }
        }
        return nil
    }

    private func matchingClose(in source: String, open: String.Index) throws -> String.Index {
        let opening = source[open]
        let closing: Character = opening == "{" ? "}" : ")"
        var depth = 1
        var index = source.index(after: open)
        while index < source.endIndex {
            if source[index] == "/", let next = nextIndex(in: source, after: index) {
                if source[next] == "/" { index = source[index...].firstIndex(of: "\n") ?? source.endIndex; continue }
                if source[next] == "*", let end = source.range(of: "*/", range: next..<source.endIndex)?.upperBound { index = end; continue }
            }
            if source[index] == "\"" || source[index] == "'" { index = quotedEnd(in: source, start: index); continue }
            if source[index] == opening { depth += 1 }
            if source[index] == closing { depth -= 1; if depth == 0 { return index } }
            index = source.index(after: index)
        }
        throw Error.malformedShaderBody
    }

    private func splitArguments(_ text: String) -> [String] {
        var result: [String] = [], start = text.startIndex, index = start, depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            else if character == ")" || character == "]" || character == "}" { depth -= 1 }
            else if character == "," && depth == 0 { result.append(String(text[start..<index])); start = text.index(after: index) }
            index = text.index(after: index)
        }
        result.append(String(text[start..<text.endIndex]))
        return result
    }

    private func skipTrivia(in source: String, index: inout String.Index) {
        while index < source.endIndex {
            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex, source[index] == "/", let next = nextIndex(in: source, after: index) else { return }
            if source[next] == "/" { index = source[index...].firstIndex(of: "\n") ?? source.endIndex }
            else if source[next] == "*", let end = source.range(of: "*/", range: next..<source.endIndex)?.upperBound { index = end }
            else { return }
        }
    }

    private func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex && source[index].isWhitespace { index = source.index(after: index) }
    }
    private func identifierEnd(in source: String, start: String.Index) -> String.Index {
        var index = source.index(after: start)
        while index < source.endIndex && (source[index].isLetter || source[index].isNumber || source[index] == "_") { index = source.index(after: index) }
        return index
    }
    private func isIdentifierStart(_ character: Character) -> Bool { character.isLetter || character == "_" }
    private func nextIndex(in source: String, after index: String.Index) -> String.Index? {
        let next = source.index(after: index); return next < source.endIndex ? next : nil
    }
    private func quotedEnd(in source: String, start: String.Index) -> String.Index {
        let quote = source[start]; var index = source.index(after: start); var escaped = false
        while index < source.endIndex {
            let character = source[index]; index = source.index(after: index)
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == quote { break }
        }
        return index
    }
}
