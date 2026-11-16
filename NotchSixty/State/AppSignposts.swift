import os

/// E1 S11: signposts around the app-level hot spots (graph publish, EQ design, profile save, launch), so Instruments and the
/// timed tests in `AppPerformanceTests` can see them. Allocation: none on the intervals themselves. Never call from an audio
/// callback; these run on the control plane only.
enum AppSignposts {
    static let signposter = OSSignposter(subsystem: "com.notchsixty.app", category: "performance")

    /// Runs `body` inside a named signpost interval.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
