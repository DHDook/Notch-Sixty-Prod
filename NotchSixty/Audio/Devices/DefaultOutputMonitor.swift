import CoreAudio
import Foundation

// E9 S8 (G28): tracks the macOS default output for the active-speaker failsafe without blocking the main thread.
//
// A Core Audio property listener on the system object fires whenever the default output changes; the UID is then read
// on a private serial queue and published on the main actor. The setup gate and the launch banner read the cached
// value, so a default change made while the app stays frontmost is caught at once and no Core Audio call runs on the
// main thread (except the one-off fallback read before the first cached value lands, which fails closed).

/// Installs a callback that runs whenever the macOS default output device changes.
protocol DefaultOutputChangeObserving: AnyObject {
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}

final class CoreAudioDefaultOutputChangeObserver: DefaultOutputChangeObserving {
    private var block: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.notchsixty.default-output-listener", qos: .utility)
    private static var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start(onChange: @escaping @Sendable () -> Void) {
        guard block == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = Self.address
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == 0 else { return }
        block = listener
    }

    func stop() {
        guard let block else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        self.block = nil
    }

    deinit { stop() }
}

@MainActor
final class DefaultOutputMonitor: ObservableObject {
    static let shared = DefaultOutputMonitor()

    /// The last UID read off-main. nil when there is no default output or it could not be read.
    @Published private(set) var defaultOutputUID: String?
    /// False until the first off-main read has landed.
    @Published private(set) var hasRead = false

    private let reader: DefaultOutputDeviceReading
    private let observer: DefaultOutputChangeObserving
    private let queue = DispatchQueue(label: "com.notchsixty.default-output-read", qos: .utility)
    private var started = false
    private var requestedSequence = 0
    private var appliedSequence = 0

    init(
        reader: DefaultOutputDeviceReading = CoreAudioDefaultOutputDeviceReader(),
        observer: DefaultOutputChangeObserving = CoreAudioDefaultOutputChangeObserver()
    ) {
        self.reader = reader
        self.observer = observer
    }

    /// Installs the property listener and reads the current value. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        observer.start { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        guard started else { return }
        started = false
        observer.stop()
    }

    /// Reads the default output off the main thread and publishes it. A read that finishes after a newer one is dropped.
    func refresh() async {
        requestedSequence += 1
        let sequence = requestedSequence
        let reader = self.reader
        let uid: String? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: reader.defaultOutputDeviceUID()) }
        }
        guard sequence > appliedSequence else { return }
        appliedSequence = sequence
        if defaultOutputUID != uid { defaultOutputUID = uid }
        if !hasRead { hasRead = true }
    }

    /// What the setup gate reads: the cached value. Before the first read has landed it reads directly (once, on the
    /// calling thread) rather than assuming the output is safe.
    func uidForGate() -> String? {
        hasRead ? defaultOutputUID : reader.defaultOutputDeviceUID()
    }
}
