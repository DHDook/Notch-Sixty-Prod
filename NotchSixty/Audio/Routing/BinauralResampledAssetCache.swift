import Foundation

/// E6 S9c: loads and rate-converts binaural profile assets off the main actor, keeping the few most recent
/// (asset, rate) pairs so switching back and forth, or starting a session after a live preview, does not repeat the
/// conversion. Thread-safe; the lock is never held while loading or resampling.
final class BinauralResampledAssetCache: @unchecked Sendable {
    private struct Key: Hashable {
        var assetID: UUID
        var sampleRate: Double
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: BinauralProfileAsset] = [:]
    private var recency: [Key] = []
    private var conversions = 0

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    /// Number of resample conversions performed (cache misses), for tests and diagnostics.
    var conversionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return conversions
    }

    /// The asset `reference` names, converted to `sampleRate`. Validates the stored asset against the reference the
    /// way activation does.
    func asset(
        for reference: BinauralProfileReference,
        sampleRate: Double,
        store: BinauralProfileAssetStore
    ) throws -> BinauralProfileAsset {
        let key = Key(assetID: reference.assetID, sampleRate: sampleRate)
        lock.lock()
        if let hit = entries[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        if GenericHRTF.isGeneric(reference) {
            // E13 S11: the built-in generic HRTF is generated natively at the output rate, never resampled.
            guard let generated = GenericHRTF.asset(sampleRate: sampleRate) else {
                throw HeadphoneDeviceProfileError.invalidBinauralProfileReference
            }
            lock.lock(); defer { lock.unlock() }
            entries[key] = generated
            recency.removeAll { $0 == key }
            recency.append(key)
            while recency.count > capacity { entries[recency.removeFirst()] = nil }
            return generated
        }
        let stored = try store.load(id: reference.assetID)
        guard stored.id == reference.assetID,
              abs(stored.sampleRate - reference.sampleRate) < 0.5,
              stored.tapCount == reference.tapCount else {
            throw HeadphoneDeviceProfileError.invalidBinauralProfileReference
        }
        let converted = try stored.resampled(to: sampleRate)

        lock.lock(); defer { lock.unlock() }
        conversions += 1
        entries[key] = converted
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > capacity {
            entries[recency.removeFirst()] = nil
        }
        return converted
    }
}
