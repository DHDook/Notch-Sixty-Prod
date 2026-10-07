import Foundation

enum BinauralAssetKind: String, Codable, CaseIterable, Sendable {
    case hrtf
    case brir

    var realtimeCType: N60BinauralProfileKind {
        switch self {
        case .hrtf: return N60BinauralProfileKindHRTF
        case .brir: return N60BinauralProfileKindBRIR
        }
    }
}

struct BinauralMeasurement: Codable, Equatable, Sendable {
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var distanceMeters: Double
    var leftIR: [Float]
    var rightIR: [Float]

    func validate(tapCount: Int) throws {
        guard azimuthDegrees.isFinite, (-180.0...180.0).contains(azimuthDegrees),
              elevationDegrees.isFinite, (-90.0...90.0).contains(elevationDegrees),
              distanceMeters.isFinite, distanceMeters > 0,
              leftIR.count == tapCount, rightIR.count == tapCount,
              leftIR.allSatisfy(\.isFinite), rightIR.allSatisfy(\.isFinite) else {
            throw BinauralProfileAssetError.invalidMeasurement
        }
    }
}

/// Sandbox-persisted normalized two-receiver HRTF/BRIR document.
///
/// This is deliberately a normalized renderer boundary, not a claim of native
/// AES69/SOFA/HDF5 parsing. A future reviewed SOFA adapter can populate this same
/// document without changing the realtime renderer or product profile schema.
struct BinauralProfileAsset: Codable, Equatable, Sendable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var id = UUID()
    var displayName: String
    var originalSourceName: String?
    var sampleRate: Double
    var tapCount: Int
    var declaredLatencyFrames: Int = 0
    var kind: BinauralAssetKind = .hrtf
    var measurements: [BinauralMeasurement]
    var importProvenance: SOFAImportProvenance?

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BinauralProfileAssetError.unsupportedSchema(schemaVersion)
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sampleRate.isFinite, sampleRate > 0,
              tapCount > 0, tapCount <= Int(N60_BINAURAL_MAX_TAPS),
              declaredLatencyFrames >= 0,
              declaredLatencyFrames <= Int(UInt32.max),
              !measurements.isEmpty else {
            throw BinauralProfileAssetError.invalidMetadata
        }
        for measurement in measurements {
            try measurement.validate(tapCount: tapCount)
        }
    }

    var reference: BinauralProfileReference {
        BinauralProfileReference(
            assetID: id,
            displayName: displayName,
            originalSourceName: originalSourceName,
            sampleRate: sampleRate,
            tapCount: tapCount
        )
    }

    func prepare(for layout: OutputProgramLayout) throws -> PreparedBinauralProfile {
        try prepare(
            for: layout,
            headPose: N60HeadPose(yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0)
        )
    }

    func prepare(
        for layout: OutputProgramLayout,
        headPose: N60HeadPose
    ) throws -> PreparedBinauralProfile {
        try validate()
        var worldDescriptor = N60BinauralProfileDescriptorMake(
            sampleRate,
            layout.realtimeLayout,
            kind.realtimeCType,
            UInt32(tapCount)
        )
        worldDescriptor.declaredLatencyFrames = UInt32(declaredLatencyFrames)
        guard N60BinauralProfileDescriptorIsValid(
            &worldDescriptor, UInt32(N60_BINAURAL_MAX_TAPS)
        ) else {
            throw BinauralProfileAssetError.descriptorCompilationFailed
        }
        var descriptor = N60BinauralProfileDescriptor()
        guard N60BinauralProfileDescriptorApplyHeadPose(
            &worldDescriptor, headPose, &descriptor
        ), N60BinauralProfileDescriptorIsValid(
            &descriptor, UInt32(N60_BINAURAL_MAX_TAPS)
        ) else {
            throw BinauralProfileAssetError.descriptorCompilationFailed
        }

        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(layout.roles.count * tapCount)
        right.reserveCapacity(layout.roles.count * tapCount)

        for channel in 0..<layout.roles.count {
            let target: N60BinauralSourcePosition = withUnsafePointer(
                to: &descriptor.sources
            ) { tuplePointer in
                tuplePointer.withMemoryRebound(
                    to: N60BinauralSourcePosition.self,
                    capacity: Int(N60_MAX_PROGRAM_CHANNELS)
                ) { sourcePointer in
                    sourcePointer[channel]
                }
            }
            guard let measurement = nearestMeasurement(
                azimuthDegrees: target.azimuthDegrees,
                elevationDegrees: target.elevationDegrees,
                distanceMeters: target.distanceMeters
            ) else {
                throw BinauralProfileAssetError.measurementUnavailable(
                    layout.roles[channel].displayName
                )
            }
            left.append(contentsOf: measurement.leftIR)
            right.append(contentsOf: measurement.rightIR)
        }
        return PreparedBinauralProfile(
            descriptor: descriptor,
            leftIRs: left,
            rightIRs: right
        )
    }

    private func nearestMeasurement(
        azimuthDegrees: Double,
        elevationDegrees: Double,
        distanceMeters: Double
    ) -> BinauralMeasurement? {
        let target = Self.unitVector(
            azimuthDegrees: azimuthDegrees,
            elevationDegrees: elevationDegrees
        )
        return measurements.max { lhs, rhs in
            score(lhs, target: target, targetDistance: distanceMeters)
                < score(rhs, target: target, targetDistance: distanceMeters)
        }
    }

    private func score(
        _ measurement: BinauralMeasurement,
        target: (Double, Double, Double),
        targetDistance: Double
    ) -> Double {
        let measured = Self.unitVector(
            azimuthDegrees: measurement.azimuthDegrees,
            elevationDegrees: measurement.elevationDegrees
        )
        let similarity = target.0 * measured.0 + target.1 * measured.1 + target.2 * measured.2
        return similarity - 0.001 * abs(measurement.distanceMeters - targetDistance)
    }

    private static func unitVector(
        azimuthDegrees: Double,
        elevationDegrees: Double
    ) -> (Double, Double, Double) {
        let azimuth = azimuthDegrees * .pi / 180.0
        let elevation = elevationDegrees * .pi / 180.0
        let cosElevation = cos(elevation)
        return (
            cosElevation * cos(azimuth),
            cosElevation * sin(azimuth),
            sin(elevation)
        )
    }

    /// Deterministic tiny dataset for build/runtime validation only.
    static func validationStereo(sampleRate: Double = 48_000) -> Self {
        let taps = 16
        func impulse(azimuth: Double, leftGain: Float, rightGain: Float) -> BinauralMeasurement {
            var left = [Float](repeating: 0, count: taps)
            var right = [Float](repeating: 0, count: taps)
            left[0] = leftGain
            right[0] = rightGain
            return BinauralMeasurement(
                azimuthDegrees: azimuth,
                elevationDegrees: 0,
                distanceMeters: 1,
                leftIR: left,
                rightIR: right
            )
        }
        return Self(
            displayName: "Validation HRTF",
            originalSourceName: nil,
            sampleRate: sampleRate,
            tapCount: taps,
            kind: .hrtf,
            measurements: [
                impulse(azimuth: -30, leftGain: 1.0, rightGain: 0.2),
                impulse(azimuth: 30, leftGain: 0.2, rightGain: 1.0),
                impulse(azimuth: 0, leftGain: 0.7, rightGain: 0.7),
            ]
        )
    }
}

