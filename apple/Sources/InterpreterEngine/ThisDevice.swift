import Foundation

/// What to call the device in labels: "iPhone speaker", "iPad microphone".
/// Read from the hardware model rather than UIDevice, which is main-actor
/// only, so audio code off the main actor can name it too.
public enum ThisDevice {
    public static let name: String = {
        #if os(iOS)
        // The simulator reports the Mac's architecture; it names the device it plays.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPad") ? "iPad" : "iPhone"
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.hasPrefix("iPad") ? "iPad" : "iPhone"
        #else
        return "Mac"
        #endif
    }()

    public static var isPad: Bool { name == "iPad" }
}
