import Foundation
import IOKit.pwr_mgt

/// E4 S29: keeps the Mac awake (display may sleep) while Quiet Zone is armed with overnight on.
///
/// Owner-approved 31 Oct 2026. The assertion is `kIOPMAssertionTypePreventUserIdleSystemSleep`, which
/// the App Sandbox allows and which does not hold the display on. It is taken only when `wanted` is
/// true and released on disarm, quit and teardown. If the Mac sleeps anyway (lid closed, low
/// battery), the existing `sleep` reason disarms and nothing re-arms on wake: the arm is never
/// persisted. Control plane only (main actor); never touched from an audio thread. The caller reads
/// the `e4.overnight` flag; this type never does.
protocol PowerAssertionBackend: AnyObject {
    /// Returns an opaque assertion ID, or nil when the system refused.
    func create(reason: String) -> UInt32?
    func release(_ id: UInt32)
}

final class IOKitPowerAssertionBackend: PowerAssertionBackend {
    func create(reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    func release(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

@MainActor
final class OvernightPowerAssertion {
    static let reason = "Notch Sixty Quiet Zone overnight run"

    private let backend: PowerAssertionBackend
    private var assertionID: UInt32?

    init(backend: PowerAssertionBackend = IOKitPowerAssertionBackend()) {
        self.backend = backend
    }

    var isHeld: Bool { assertionID != nil }

    /// Idempotent. `wanted` is armed AND overnight on AND flag on; any false releases. Returns
    /// whether the Mac is now being kept awake.
    @discardableResult
    func update(wanted: Bool) -> Bool {
        if wanted {
            if assertionID == nil { assertionID = backend.create(reason: Self.reason) }
        } else {
            release()
        }
        return isHeld
    }

    func release() {
        guard let id = assertionID else { return }
        assertionID = nil
        backend.release(id)
    }

    deinit {
        if let id = assertionID { backend.release(id) }
    }
}
