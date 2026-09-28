import Foundation

public struct CustomWave: Sendable, Equatable {
    public var enabled: Bool
    public var samples: Int
    public var spectrum: Bool
    public var dots: Bool
    public var thick: Bool
    public var additive: Bool
    public var scaling: Float
    public var smoothing: Float
    public var color: SIMD4<Float>
    public var separation: Int
    public var initEquations: String
    public var perFrameEquations: String
    public var perPointEquations: String
}

public struct CustomShape: Sendable, Equatable {
    public var enabled: Bool
    public var sides: Int
    public var additive: Bool
    public var thickOutline: Bool
    public var textured: Bool
    public var instances: Int
    public var position: SIMD2<Float>
    public var radius: Float
    public var angle: Float
    public var textureAngle: Float
    public var textureZoom: Float
    public var innerColor: SIMD4<Float>
    public var outerColor: SIMD4<Float>
    public var borderColor: SIMD4<Float>
    public var initEquations: String
    public var perFrameEquations: String
}

public struct MilkPreset: Sendable, Equatable {
    public var name: String
    public var presetVersion: Int
    public var warpShaderVersion: Int
    public var compositeShaderVersion: Int
    public var rating: Float
    public var decay: Float
    public var gamma: Float
    public var hueShader: Float
    public var zoom: Float
    public var zoomExponent: Float
    public var rotation: Float
    public var warp: Float
    public var center: SIMD2<Float>
    public var translation: SIMD2<Float>
    public var stretch: SIMD2<Float>
    public var waveColor: SIMD4<Float>
    public var wavePosition: SIMD2<Float>
    public var waveScale: Float
    public var waveSmoothing: Float
    public var waveMode: Int
    public var waveMystery: Float
    public var waveDots: Bool
    public var waveThick: Bool
    public var waveAdditive: Bool
    public var waveBrighten: Bool
    public var wrap: Bool
    public var brighten: Bool
    public var darken: Bool
    public var solarize: Bool
    public var invert: Bool
    public var darkenCenter: Bool
    public var videoEchoAlpha: Float
    public var videoEchoZoom: Float
    public var videoEchoOrientation: Int
    public var outerBorderSize: Float
    public var outerBorderColor: SIMD4<Float>
    public var innerBorderSize: Float
    public var innerBorderColor: SIMD4<Float>
    public var motionVectorGrid: SIMD2<Float>
    public var motionVectorOffset: SIMD2<Float>
    public var motionVectorLength: Float
    public var motionVectorColor: SIMD4<Float>
    public var warpShader: String
    public var compositeShader: String
    public var perFrameInitEquations: String
    public var perFrameEquations: String
    public var perPixelEquations: String
    public var customWaves: [CustomWave]
    public var customShapes: [CustomShape]

