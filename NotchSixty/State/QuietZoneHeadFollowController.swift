import AppKit
import Combine
import Foundation

/// A source of head poses in the room frame (the Mac camera in production, a fake in tests).
/// `start` may ask for permission and throws when it cannot run; `stop` must release the camera at once.
protocol QuietZoneHeadPoseSourcing: AnyObject {
    func start() async throws
    func stop()
}

extension QuietZoneCameraHeadSource: QuietZoneHeadPoseSourcing {}

/// Removes notification observers when the owner goes away (the owner is main-actor isolated, so it cannot do this itself).
private final class HeadFollowObserverBag {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping @Sendable (Notification) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: block)))
    }
    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }
}

/// E4 S26b: the production reader for `e4.head-position-camera`. Lets the listener switch on head-follow, owns the
/// camera lifetime, and lets the head pose choose which surveyed ear position the Quiet Zone designs for.
///
/// Privacy (owner-approved, 11 Nov 2026): the camera is off at every launch (the switch is never persisted) and
/// runs only while head-follow is on. Frames are processed on this Mac by Vision in memory; only a head position is
/// kept; nothing is stored, logged or sent. The camera stops when head-follow is switched off, when the Mac goes to
/// sleep, and when the app is no longer the active app, and restarts on wake or return only while the switch is still on.
/// Control plane only: this never plays anything, never arms anything and is never read by the arm path. With no
/// usable pose (camera off, pose stale or low confidence, head outside the surveyed area) the fixed ear survey stays in use.
@MainActor
final class QuietZoneHeadFollowController: ObservableObject {
    enum CameraState: Equatable {
        case off
        case starting
        case on
        case paused(String)
        case denied
        case unavailable(String)
    }

    enum Readout: Equatable {
        case cameraOff
        case noPositions
        case waitingForPose
        case outsideSurvey
        case following(nearest: String, distanceCentimetres: Int)
    }

    struct SavedPosition: Identifiable, Equatable, Codable, Sendable {
        var id: UUID
        var name: String
        var x: Double
        var y: Double
        var z: Double
        var tones: [QuietZoneEarTone]
        /// The Room Correction position the ear survey behind `tones` was taken at, so a stored seat can be checked
        /// against the room measurements before it is trusted again (E4 G19). Nil for a seat saved without one.
        var earID: UUID? = nil
        /// The Room Correction position the monitor microphone was at, so a seat is not reused after the monitor moved.
        var monitorID: UUID? = nil
    }

    /// Where the camera is in the room, set by the listener (E4 G20). Seats are in this frame, so a change clears them.
    @Published private(set) var placement = QuietZoneCameraPlacement(x: 0, y: 0, z: 0, yawRadians: 0)
    /// Called after the seats or the placement changed in a way worth saving.
    var onChanged: (() -> Void)?
    /// Stored seats waiting for the room measurements to load so they can be checked (E4 G19).
    private var pendingSeats: [SavedPosition] = []

    /// Positions closer than this replace each other when saved.
    static let sameSeatMetres = 0.1

    typealias SourceFactory = @MainActor (@escaping @Sendable (QuietZoneHeadPose) -> Void) -> QuietZoneHeadPoseSourcing

    /// The Mac camera, camera frame mapped to the room with the placement read when the camera starts (E4 G20: the
    /// listener's setting; the default is the camera at the room origin, facing along +x).
    nonisolated static func cameraSourceFactory(
        placement: @escaping @MainActor () -> QuietZoneCameraPlacement = { QuietZoneCameraPlacement(x: 0, y: 0, z: 0, yawRadians: 0) }
    ) -> SourceFactory {
        { onPose in QuietZoneCameraHeadSource(placement: placement(), onPose: onPose) }
    }

    /// The listener's switch. Off at every launch.
    @Published private(set) var isEnabled = false
    @Published private(set) var cameraState: CameraState = .off
    /// The smoothed head position (room frame, metres) for the readout; nil without a fresh pose.
    @Published private(set) var pose: QuietZoneHeadPose?
    @Published private(set) var positions: [SavedPosition] = []
    @Published private(set) var message = "Head follow is off. The camera is not in use."

    enum Suspension: Hashable { case sleep, background }

    private let makeSource: SourceFactory
    private let clock: () -> Double
    private var tracker = QuietZoneHeadTracker()
    private var source: QuietZoneHeadPoseSourcing?
    private var suspensions: Set<Suspension> = []
    /// Bumped on every start and stop so a slow start that finishes after a stop is discarded.
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    private let observers = HeadFollowObserverBag()

