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
    private var rms: Float = 0
    public var level: Float { lock.withLock { rms } }

    public var count: Int { lock.withLock { base + samples.count } }

    func append(_ block: [Float]) {
        let rms = block.isEmpty ? 0 : (block.reduce(0) { $0 + $1 * $1 } / Float(block.count)).squareRoot()
        lock.withLock {
            samples += block
            self.rms = rms
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
            let started = ProcessInfo.processInfo.systemUptime
            var at = 0
            while at < samples.count, !Task.isCancelled {
                let due = Int((ProcessInfo.processInfo.systemUptime - started) * 16_000)
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
    let audioEngine: AVAudioEngine
    private var engine: AVAudioEngine { audioEngine }
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(device: String? = nil, engine sharedEngine: AVAudioEngine? = nil) throws {
        audioEngine = sharedEngine ?? AVAudioEngine()
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
        guard converter != nil else { throw AudioFailure.noInput }
        do {
            try objc {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
                    self?.receive(pcm)
                }
                tapInstalled = true
                engine.prepare()
            }
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
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
    let audioEngine: AVAudioEngine
    private var engine: AVAudioEngine { audioEngine }
    private let player = AVAudioPlayerNode()
    private let audible: Bool
    /// Every clip and the session second it starts, for the listen-back.
    private var clips: [(start: Double, samples: [Float])] = []
    public var placed: [(start: Double, samples: [Float])] { lock.withLock { clips } }
    public var sampleRate: Double { format.sampleRate }
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var end = 0.0  // session clock time the last scheduled clip finishes
    private var stopped = false
    private let clock: @Sendable () -> Double

    public init(sampleRate: Double, device: String? = nil, audible: Bool = true, engine sharedEngine: AVAudioEngine? = nil,
                clock: @escaping @Sendable () -> Double) throws {
        audioEngine = sharedEngine ?? AVAudioEngine()
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
        }
        // With a shared phone engine, the microphone installs its tap before
        // either I/O path starts. Two separate engines can reconfigure each
        // other's audio session during startup.
        if sharedEngine == nil { try start() }
    }

    func start() throws {
        guard audible else { return }
        do {
            try objc { engine.prepare() }
            if !engine.isRunning { try engine.start() }
            try objc { player.play() }
        } catch {
            stop()
            throw error
        }
    }

    /// How loud the interpreter is, from 0 to 1; takes effect at once, queued
    /// clips included.
    public var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
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
            guard !stopped else { return clock() }
            let start = max(clock(), end)
            end = start + Double(samples.count) / format.sampleRate
            // Only recording runs need a listen-back. Live playback must release
            // old audio instead of retaining a whole conversation in memory.
            if !audible { clips.append((start, samples)) }
            if audible { player.scheduleBuffer(pcm) }
            return start
        }
        return start
    }

    public func stop() {
        lock.withLock {
            stopped = true
            end = clock()
            if audible {
                player.stop()
                engine.stop()
            }
        }
    }
}

#if os(iOS)
/// By default the phone's own microphone hears the room and AirPods, if
/// connected, are only for listening, over A2DP, in full quality. Without
/// headphones the interpreter speaks from the speaker, and since what it says
/// is English, the gate keeps the echo quiet.
///
/// The headphones' microphone is closer to the people talking. Bluetooth input
/// used to mean call quality both ways (HFP); since iOS 26 AirPods can record
/// at full bandwidth, and since 26.2 hear the room ("far field") rather than
/// only the wearer, whose own speech is English and skipped anyway.
public enum PhoneAudio {
    /// Which microphone; the raw value is what LiveSession remembers.
    public enum Input: String, CaseIterable, Sendable {
        case phone = "iphone"
        case headphonesRoom = "headphones"
        case headphonesWearer = "headphones-wearer"

        public init(_ stored: String?) { self = stored.flatMap(Input.init(rawValue:)) ?? .phone }
        var usesHeadphones: Bool { self != .phone }
    }

    /// What the session actually got, for the settings screen: the requests
    /// above are preferences the route may not support.
    public static var inputDescription: String {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.currentRoute.inputs.first else { return "No microphone" }
        var parts = [port.portType == .builtInMic ? "\(ThisDevice.name) microphone" : port.portName]
        if #available(iOS 26.0, *), let bluetooth = port.bluetoothMicrophoneExtension {
            parts.append(bluetooth.highQualityRecording.isEnabled ? "full quality" : "call quality")
            parts.append(bluetooth.farFieldCapture.isEnabled ? "whole room" : "mainly the wearer")
        }
        return parts.joined(separator: " · ")
    }

    static var inputIsHeadphones: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType != .builtInMic }
    }

    static var routeState: AudioRouteState {
        let session = AVAudioSession.sharedInstance()
        return AudioRouteState(inputs: session.currentRoute.inputs.map(\.uid).sorted(),
                               outputs: session.currentRoute.outputs.map(\.uid).sorted(),
                               sampleRate: session.sampleRate,
                               inputChannels: session.inputNumberOfChannels,
                               outputChannels: session.outputNumberOfChannels)
    }

    public static func activate(_ input: Input = .phone) throws {
        let session = AVAudioSession.sharedInstance()
        if input.usesHeadphones {
            // Richest first; each option is a preference the route may refuse,
            // and an unsupported combination is an error, not a fallback.
            var attempts: [AVAudioSession.CategoryOptions] = []
            if #available(iOS 26.2, *), input == .headphonesRoom {
                attempts.append([.allowBluetoothHFP, .bluetoothHighQualityRecording, .farFieldInput, .defaultToSpeaker])
            }
            if #available(iOS 26.0, *) {
                attempts.append([.allowBluetoothHFP, .bluetoothHighQualityRecording, .defaultToSpeaker])
            }
            attempts.append([.allowBluetoothHFP, .defaultToSpeaker])
            var chosen = false
            for options in attempts where !chosen {
                chosen = (try? session.setCategory(.playAndRecord, mode: .default, options: options)) != nil
            }
            if !chosen { try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker]) }
            if let headset = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(headset)
            }
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
        }
        try session.setActive(true)
    }

    /// The category alone, at launch, without taking the audio: only then does
    /// iOS list a headset that is connected but playing another device's sound
    /// (AirPods' automatic switching), so the screen can say it will switch here.
    public static func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                         options: [.allowBluetoothHFP, .defaultToSpeaker])
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