struct PreparedBinauralProfile: Sendable {
    var descriptor: N60BinauralProfileDescriptor
    var leftIRs: [Float]
    var rightIRs: [Float]
}

enum BinauralProfileAssetError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidMetadata
    case invalidMeasurement
    case descriptorCompilationFailed
    case measurementUnavailable(String)
    case assetNotFound(UUID)
    case sofaImportFailed(String)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The spatial profile uses unsupported schema version \(version)."
        case .invalidMetadata:
            return "The normalized spatial profile metadata is invalid."
        case .invalidMeasurement:
            return "The normalized spatial profile contains an invalid HRTF/BRIR measurement."
        case .descriptorCompilationFailed:
            return "Unable to compile the normalized spatial profile for the selected program layout."
        case .measurementUnavailable(let role):
            return "The normalized spatial profile cannot provide a measurement for \(role)."
        case .assetNotFound(let id):
            return "The spatial profile asset \(id.uuidString) is not available in the app sandbox."
        case .sofaImportFailed(let reason):
            return "SOFA import failed. \(reason)"
        case .persistenceFailed:
            return "Unable to persist the normalized spatial profile in the app sandbox."
        }
    }
}

/// Small control-plane asset store. Files are only touched from UI/control code;
/// the realtime bridge receives already-prepared copied FIR kernels.
final class BinauralProfileAssetStore {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.rootURL = applicationSupport
                .appendingPathComponent("Notch Sixty", isDirectory: true)
                .appendingPathComponent("Binaural Profiles", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func save(_ asset: BinauralProfileAsset) throws -> BinauralProfileReference {
        try asset.validate()
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(asset)
            try data.write(to: url(for: asset.id), options: .atomic)
            return asset.reference
        } catch let error as BinauralProfileAssetError {
            throw error
        } catch {
            throw BinauralProfileAssetError.persistenceFailed
        }
    }

    func load(id: UUID) throws -> BinauralProfileAsset {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BinauralProfileAssetError.assetNotFound(id)
        }
        do {
            let asset = try decoder.decode(
                BinauralProfileAsset.self,
                from: Data(contentsOf: url)
            )
            try asset.validate()
            return asset
        } catch let error as BinauralProfileAssetError {
            throw error
        } catch {
            throw BinauralProfileAssetError.persistenceFailed
        }
    }

    /// Imports either a native AES69/SOFA FIR document or Notch Sixty's
    /// normalized JSON boundary. All file parsing stays on the control plane;
    /// only the normalized asset is persisted for later realtime preparation.
    func importNormalizedDocument(
        from sourceURL: URL
    ) throws -> BinauralProfileReference {
        if sourceURL.pathExtension.lowercased() == "sofa" {
            do {
                let dataset = try NativeSOFAImporter()
                    .load(from: sourceURL)
                var asset = try SOFABinauralAssetAdapter()
                    .makeAsset(
                        from: dataset,
                        sourceURL: sourceURL
                    )
                asset.id = UUID()
                return try save(asset)
            } catch let error as BinauralProfileAssetError {
                throw error
            } catch {
                throw BinauralProfileAssetError.sofaImportFailed(
                    error.localizedDescription
                )
            }
        }

        do {
            var asset = try decoder.decode(
                BinauralProfileAsset.self,
                from: Data(contentsOf: sourceURL)
            )
            asset.id = UUID()
            if asset.originalSourceName == nil {
                asset.originalSourceName = sourceURL.lastPathComponent
            }
            return try save(asset)
        } catch let error as BinauralProfileAssetError {
            throw error
        } catch {
            throw BinauralProfileAssetError.persistenceFailed
        }
    }

    private func url(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString).appendingPathExtension("n60binaural")
    }
}