    public static func parse(_ source: String, name: String) throws -> MilkPreset {
        var values: [String: String] = [:]
        var warpLines: [(Int, String)] = []
        var compLines: [(Int, String)] = []
        var frameInitLines: [(Int, String)] = []
        var frameLines: [(Int, String)] = []
        var pixelLines: [(Int, String)] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]).trimmingCharacters(in: .whitespaces)
            var value = String(pair[1]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("`") { value.removeFirst() }
            values[key] = value
            func numbered(_ prefix: String) -> Int? {
                guard key.hasPrefix(prefix) else { return nil }
                return Int(key.dropFirst(prefix.count))
            }
            if let n = numbered("warp_") { warpLines.append((n, value)) }
            if let n = numbered("comp_") { compLines.append((n, value)) }
            if let n = numbered("per_frame_init_") { frameInitLines.append((n, value)) }
            if let n = numbered("per_frame_") { frameLines.append((n, value)) }
            if let n = numbered("per_pixel_") { pixelLines.append((n, value)) }
        }

        func f(_ keys: String..., default fallback: Float) -> Float {
            for key in keys { if let text = values[key], let value = Float(text) { return value } }
            return fallback
        }
        func i(_ key: String, default fallback: Int) -> Int { Int(values[key] ?? "") ?? fallback }
        func b(_ keys: String..., default fallback: Bool = false) -> Bool {
            for key in keys { if let text = values[key] { return text == "1" || text.lowercased() == "true" } }
            return fallback
        }
        // CState::ReadCode starts at 1 and stops at the first missing number.
        // Later fragments after a gap must not execute.
        func joined(_ lines: [(Int, String)]) -> String {
            let byIndex = Dictionary(lines.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
            var result: [String] = []
            var index = 1
            while let line = byIndex[index] {
                result.append(line)
                index += 1
            }
            return result.joined(separator: "\n")
        }
        func code(_ prefix: String) -> String {
            joined(values.compactMap { key, value -> (Int, String)? in
                guard key.hasPrefix(prefix) else { return nil }
                let suffix = key.dropFirst(prefix.count).drop(while: { $0 == "_" })
                guard let n = Int(suffix) else { return nil }
                return (n, value)
            })
        }

        let waves = (0..<4).map { n in
            let p = "wavecode_\(n)_"
            return CustomWave(
                enabled: b(p + "enabled"), samples: i(p + "samples", default: 512),
                spectrum: b(p + "bSpectrum"), dots: b(p + "bUseDots"), thick: b(p + "bDrawThick"),
                additive: b(p + "bAdditive"), scaling: f(p + "scaling", default: 1),
                smoothing: f(p + "smoothing", default: 0.5),
                color: SIMD4(f(p + "r", default: 1), f(p + "g", default: 1), f(p + "b", default: 1), f(p + "a", default: 1)),
                separation: i(p + "sep", default: 0), initEquations: code("wave_\(n)_init"),
                perFrameEquations: code("wave_\(n)_per_frame"), perPointEquations: code("wave_\(n)_per_point"))
        }

        let shapes = (0..<4).map { n in
            let p = "shapecode_\(n)_"
            return CustomShape(enabled: b(p + "enabled"), sides: i(p + "sides", default: 4),
                additive: b(p + "additive"), thickOutline: b(p + "thickOutline"), textured: b(p + "textured"),
                instances: i(p + "num_inst", default: 1), position: SIMD2(f(p + "x", default: 0.5), f(p + "y", default: 0.5)),
                radius: f(p + "rad", default: 0.1), angle: f(p + "ang", default: 0),
                textureAngle: f(p + "tex_ang", default: 0), textureZoom: f(p + "tex_zoom", default: 1),
                innerColor: SIMD4(f(p + "r", default: 1), f(p + "g", default: 0), f(p + "b", default: 0), f(p + "a", default: 1)),
                outerColor: SIMD4(f(p + "r2", default: 0), f(p + "g2", default: 1), f(p + "b2", default: 0), f(p + "a2", default: 0)),
                borderColor: SIMD4(f(p + "border_r", default: 1), f(p + "border_g", default: 1), f(p + "border_b", default: 1), f(p + "border_a", default: 0)),
                initEquations: code("shape_\(n)_init"), perFrameEquations: code("shape_\(n)_per_frame"))
        }

        let presetVersion = i("MILKDROP_PRESET_VERSION", default: 0)
        let shaderVersions: (Int, Int)
        if presetVersion < 200 {
            shaderVersions = (0, 0)
        } else if presetVersion == 200 {
            let shared = i("PSVERSION", default: 2)
            shaderVersions = (shared, shared)
        } else {
            shaderVersions = (i("PSVERSION_WARP", default: 2), i("PSVERSION_COMP", default: 2))
        }

        return MilkPreset(
            name: name, presetVersion: presetVersion,
            warpShaderVersion: shaderVersions.0, compositeShaderVersion: shaderVersions.1,
            rating: f("fRating", default: 0), decay: f("fDecay", default: 0.98),
            gamma: f("fGammaAdj", default: 2), hueShader: f("fShader", default: 0), zoom: f("zoom", "fZoom", default: 1),
            zoomExponent: f("fZoomExponent", default: 1), rotation: f("rot", "fRot", default: 0),
            warp: f("warp", "fWarpAmount", default: 0), center: SIMD2(f("cx", "fCenterX", default: 0.5), f("cy", "fCenterY", default: 0.5)),
            translation: SIMD2(f("dx", "fXPush", default: 0), f("dy", "fYPush", default: 0)),
            stretch: SIMD2(f("sx", "fStretchX", default: 1), f("sy", "fStretchY", default: 1)),
            waveColor: SIMD4(f("wave_r", "fWaveR", default: 1), f("wave_g", "fWaveG", default: 1), f("wave_b", "fWaveB", default: 1), f("fWaveAlpha", default: 0.8)),
            wavePosition: SIMD2(f("wave_x", "fWaveX", default: 0.5), f("wave_y", "fWaveY", default: 0.5)),
            waveScale: f("fWaveScale", default: 1), waveSmoothing: f("fWaveSmoothing", default: 0.5),
            waveMode: i("nWaveMode", default: 0), waveMystery: f("fWaveParam", default: 0),
            waveDots: b("bWaveDots"), waveThick: b("bWaveThick"), waveAdditive: b("bAdditiveWaves"), waveBrighten: b("bMaximizeWaveColor"),
            wrap: b("bTexWrap"), brighten: b("bBrighten"),
            darken: b("bDarken"), solarize: b("bSolarize"), invert: b("bInvert"),
            darkenCenter: b("bDarkenCenter"),
            videoEchoAlpha: f("fVideoEchoAlpha", default: 0), videoEchoZoom: f("fVideoEchoZoom", default: 2),
            videoEchoOrientation: i("nVideoEchoOrientation", default: 0),
            outerBorderSize: f("ob_size", default: 0),
            outerBorderColor: SIMD4(f("ob_r", default: 0), f("ob_g", default: 0), f("ob_b", default: 0), f("ob_a", default: 0)),
            innerBorderSize: f("ib_size", default: 0),
            innerBorderColor: SIMD4(f("ib_r", default: 0), f("ib_g", default: 0), f("ib_b", default: 0), f("ib_a", default: 0)),
            motionVectorGrid: SIMD2(f("mv_x", "nMotionVectorsX", default: 12), f("mv_y", "nMotionVectorsY", default: 9)),
            motionVectorOffset: SIMD2(f("mv_dx", default: 0), f("mv_dy", default: 0)),
            motionVectorLength: f("mv_l", default: 1),
            motionVectorColor: SIMD4(f("mv_r", default: 1), f("mv_g", default: 1), f("mv_b", default: 1), f("mv_a", default: 0)),
            warpShader: joined(warpLines), compositeShader: joined(compLines),
            perFrameInitEquations: joined(frameInitLines), perFrameEquations: joined(frameLines),
            perPixelEquations: joined(pixelLines), customWaves: waves, customShapes: shapes)
    }
}

public enum PresetLibrary {
    public static func discover(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "milk" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func load(_ url: URL) throws -> MilkPreset {
        let data = try Data(contentsOf: url)
        let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        return try MilkPreset.parse(source, name: url.deletingPathExtension().lastPathComponent)
    }
}
