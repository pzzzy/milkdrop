import Foundation
import XCTest
@testable import MilkDropCore

final class AudioAnalyzerTests: XCTestCase {
    func testSilenceProducesFiniteZeroBands() {
        let analyzer = AudioAnalyzer(sampleRate: 48_000)
        analyzer.consume(samples: Array(repeating: 0, count: 2048))
        let snapshot = analyzer.snapshot()
        // MilkDrop's relative-band controls use 1.0 as the neutral baseline
        // when no long-term signal exists; silence must remain finite.
        XCTAssertEqual(snapshot.bass, 1)
        XCTAssertEqual(snapshot.mid, 1)
        XCTAssertEqual(snapshot.treble, 1)
        XCTAssertTrue(snapshot.waveform.allSatisfy(\.isFinite))
    }

    func testFrequencyBandsRespondToTheirRanges() {
        func tone(_ frequency: Double) -> AudioSnapshot {
            let rate = 48_000.0
            let samples = (0..<4096).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate) * 0.5) }
            let analyzer = AudioAnalyzer(sampleRate: rate)
            analyzer.consume(samples: samples)
            return analyzer.snapshot()
        }
        let low = tone(300), middle = tone(1_500), high = tone(6_000)
        XCTAssertTrue(low.bass > low.mid && low.bass > low.treble)
        XCTAssertTrue(middle.mid > middle.bass && middle.mid > middle.treble)
        XCTAssertTrue(high.treble > high.bass && high.treble > high.mid)
    }

    func testWaveformAlwaysHasFiveHundredTwelveSamples() {
        let analyzer = AudioAnalyzer(sampleRate: 96_000)
        analyzer.consume(samples: [0.1, -0.2, 0.3])
        XCTAssertEqual(analyzer.snapshot().waveform.count, 512)
    }
}
