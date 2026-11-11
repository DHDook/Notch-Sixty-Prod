import Foundation

/// E4 G19/G20: everything the Quiet Zone ear surveys build up, kept across launches.
///
/// One record in `UserDefaults` (JSON): the ear survey, the second zone's survey, the other-seat surveys, the saved
/// head-follow seats and the camera placement. Measurements only: the listener's switches ("quiet the ear position",
/// zone mode, head follow) are never stored, so every launch starts at one seat with the camera off, and nothing here
/// arms anything. A stored survey is shown again only after the room measurements load and only when the monitor
/// position and the ear position's speaker paths are what they were (`QuietZoneVirtualMicSurveyController.restoreIfPossible`).
struct QuietZoneSurveyRecord: Codable, Equatable, Sendable {
    var version = 1
    var zoneA: QuietZoneVirtualMicSurveyController.Stored?
    var zoneB: QuietZoneVirtualMicSurveyController.Stored?
    var otherSeats: [QuietZoneVirtualMicSurveyController.Stored] = []
    var seats: [QuietZoneHeadFollowController.SavedPosition] = []
    var camera: QuietZoneCameraPlacement?

    var isEmpty: Bool { zoneA == nil && zoneB == nil && otherSeats.isEmpty && seats.isEmpty && camera == nil }
}

final class QuietZoneSurveyStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> QuietZoneSurveyRecord {
        guard let data = defaults.data(forKey: PreferenceKeys.quietZoneSurveys),
              let record = try? JSONDecoder().decode(QuietZoneSurveyRecord.self, from: data),
              record.version == 1 else { return QuietZoneSurveyRecord() }
        func finite(_ s: QuietZoneVirtualMicSurveyController.Stored?) -> QuietZoneVirtualMicSurveyController.Stored? {
            guard let s, !s.tones.isEmpty, s.tones.allSatisfy(\.isFinite) else { return nil }
            return s
        }
        var clean = record
        clean.zoneA = finite(record.zoneA)
        clean.zoneB = finite(record.zoneB)
        clean.otherSeats = record.otherSeats.compactMap(finite)
        clean.seats = record.seats.filter {
            !$0.tones.isEmpty && $0.tones.allSatisfy(\.isFinite) && [$0.x, $0.y, $0.z].allSatisfy(\.isFinite)
        }
        if let camera = record.camera, ![camera.x, camera.y, camera.z, camera.yawRadians].allSatisfy(\.isFinite) {
            clean.camera = nil
        }
        return clean
    }

    func save(_ record: QuietZoneSurveyRecord) {
        if record.isEmpty {
            defaults.removeObject(forKey: PreferenceKeys.quietZoneSurveys)
        } else if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: PreferenceKeys.quietZoneSurveys)
        }
    }
}

/// Connects the store to the Quiet Zone's survey controllers. Main actor, control plane only.
@MainActor
final class QuietZoneSurveyPersistence {
    private let store: QuietZoneSurveyStore
    private weak var quietZone: ActiveQuietZoneController?
    private var loaded = false
    /// What was on disk at launch: parts whose controller is not attached (its flag is off) are written back unchanged.
    private var base = QuietZoneSurveyRecord()

    init(store: QuietZoneSurveyStore = QuietZoneSurveyStore()) { self.store = store }

    /// Hooks every survey controller that exists now, hands each its stored survey, and saves on every change.
    func attach(to quietZone: ActiveQuietZoneController) {
        self.quietZone = quietZone
        let record = store.load()
        base = record
        quietZone.virtualMic?.onChanged = { [weak self] in self?.save() }
        quietZone.virtualMic?.offerStored(record.zoneA)
        if let zones = quietZone.zones {
            zones.second.onChanged = { [weak self] in self?.save() }
            zones.second.offerStored(record.zoneB)
            zones.onOtherSeatsChanged = { [weak self] in self?.save() }
            zones.offerStoredOtherSeats(record.otherSeats)
        }
        if let follow = quietZone.virtualMic?.headFollow {
            follow.onChanged = { [weak self] in self?.save() }
            follow.offerStored(placement: record.camera, seats: record.seats)
        }
        loaded = true
        restore()
    }

    /// Checks whatever is still waiting for the room measurements.
    func restore() {
        guard let quietZone, loaded else { return }
        quietZone.virtualMic?.restoreIfPossible()
        quietZone.zones?.second.restoreIfPossible()
        quietZone.zones?.restoreStoredOtherSeats()
        for seat in quietZone.zones?.otherSeats ?? [] { seat.restoreIfPossible() }
        quietZone.virtualMic?.headFollow?.restoreSeatsIfPossible { [weak quietZone] seat in
            guard let quietZone, let earID = seat.earID else { return false }
            let known = quietZone.ambient.availableModelPositions
            guard let monitor = quietZone.ambient.selectedModelPosition?.id,
                  known.contains(where: { $0.id == earID }) else { return known.isEmpty ? nil : false }
            guard seat.monitorID == monitor else { return false }
            for tone in seat.tones {
                guard tone.isFinite, let paths = try? quietZone.surveyPaths(frequencyHz: tone.frequencyHz, earPositionID: earID),
                      Self.close(paths.earLeft, tone.earLeft), Self.close(paths.earRight, tone.earRight) else { return false }
            }
            return true
        }
    }

    private static func close(_ a: ActiveQuietZoneComplex, _ b: ActiveQuietZoneComplex) -> Bool {
        hypot(a.real - b.real, a.imaginary - b.imaginary) <= 1.0e-6 * max(a.magnitude, b.magnitude, 1.0e-12)
    }

    func save() {
        guard loaded, let quietZone else { return }
        var record = base
        if let first = quietZone.virtualMic { record.zoneA = first.stored }
        if let zones = quietZone.zones {
            record.zoneB = zones.second.stored
            record.otherSeats = zones.storedOtherSeats
        }
        if let follow = quietZone.virtualMic?.headFollow {
            record.seats = follow.storedSeats
            let defaultPlacement = QuietZoneCameraPlacement(x: 0, y: 0, z: 0, yawRadians: 0)
            record.camera = follow.placement == defaultPlacement ? nil : follow.placement
        }
        store.save(record)
    }
}
