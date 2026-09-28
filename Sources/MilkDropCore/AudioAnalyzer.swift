import Foundation

public struct AudioSnapshot: Sendable, Equatable {
    public var waveform: [Float]
    public var spectrum: [Float]
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var bassAttenuated: Float
    public var midAttenuated: Float
    public var trebleAttenuated: Float
    public var peak: Float

    public static let silence = AudioSnapshot(waveform: Array(repeating: 0, count: 512), spectrum: Array(repeating: 0, count: 512), bass: 0, mid: 0, treble: 0, bassAttenuated: 0, midAttenuated: 0, trebleAttenuated: 0, peak: 0)
}

public final class AudioAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleRate: Double
    private let fftSize = 2048
    private var history = Array(repeating: Float.zero, count: 2048)
    private var current = AudioSnapshot.silence
    private var fastAverage = Array(repeating: Float.zero, count: 3)
    private var longAverage = Array(repeating: Float.zero, count: 3)
    private var analyzedDuration: Double = 0

    public init(sampleRate: Double) { self.sampleRate = max(sampleRate, 1) }

    public func configure(sampleRate: Double) {
        lock.lock(); self.sampleRate = max(sampleRate, 1); lock.unlock()
    }

    public func consume(samples input: [Float]) {
        guard !input.isEmpty else { return }
        lock.lock()
        if input.count >= fftSize {
            history = Array(input.suffix(fftSize))
        } else {
            history.removeFirst(input.count)
            history.append(contentsOf: input)
        }
        var real = history
        var imag = Array(repeating: Float.zero, count: fftSize)
        var peak: Float = 0
        for n in 0..<fftSize {
            let window = 0.5 - 0.5 * cos(2 * Float.pi * Float(n) / Float(fftSize - 1))
            peak = max(peak, abs(real[n]))
            real[n] *= window
        }
        Self.fft(real: &real, imag: &imag)
        var spectrum = Array(repeating: Float.zero, count: 512)
        for bin in 0..<512 {
            let magnitude = hypot(real[bin], imag[bin]) / Float(fftSize)
            spectrum[bin] = min(4, magnitude * 8)
        }
        func band(_ low: Double, _ high: Double) -> Float {
            let first = max(1, Int(low * Double(fftSize) / sampleRate))
            let last = min(511, Int(high * Double(fftSize) / sampleRate))
            guard last >= first else { return 0 }
            return spectrum[first...last].reduce(Float.zero, +) / Float(last - first + 1)
        }
        // MilkDrop divides the pitch range 200...11025 Hz into three equal
        // logarithmic bands: 200...761, 761...2897, 2897...11025 Hz.
        let multiplier = pow(11_025.0 / 200.0, 1.0 / 3.0)
        let absolute = [band(200, 200 * multiplier),
                        band(200 * multiplier, 200 * multiplier * multiplier),
                        band(200 * multiplier * multiplier, 11_025)]
        let elapsed = Double(input.count) / sampleRate
        analyzedDuration += elapsed
        for index in 0..<3 {
            let fastBase: Float = absolute[index] > fastAverage[index] ? 0.2 : 0.5
            let fastRate = pow(fastBase, Float(30 * elapsed))
            fastAverage[index] = fastAverage[index] * fastRate + absolute[index] * (1 - fastRate)
            let longBase: Float = analyzedDuration < (50.0 / 30.0) ? 0.9 : 0.992
            let longRate = pow(longBase, Float(30 * elapsed))
            longAverage[index] = longAverage[index] * longRate + absolute[index] * (1 - longRate)
        }
        func relative(_ value: Float, _ history: Float) -> Float {
            abs(history) < 0.001 ? 1 : value / history
        }
        let immediateRelative = (0..<3).map { relative(absolute[$0], longAverage[$0]) }
        let attenuatedRelative = (0..<3).map { relative(fastAverage[$0], longAverage[$0]) }
        current = AudioSnapshot(
            waveform: Self.resample(history, count: 512), spectrum: spectrum,
            bass: immediateRelative[0], mid: immediateRelative[1], treble: immediateRelative[2],
            bassAttenuated: attenuatedRelative[0],
            midAttenuated: attenuatedRelative[1],
            trebleAttenuated: attenuatedRelative[2], peak: peak)
        lock.unlock()
    }

    public func snapshot() -> AudioSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private static func resample(_ input: [Float], count: Int) -> [Float] {
        guard !input.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { input[min(input.count - 1, $0 * input.count / count)] }
    }

    private static func fft(real: inout [Float], imag: inout [Float]) {
        let n = real.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i, j); imag.swapAt(i, j) }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Float.pi / Float(length)
            let wLenR = cos(angle), wLenI = sin(angle)
            for base in stride(from: 0, to: n, by: length) {
                var wr: Float = 1, wi: Float = 0
                for k in 0..<(length / 2) {
                    let even = base + k, odd = even + length / 2
                    let tr = real[odd] * wr - imag[odd] * wi
                    let ti = real[odd] * wi + imag[odd] * wr
                    real[odd] = real[even] - tr; imag[odd] = imag[even] - ti
                    real[even] += tr; imag[even] += ti
                    let nextR = wr * wLenR - wi * wLenI
                    wi = wr * wLenI + wi * wLenR; wr = nextR
                }
            }
            length <<= 1
        }
    }
}
