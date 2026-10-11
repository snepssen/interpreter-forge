import AVFoundation
import XCTest
@testable import InterpreterEngine

final class AudioChangeTests: XCTestCase {
    private let builtIn = AudioRouteState(inputs: ["built-in-mic"], outputs: ["speaker"],
                                         sampleRate: 48_000, inputChannels: 1, outputChannels: 2)

    func testDelayedStartupNotificationsDoNotInterruptAnIntactSession() {
        XCTAssertFalse(AudioChange.route(before: builtIn, after: builtIn).requiresRestart)
        XCTAssertFalse(AudioChange.engineConfiguration(owned: true, isRunning: true).requiresRestart)
        XCTAssertFalse(AudioChange.engineConfiguration(owned: false, isRunning: false).requiresRestart)
        XCTAssertFalse(AudioChange.interruption(began: false).requiresRestart)
    }

    func testDeviceFormatAndActualInterruptionChangesRequireRestart() {
        let headphones = AudioRouteState(inputs: ["built-in-mic"], outputs: ["headphones"],
                                         sampleRate: 48_000, inputChannels: 1, outputChannels: 2)
        let format = AudioRouteState(inputs: ["built-in-mic"], outputs: ["speaker"],
                                    sampleRate: 44_100, inputChannels: 1, outputChannels: 2)
        let channels = AudioRouteState(inputs: ["built-in-mic"], outputs: ["speaker"],
                                      sampleRate: 48_000, inputChannels: 2, outputChannels: 2)
        for route in [headphones, format, channels] {
            XCTAssertTrue(AudioChange.route(before: builtIn, after: route).requiresRestart)
        }
        XCTAssertTrue(AudioChange.engineConfiguration(owned: true, isRunning: false).requiresRestart)
        XCTAssertTrue(AudioChange.interruption(began: true).requiresRestart)
        XCTAssertTrue(AudioChange.mediaReset.requiresRestart)
    }

    func testCaptureAndPlaybackCanShareOneEngineWithoutOpeningAudio() throws {
        let engine = AVAudioEngine()
        let microphone = try Microphone(engine: engine)
        let speaker = try Speaker(sampleRate: 22_050, audible: false, engine: engine) { 0 }
        XCTAssertTrue(microphone.audioEngine === speaker.audioEngine)
        XCTAssertFalse(engine.isRunning)
        speaker.stop()
        microphone.stop()
    }
}
