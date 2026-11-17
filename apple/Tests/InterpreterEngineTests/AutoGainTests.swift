import XCTest
@testable import InterpreterEngine

final class AutoGainTests: XCTestCase {
    /// Seconds of a 200 Hz tone at 16 kHz with the given RMS.
    private func tone(rms: Float, seconds: Double) -> [Float] {
        let amplitude = rms * 2.0.squareRoot().float
        return (0..<Int(seconds * 16_000)).map { amplitude * sin(2 * .pi * 200 * Float($0) / 16_000) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    func testQuietSpeakerComesUpToTarget() {
        var gain = AutoGain()
        var samples = tone(rms: 0.02, seconds: 5)
        gain.process(&samples)
        XCTAssertEqual(rms(samples.suffix(16_000)), gain.target, accuracy: 0.01)
    }

    func testVeryQuietInputIsCappedAtMaxGain() {
        var gain = AutoGain()
        var samples = tone(rms: 0.004, seconds: 8)
        gain.process(&samples)
        XCTAssertEqual(gain.gain, gain.maxGain, accuracy: 0.5)
    }

    func testLoudSpeakerComesDownQuicklyAndNeverClips() {
        var gain = AutoGain()
        var samples = tone(rms: 0.6, seconds: 1)
        gain.process(&samples)
        XCTAssertLessThanOrEqual(samples.map(abs).max()!, 1)
        // Within a tenth of a second it is turned down as far as it goes.
        XCTAssertEqual(rms(samples[1_600..<3_200]), 0.6 * gain.minGain, accuracy: 0.02)
    }

    func testSilenceHoldsTheGain() {
        var gain = AutoGain()
        var speech = tone(rms: 0.02, seconds: 5)
        gain.process(&speech)
        let held = gain.gain
        var room = tone(rms: 0.001, seconds: 5)
        gain.process(&room)
        XCTAssertEqual(gain.gain, held)
    }

    func testLimiterLeavesNormalSamplesAlone() {
        XCTAssertEqual(AutoGain.limit(0.5), 0.5)
        XCTAssertEqual(AutoGain.limit(-0.9), -0.9)
        XCTAssertLessThanOrEqual(AutoGain.limit(3), 1)
        XCTAssertGreaterThanOrEqual(AutoGain.limit(-3), -1)
        XCTAssertLessThan(AutoGain.limit(0.95), 0.95)
    }
}

private extension Double { var float: Float { Float(self) } }