    init(
        makeSource: @escaping SourceFactory,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        appCenter: NotificationCenter = .default
    ) {
        self.makeSource = makeSource
        self.clock = clock
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { $0.suspend(.sleep) }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { $0.resume(.sleep) }
        observe(appCenter, NSApplication.didResignActiveNotification) { $0.suspend(.background) }
        observe(appCenter, NSApplication.didBecomeActiveNotification) { $0.resume(.background) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (QuietZoneHeadFollowController) -> Void) {
        observers.add(center, name) { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
        }
    }

    var isCameraOn: Bool { cameraState == .on }

    var readout: Readout {
        guard isCameraOn else { return .cameraOff }
        guard !positions.isEmpty else { return .noPositions }
        guard let head = tracker.pose(at: clock()) else { return .waitingForPose }
        guard let blend = QuietZoneHeadSurvey.weights(positions: positions.map { ($0.x, $0.y, $0.z) }, at: head),
              let best = blend.max(by: { $0.weight < $1.weight }) else { return .outsideSurvey }
        let p = positions[best.index]
        let d = ((p.x - head.x) * (p.x - head.x) + (p.y - head.y) * (p.y - head.y) + (p.z - head.z) * (p.z - head.z)).squareRoot()
        return .following(nearest: p.name, distanceCentimetres: Int((d * 100).rounded()))
    }

    // MARK: Switch and camera lifetime

    /// Switches head-follow on or off. Switching on asks for camera permission the first time.
    func setEnabled(_ on: Bool) {
        Task { await setEnabledAndWait(on) }
    }

    func setEnabledAndWait(_ on: Bool) async {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            await startCameraIfAllowed()
        } else {
            stopCamera(state: .off)
            message = "Head follow is off. The camera is not in use."
        }
    }

    private func startCameraIfAllowed() async {
        guard isEnabled else { return }
        if !suspensions.isEmpty { cameraState = .paused(Self.pauseText(suspensions)); message = "Camera paused: \(Self.pauseText(suspensions))."; return }
        guard source == nil else { return }
        generation += 1
        let mine = generation
        cameraState = .starting
        message = "Starting the camera. Allow camera access if macOS asks."
        let newSource = makeSource { [weak self] pose in
            Task { @MainActor in self?.ingest(pose) }
        }
        source = newSource
        do {
            try await newSource.start()
        } catch {
            guard mine == generation else { return }
            newSource.stop()
            source = nil
            if let failure = error as? QuietZoneCameraHeadSource.Failure, failure == .denied {
                cameraState = .denied
                message = "Camera access is off for Notch Sixty. Allow it in System Settings, Privacy and Security, Camera."
            } else if let failure = error as? QuietZoneCameraHeadSource.Failure, failure == .noCamera {
                cameraState = .unavailable("No camera found.")
                message = "No camera found on this Mac."
            } else {
                cameraState = .unavailable("The camera could not start.")
                message = "The camera could not start."
            }
            return
        }
        guard mine == generation, isEnabled, suspensions.isEmpty else {
            // Switched off, slept or backgrounded while the camera was starting.
            newSource.stop()
            if mine == generation { source = nil }
            return
        }
        cameraState = .on
        message = "Camera on. Frames stay on this Mac and are never stored or sent."
    }

    private func stopCamera(state: CameraState) {
        generation += 1
        source?.stop()
        source = nil
        tracker.reset()
        pose = nil
        cameraState = state
    }

    private static func pauseText(_ s: Set<Suspension>) -> String {
        s.contains(.sleep) ? "this Mac is asleep" : "Notch Sixty is in the background"
    }

