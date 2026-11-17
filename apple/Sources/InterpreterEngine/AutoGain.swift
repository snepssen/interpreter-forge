import Foundation

/// Automatic gain for the microphone: someone quiet, or across the table, or
/// heard through AirPods' call-quality microphone, comes up to the level of
/// normal speech before speech detection and recognition hear it; someone loud
/// comes down. It works on 10 ms blocks of 16 kHz audio.
///
/// The gain falls quickly (a loud voice is never clipped for long) and rises
/// slowly (a pause doesn't pump the room noise up). Blocks quieter than the
/// gate are the room, not speech: they hold the gain where it is.
struct AutoGain: Sendable {
    /// RMS of comfortable speech at full scale.
    var target: Float = 0.1
    /// At most +24 dB: more only lifts hiss.
    var maxGain: Float = 16
    var minGain: Float = 0.5
    /// Below this RMS a block is the room, not speech.
    var gate: Float = 0.003
    /// Fraction of the way to the wanted gain per 10 ms block.
    var attack: Float = 0.3   // falling: about 30 ms
    var release: Float = 0.01 // rising: about 1 s
    static let block = 160

    private(set) var gain: Float = 1

    mutating func process(_ samples: inout [Float]) {
        var at = 0
        while at < samples.count {
            let end = min(at + Self.block, samples.count)
            var energy: Float = 0
            for i in at..<end { energy += samples[i] * samples[i] }
            let rms = (energy / Float(end - at)).squareRoot()
            let from = gain
            if rms > gate {
                let wanted = min(maxGain, max(minGain, target / rms))
                gain += (wanted - gain) * (wanted < gain ? attack : release)
            }
            // Ramp across the block so a gain step doesn't click.
            let step = (gain - from) / Float(end - at)
            for i in at..<end {
                samples[i] = Self.limit(samples[i] * (from + step * Float(i - at + 1)))
            }
            at = end
        }
    }

    /// Untouched below 0.9; above it, bent smoothly towards 1 instead of clipped.
    static func limit(_ x: Float) -> Float {
        let size = abs(x)
        guard size > 0.9 else { return x }
        return (x < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((size - 0.9) / 0.1))
    }
}
