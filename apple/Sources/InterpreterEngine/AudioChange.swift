import Foundation

/// The route in use after capture and output have both started. Category and
/// route notifications can arrive later even when this configuration is intact.
struct AudioRouteState: Equatable, Sendable {
    let inputs: [String]
    let outputs: [String]
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
}

enum AudioChange: Sendable {
    case engineConfiguration(owned: Bool, isRunning: Bool)
    case route(before: AudioRouteState, after: AudioRouteState)
    case interruption(began: Bool)
    case mediaReset

    var requiresRestart: Bool {
        switch self {
        case .engineConfiguration(let owned, let running): owned && !running
        case .route(let before, let after): before != after
        case .interruption(let began): began
        case .mediaReset: true
        }
    }
}