    func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        guard isEnabled, cameraState == .on || cameraState == .starting else { return }
        stopCamera(state: .paused(Self.pauseText(suspensions)))
        message = "Camera paused: \(Self.pauseText(suspensions)). It restarts when you are back."
    }

    func resume(_ reason: Suspension) {
        suspensions.remove(reason)
        guard isEnabled, suspensions.isEmpty else { return }
        if case .paused = cameraState {
            restartTask = Task { await startCameraIfAllowed() }
        }
    }

    // Lifecycle entry points (also driven by the system notifications observed in `init`).
    func systemWillSleep() { suspend(.sleep) }
    func systemDidWake() { resume(.sleep) }
    func appDidResignActive() { suspend(.background) }
    func appDidBecomeActive() { resume(.background) }
    /// Waits for a restart begun by `resume` (tests).
    func settle() async { await restartTask?.value }

    // MARK: Poses

    /// A pose from the source. The controller stamps its own time, so a source clock never decides staleness.
    func ingest(_ incoming: QuietZoneHeadPose) {
        guard isCameraOn else { return }
        var stamped = incoming
        stamped.time = clock()
        tracker.update(stamped)
        pose = tracker.pose(at: stamped.time)
    }

    // MARK: Surveyed positions

    /// Saves the ear survey just taken as the position where the head is now. Sit where the ear microphone was, then save.
    @discardableResult
    func savePosition(tones: [QuietZoneEarTone], earPositionID: UUID? = nil, monitorID: UUID? = nil) -> Bool {
        guard isCameraOn, let head = tracker.pose(at: clock()) else {
            message = "Switch head follow on and wait for the camera to find your head, then save."
            return false
        }
        guard !tones.isEmpty else { message = "Survey the ear position first."; return false }
        if let first = positions.first,
           first.tones.count != tones.count
            || zip(first.tones, tones).contains(where: { abs($0.frequencyHz - $1.frequencyHz) > 0.01 }) {
            message = "The surveyed tones differ from the saved positions. Clear the positions and save again."
            return false
        }
        var entry = SavedPosition(
            id: UUID(), name: "Seat \(positions.count + 1)", x: head.x, y: head.y, z: head.z, tones: tones, earID: earPositionID, monitorID: monitorID)
        if let nearIndex = positions.firstIndex(where: {
            QuietZoneHeadPose(x: $0.x, y: $0.y, z: $0.z, confidence: 1, time: 0).distance(to: head) < Self.sameSeatMetres
        }) {
            entry.id = positions[nearIndex].id
            entry.name = positions[nearIndex].name
            positions[nearIndex] = entry
        } else {
            positions.append(entry)
        }
        pendingSeats = []
        message = "Saved \(entry.name). Save more seats for the zone to follow between them."
        onChanged?()
        return true
    }

    func clearPositions() {
        positions = []
        pendingSeats = []
        message = "Saved positions cleared."
        onChanged?()
    }

    /// Sets where the camera is. Saved seats were taken in the old frame, so they are cleared, and the camera is
    /// switched off so the listener restarts it knowingly (E4 G20).
    func setPlacement(_ new: QuietZoneCameraPlacement) {
        guard new != placement, [new.x, new.y, new.z, new.yawRadians].allSatisfy(\.isFinite) else { return }
        placement = new
        let hadSeats = !positions.isEmpty || !pendingSeats.isEmpty
        positions = []
        pendingSeats = []
        if isEnabled {
            isEnabled = false
            stopCamera(state: .off)
        }
        message = hadSeats
            ? "Camera position changed, so the saved seats were cleared and head follow is off. Switch it on and save the seats again."
            : "Camera position saved."
        onChanged?()
    }

    /// Hands over the placement read from disk (no clearing: the seats read with it belong to it).
    func offerStored(placement stored: QuietZoneCameraPlacement?, seats: [SavedPosition]) {
        if let stored, [stored.x, stored.y, stored.z, stored.yawRadians].allSatisfy(\.isFinite) { placement = stored }
        guard positions.isEmpty else { return }
        pendingSeats = seats
    }

    /// The seats to save: the live ones, or ones still waiting to be checked after a launch.
    var storedSeats: [SavedPosition] { positions.isEmpty ? pendingSeats : positions }

    var hasPendingSeats: Bool { !pendingSeats.isEmpty }

    /// Shows stored seats whose ear survey still matches the room measurements. `check` returns nil while the room
    /// measurements are not loaded yet (the seats keep waiting), true when a seat still matches, false when it does not.
    func restoreSeatsIfPossible(check: (SavedPosition) -> Bool?) {
        guard !pendingSeats.isEmpty, positions.isEmpty else { return }
        var verdicts: [Bool] = []
        for seat in pendingSeats {
            guard let verdict = check(seat) else { return }
            verdicts.append(verdict)
        }
        let kept = zip(pendingSeats, verdicts).filter(\.1).map(\.0)
        let dropped = pendingSeats.count - kept.count
        pendingSeats = []
        positions = kept
        if dropped > 0 {
            message = "The room measurements changed since the seats were saved, so \(dropped == 1 ? "a seat was" : "\(dropped) seats were") not reused. Save them again."
            onChanged?()
        } else if !kept.isEmpty {
            message = "Reused \(kept.count) saved seat\(kept.count == 1 ? "" : "s") from last time."
        }
    }

    /// The surveyed tone for the head's current position, blended from the nearest saved positions, or nil to keep the
    /// fixed ear survey (camera off, no pose or a stale one, head outside the trust radius, or no saved position).
    func tone(near frequencyHz: Double) -> QuietZoneEarTone? {
        guard isCameraOn, let head = tracker.pose(at: clock()),
              let blend = QuietZoneHeadSurvey.weights(positions: positions.map { ($0.x, $0.y, $0.z) }, at: head),
              let first = blend.first,
              let toneIndex = positions[first.index].tones.indices.min(by: {
                  abs(positions[first.index].tones[$0].frequencyHz - frequencyHz) < abs(positions[first.index].tones[$1].frequencyHz - frequencyHz)
              }),
              abs(positions[first.index].tones[toneIndex].frequencyHz - frequencyHz) <= 0.5 else { return nil }
        var ratio = ActiveQuietZoneComplex.zero
        var left = ActiveQuietZoneComplex.zero
        var right = ActiveQuietZoneComplex.zero
        var effective = ActiveQuietZoneComplex.zero
        for entry in blend {
            let t = positions[entry.index].tones[toneIndex]
            ratio = ratio + t.ratio * entry.weight
            left = left + t.earLeft * entry.weight
            right = right + t.earRight * entry.weight
            effective = effective + t.effectiveSecondary * entry.weight
        }
        return QuietZoneEarTone(
            frequencyHz: positions[first.index].tones[toneIndex].frequencyHz,
            ratio: ratio, earLeft: left, earRight: right, effectiveSecondary: effective)
    }
}
