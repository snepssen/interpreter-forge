/// What a human interpreter does when falling behind: say it faster, and, if the
/// listener chose to keep up rather than hear all, say less.
/// The backlog is how long a piece would wait behind the interpreter still speaking.
public struct Backlog: Sendable {
    public var briefAfter = 1.5  // seconds of backlog before translating for the gist
    public var fasterAfter = 1.0  // seconds of backlog before speeding up
    public var pacePerSecond = 0.1  // extra pace per second of backlog beyond that
    public var maxPace = 1.3

    public init() {}

    public func brief(_ backlog: Double) -> Bool { backlog >= briefAfter }

    public func pace(_ backlog: Double) -> Double {
        backlog <= fasterAfter ? 1 : min(maxPace, 1 + pacePerSecond * (backlog - fasterAfter))
    }
}
