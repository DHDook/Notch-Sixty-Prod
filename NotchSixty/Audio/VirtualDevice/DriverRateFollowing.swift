import CoreAudio
import Foundation

// E36 S6b: automatic sample-rate following (design note 8). Off by default. When on and the driver path is in use, the rate a
// player sets on the virtual device is applied to the DAC: the same rate, or the nearest supported multiple of it. The DAC
// change goes through the engine's existing nominal-rate listener (the live rate change path), so nothing here touches a
// session. Control plane only (main actor, driven by the two-second driver poll); never called from an audio callback.

enum DriverRateFollowPolicy {
    static let tolerance = 0.5
    /// The multiples tried: 2x to 8x covers 44.1 kHz to 352.8 kHz.
    static let maxMultiple = 8

    /// The DAC rate for a player rate: the same rate when the DAC offers it, else the smallest supported integer multiple,
    /// else nil (the DAC stays; there is no resampling and no guess).
    static func target(playerRate: Double, dacRates: [Double]) -> Double? {
        guard playerRate > 0 else { return nil }
        func offered(_ rate: Double) -> Double? { dacRates.first { abs($0 - rate) < tolerance } }
        if let same = offered(playerRate) { return same }
        for multiple in 2...maxMultiple {
            if let match = offered(playerRate * Double(multiple)) { return match }
        }
        return nil
    }
}

protocol RateFollowingStore: AnyObject {
    var isEnabled: Bool { get set }
}

final class UserDefaultsRateFollowingStore: RateFollowingStore {
    static let key = "n60.e36.automaticRateFollowing"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    /// Off until the user turns it on.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// What the follower reads and writes. Production ports use Core Audio; tests pass fakes.
struct DriverRatePorts {
    /// The rate the player set on the virtual device, nil when the device is not there.
    var playerRate: () -> Double?
    var dacRate: () -> Double?
    var dacRates: () -> [Double]
    /// Returns true when the write was accepted.
    var setDACRate: (Double) -> Bool
}

@MainActor
final class DriverRateFollower {
    enum Outcome: Equatable {
        case disabled
        /// The driver path is not in use, so there is nothing to follow.
        case inactive
        case noPlayerRate
        case alreadyAtTarget
        /// The player's rate changed; it must hold for one more poll before the DAC follows (no thrash during a sweep).
        case settling(Double)
        case changed(Double)
        /// No supported rate or multiple: the DAC stays where it is.
        case unsupported(playerRate: Double)
        case failed(Double)
    }

    private let store: any RateFollowingStore
    private let ports: DriverRatePorts
    private var pending: Double?
    private var lastHandledPlayerRate: Double?
    private(set) var lastOutcome: Outcome = .disabled

    init(store: any RateFollowingStore, ports: DriverRatePorts) {
        self.store = store
        self.ports = ports
    }

    var isEnabled: Bool {
        get { store.isEnabled }
        set {
            store.isEnabled = newValue
            if !newValue { reset() }
        }
    }

    func reset() { pending = nil; lastHandledPlayerRate = nil }

    @discardableResult
    func tick(driverInUse: Bool) -> Outcome {
        lastOutcome = evaluate(driverInUse: driverInUse)
        return lastOutcome
    }

    private func evaluate(driverInUse: Bool) -> Outcome {
        guard store.isEnabled else { return .disabled }
        guard driverInUse else { reset(); return .inactive }
        guard let player = ports.playerRate(), player > 0 else { return .noPlayerRate }
        // A rate already acted on is not retried every poll; a new player rate is.
        if let handled = lastHandledPlayerRate, abs(handled - player) < DriverRateFollowPolicy.tolerance { return lastOutcome }
        guard let target = DriverRateFollowPolicy.target(playerRate: player, dacRates: ports.dacRates()) else {
            lastHandledPlayerRate = player
            return .unsupported(playerRate: player)
        }
        if let dac = ports.dacRate(), abs(dac - target) < DriverRateFollowPolicy.tolerance {
            lastHandledPlayerRate = player
            return .alreadyAtTarget
        }
        guard let seen = pending, abs(seen - player) < DriverRateFollowPolicy.tolerance else {
            pending = player
            return .settling(player)
        }
        pending = nil
        lastHandledPlayerRate = player
        return ports.setDACRate(target) ? .changed(target) : .failed(target)
    }
}

/// The slice of the engine rate following needs.
@MainActor
protocol RateFollowingEngine: AnyObject {
    var rateFollowingOutputDeviceID: AudioDeviceID? { get }
}

@MainActor
extension AudioIOEngine: RateFollowingEngine {
    var rateFollowingOutputDeviceID: AudioDeviceID? { selectedOutputDevice?.deviceID }
}

enum DriverRateFollowingSystem {
    static func readRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    static func writeRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// The virtual device, by the UID the driver publishes.
    static func virtualDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = N60_VD_DEVICE_UID as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    @MainActor
    static func ports(engine: @escaping () -> (any RateFollowingEngine)?) -> DriverRatePorts {
        DriverRatePorts(
            playerRate: { virtualDevice().flatMap(readRate) },
            dacRate: { engine()?.rateFollowingOutputDeviceID.flatMap(readRate) },
            dacRates: {
                guard let dac = engine()?.rateFollowingOutputDeviceID else { return [] }
                return DriverCaptureAttachment.availableRates(device: dac, current: readRate(dac) ?? 0).filter { $0 > 0 }
            },
            setDACRate: { rate in engine()?.rateFollowingOutputDeviceID.map { writeRate($0, rate) } ?? false })
    }
}
