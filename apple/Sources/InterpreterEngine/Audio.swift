@preconcurrency import AVFoundation
import Foundation
import ObjCExceptions
#if os(macOS)
import CoreAudio
#endif

/// Samples the microphone has delivered, 16 kHz mono, shared between the audio
/// thread that appends and the listener that reads.
public final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var base = 0  // stream index of samples[0]
    public private(set) var level: Float = 0  // RMS of the latest block

    public var count: Int { lock.withLock { base + samples.count } }

    func append(_ block: [Float]) {
        let rms = block.isEmpty ? 0 : (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot()
        lock.withLock {
            samples += block
            level = rms
        }
    }

    /// Stream samples from `start` to `end`, whatever of them is still held.
    public func read(_ start: Int, _ end: Int) -> [Float] {
        lock.withLock {
            let lo = max(start, base) - base
            let hi = min(end, base + samples.count) - base
            return lo < hi ? Array(samples[lo..<hi]) : []
        }
    }

    /// Let go of everything before stream index `index`.
    public func drop(before index: Int) {
        lock.withLock {
            let n = min(max(0, index - base), samples.count)
            samples.removeFirst(n)
            base += n
        }
    }

    public func everything() -> [Float] { lock.withLock { samples } }
}

public enum AudioFailure: LocalizedError {
    case noInput
    public var errorDescription: String? {
        "The microphone isn't delivering audio. Allow Interpreter in System Settings → Privacy & Security → Microphone."
    }
}

/// AVAudioEngine raises NSException for misuse; this makes it a Swift error.
func objc(_ body: () -> Void) throws {
    var error: NSError?
    if !TCTry(body, &error), let error { throw error }
}

/// Where the speech comes from.
public protocol AudioSource: AnyObject, Sendable {
    var buffer: SampleBuffer { get }
    func start() throws
    func stop()
    /// A recording that has played to its end; a microphone never is.
    var finished: Bool { get }
}

/// A recording played in at the pace it was spoken: the live loop, with the
/// same contention, for measuring without a microphone.
public final class Recording: AudioSource, @unchecked Sendable {
    public let buffer = SampleBuffer()
    private let samples: [Float]
    private var task: Task<Void, Never>?
    private let done = NSLock()
    private var ended = false

    public init(_ samples: [Float]) { self.samples = samples }

    public var finished: Bool { done.withLock { ended } }

    public func start() throws {
        let samples = samples
        let buffer = buffer
        task = Task.detached { [weak self] in
            let started = Date()
            var at = 0
            while at < samples.count, !Task.isCancelled {
                let due = Int(Date().timeIntervalSince(started) * 16_000)
                if due > at {
                    let end = min(due, samples.count)
                    buffer.append(Array(samples[at..<end]))
                    at = end
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            self?.done.withLock { self?.ended = true }
        }
    }

    public func stop() { task?.cancel() }
}

/// The microphone, converted to 16 kHz mono as it arrives.
public final class Microphone: AudioSource, @unchecked Sendable {
    public let buffer = SampleBuffer()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(device: String? = nil) throws {
        #if os(macOS)
        if let device, let id = AudioDevices.find(device, input: true) {
            try AudioDevices.use(id, on: engine.inputNode)
        }
        #endif
    }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Before microphone access is granted the input has no format at all, and
        // a tap on it raises an exception rather than failing.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioFailure.noInput }
        converter = AVAudioConverter(from: format, to: target)
        try objc {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
                self?.receive(pcm)
            }
            engine.prepare()
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    public var finished: Bool { false }

    private func receive(_ pcm: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * 16_000 / pcm.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let data = out.floatChannelData else { return }
        buffer.append(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}

/// Plays clips back to back and knows how far behind it is. With `audible`
/// false it only keeps the schedule, for a listen-back without speakers.
public final class Speaker: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audible: Bool
    /// Every clip and the session second it starts, for the listen-back.
    public private(set) var placed: [(start: Double, samples: [Float])] = []
    public var sampleRate: Double { format.sampleRate }
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var end = 0.0  // session clock time the last scheduled clip finishes
    private let clock: @Sendable () -> Double

    public init(sampleRate: Double, device: String? = nil, audible: Bool = true,
                clock: @escaping @Sendable () -> Double) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        self.clock = clock
        self.audible = audible
        guard audible else { return }
        #if os(macOS)
        if let device, let id = AudioDevices.find(device, input: false) {
            try AudioDevices.use(id, on: engine.outputNode)
        }
        #endif
        try objc {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
        }
        try engine.start()
        try objc { player.play() }
    }

    /// Seconds of English still waiting to be heard.
    public var backlog: Double { lock.withLock { max(0, end - clock()) } }

    /// Queue a clip; returns the session time it starts playing.
    @discardableResult
    public func play(_ samples: [Float]) -> Double {
        guard !samples.isEmpty, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return clock() }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let start = lock.withLock {
            let start = max(clock(), end)
            end = start + Double(samples.count) / format.sampleRate
            placed.append((start, samples))
            return start
        }
        if audible { player.scheduleBuffer(pcm) }
        return start
    }

    public func stop() {
        guard audible else { return }
        player.stop()
        engine.stop()
    }
}

#if os(iOS)
/// The phone's own microphone hears the room; AirPods, if connected, are only
/// for listening, over A2DP, so they stay in full quality rather than drop to
/// call quality. Without headphones the interpreter speaks from the speaker,
/// and since what it says is English, the gate keeps the echo quiet.
public enum PhoneAudio {
    public static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        }
        try session.setActive(true)
    }

    public static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

#if os(macOS)
/// Core Audio devices by name, so a mic can be chosen without changing the
/// system default: an iPhone on the table through Continuity, AirPods only for
/// listening.
public enum AudioDevices {
    public struct Device: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        public let name: String
        public let isInput: Bool
        public let isOutput: Bool
    }

    public static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { Device(id: $0, name: name($0), isInput: channels($0, kAudioObjectPropertyScopeInput) > 0,
                                isOutput: channels($0, kAudioObjectPropertyScopeOutput) > 0) }
    }

    /// The first device whose name contains `name`, of the right kind.
    static func find(_ name: String, input: Bool) -> AudioDeviceID? {
        all().first { ($0.isInput && input || $0.isOutput && !input) && $0.name.localizedCaseInsensitiveContains(name) }?.id
    }

    static func use(_ id: AudioDeviceID, on node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { return }
        var id = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func name(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
#endif
