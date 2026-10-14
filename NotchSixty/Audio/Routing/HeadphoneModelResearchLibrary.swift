import Foundation

/// Local user-supplied headphone frequency-response measurements, not a
/// licensed/bundled measurement database. A measured model curve is *not* a
/// personalized fit for an individual seal or ear canal.
struct HeadphoneModelFrequencyPoint: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var leftMagnitudeDB: Double
    var rightMagnitudeDB: Double
    var targetMagnitudeDB: Double
}

struct HeadphoneModelMeasurement: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion: Int
    var id: UUID
    var headphoneModel: String
    var sourceName: String
    var sourceAttribution: String
    var sourceLicense: String
    var acquisitionNotes: String
    var points: [HeadphoneModelFrequencyPoint]

    func validate(sampleRate: Double) throws {
        guard schemaVersion == 1,
              sampleRate.isFinite, (44_100...384_000).contains(sampleRate),
              !headphoneModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceAttribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceLicense.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              acquisitionNotes.count <= 2_000,
              (16...256).contains(points.count) else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        var previous = 0.0
        for point in points {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz >= 20,
                  point.frequencyHz <= min(20_000, sampleRate * 0.45),
                  point.frequencyHz > previous,
                  point.leftMagnitudeDB.isFinite,
                  point.rightMagnitudeDB.isFinite,
                  point.targetMagnitudeDB.isFinite,
                  abs(point.leftMagnitudeDB) <= 50,
                  abs(point.rightMagnitudeDB) <= 50,
                  abs(point.targetMagnitudeDB) <= 30 else {
                throw OptionalAcousticResearchError.invalidEvidence
            }
            previous = point.frequencyHz
        }
    }
}

struct HeadphoneModelFitResult: Sendable {
    var headphoneModel: String
    var proposal: HeadphoneCorrectionProposal
    var leftRMSEBeforeDB: Double
    var rightRMSEBeforeDB: Double
    var leftRMSEAfterDB: Double
    var rightRMSEAfterDB: Double
    var worstFrequencyRegressionDB: Double
    var recommendedHeadroomDB: Double
    var warnings: [String]
    var canApply: Bool { false }
    var isIndividualCalibration: Bool { false }
    var isMeasuredVerification: Bool { false }
}

/// Finite, deterministic greedy PEQ fitting against an explicitly sourced
/// model measurement. This only prepares HeadphoneCorrectionProposal; the
/// existing manual Stage/Apply + digital attenuation gate remains authoritative.
/// Comparisons use the same production float biquad-design transfer as the
/// device's headphone PEQ, not a hand-wavy parametric surrogate.
struct HeadphoneModelCorrectionDesigner: Sendable {
    func fit(
        measurement: HeadphoneModelMeasurement,
        sampleRate: Double,
        maximumBandsPerEar: Int = 8
    ) throws -> HeadphoneModelFitResult {
        try measurement.validate(sampleRate: sampleRate)
        guard (1...16).contains(maximumBandsPerEar) else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        let grid = measurement.points
        func rmse(_ residual: [Double]) -> Double {
            sqrt(residual.reduce(0) { $0 + $1 * $1 } / Double(residual.count))
        }
        func fitEar(_ key: KeyPath<HeadphoneModelFrequencyPoint, Double>)
            -> (bands: [HeadphoneCorrectionEQBand], before: Double,
                after: Double, worst: Double) {
            let desired = grid.map { $0.targetMagnitudeDB - $0[keyPath: key] }
            var bands = [HeadphoneCorrectionEQBand]()
            var residual = desired
            var currentRMSE = rmse(residual)
            let originalRMSE = currentRMSE
            for _ in 0..<maximumBandsPerEar {
                var best: (band: HeadphoneCorrectionEQBand,
                           residual: [Double], rmse: Double)?
                let sorted = grid.indices.sorted {
                    abs(residual[$0]) > abs(residual[$1])
                }
                for candidateIndex in sorted.prefix(12) {
                    let point = grid[candidateIndex]
                    let requested = residual[candidateIndex]
                    // No automatic band may exceed +6 dB boost or -12 dB cut.
                    // A 0.5–2 Q search allows broad corrections without very
                    // narrow resonant or overfit notches.
                    for q in [0.5, 1.0, 2.0] {
                        let band = HeadphoneCorrectionEQBand(
                            enabled: true, type: .peaking,
                            frequencyHz: point.frequencyHz,
                            gainDB: min(6, max(-12, requested)),
                            q: q
                        )
                        var proposed = bands
                        proposed.append(band)
                        let correction = HeadphoneChannelCorrection(
                            eqBands: proposed
                        )
                        var next = [Double]()
                        next.reserveCapacity(grid.count)
                        var valid = true
                        for (i, point) in grid.enumerated() {
                            guard let magnitude = HeadphoneEQResponsePreview.magnitudeDB(
                                correction, frequencyHz: point.frequencyHz,
                                sampleRate: sampleRate,
                                headroomAttenuationDB: 0
                            ) else { valid = false; break }
                            next.append(desired[i] - magnitude)
                        }
                        if valid {
                            let error = rmse(next)
                            if error + 0.035 < currentRMSE,
                               error < (best?.rmse ?? Double.infinity) {
                                best = (band, next, error)
                            }
                        }
                    }
                }
                guard let best else { break }
                bands.append(best.band)
                residual = best.residual
                currentRMSE = best.rmse
            }
            let maxRegression = zip(residual, desired).map {
                abs($0.0) - abs($0.1)
            }.max() ?? 0
            return (bands, originalRMSE, currentRMSE, maxRegression)
        }
        let left = fitEar(\.leftMagnitudeDB)
        let right = fitEar(\.rightMagnitudeDB)
        let proposal = HeadphoneCorrectionProposal(
            schemaVersion: 1,
            headphoneModel: measurement.headphoneModel,
            sourceName: measurement.sourceName,
            sourceAttribution: measurement.sourceAttribution,
            sourceLicense: measurement.sourceLicense,
            referenceSampleRate: sampleRate,
            leftBands: left.bands,
            rightBands: right.bands
        )
        try proposal.validate(sampleRate: sampleRate)
        var draft = HeadphoneDeviceProfileConfiguration()
        try draft.stageLocalProposal(proposal, sampleRate: sampleRate)
        let headroom = draft.conservativeRequiredHeadroomDB
        let worst = max(left.worst, right.worst)
        var warnings = [String]()
        if worst > 2 {
            warnings.append("At least one measured frequency would regress by over 2 dB; review the proposed bands manually.")
        }
        if headroom > 6 {
            warnings.append("Conservative positive gains require more than 6 dB digital attenuation.")
        }
        if left.after >= left.before || right.after >= right.before {
            warnings.append("At least one ear received no modeled target-error improvement.")
        }
        warnings.append("Model-based response fitting is not individual ear calibration. Verify actual seal, coupling, licensing and safe listening levels.")
        return HeadphoneModelFitResult(
            headphoneModel: measurement.headphoneModel,
            proposal: proposal,
            leftRMSEBeforeDB: left.before,
            rightRMSEBeforeDB: right.before,
            leftRMSEAfterDB: left.after,
            rightRMSEAfterDB: right.after,
            worstFrequencyRegressionDB: worst,
            recommendedHeadroomDB: headroom,
            warnings: warnings
        )
    }
}

/// Local App Support library only. Does not fetch, index third-party web
/// sources, bundle user profiles into the shipped app, or assert data rights.
/// Storage is bounded; raw imported data keeps the supplied attribution.
struct HeadphoneModelMeasurementLibrary: Sendable {
    var rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0]
                .appendingPathComponent("Notch Sixty", isDirectory: true)
                .appendingPathComponent("Headphone Model Measurements", isDirectory: true)
        }
    }

    func importFile(_ url: URL, sampleRate: Double) throws
        -> HeadphoneModelMeasurement {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = (attrs[.size] as? NSNumber)?.intValue,
              (1...128_000).contains(bytes) else {
            throw OptionalAcousticResearchError.excessiveFileSize
        }
        var model = try JSONDecoder().decode(
            HeadphoneModelMeasurement.self,
            from: Data(contentsOf: url)
        )
        try model.validate(sampleRate: sampleRate)
        model.id = UUID() // Never let untrusted uploaded IDs overwrite storage.
        try save(model, sampleRate: sampleRate)
        return model
    }

    func save(_ model: HeadphoneModelMeasurement, sampleRate: Double) throws {
        try model.validate(sampleRate: sampleRate)
        let data = try JSONEncoder().encode(model)
        guard data.count <= 128_000 else {
            throw OptionalAcousticResearchError.excessiveFileSize
        }
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true
        )
        try data.write(to: rootURL.appendingPathComponent(
            model.id.uuidString + ".n60headphonemodel"), options: .atomic)
    }

    func list(sampleRate: Double) throws -> [HeadphoneModelMeasurement] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "n60headphonemodel" }
        guard urls.count <= 256 else {
            throw OptionalAcousticResearchError.invalidEvidence
        }
        return try urls.compactMap { url in
            let attrs = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            guard let bytes = (attrs[.size] as? NSNumber)?.intValue,
                  (1...128_000).contains(bytes) else {
                throw OptionalAcousticResearchError.excessiveFileSize
            }
            let model = try JSONDecoder().decode(
                HeadphoneModelMeasurement.self,
                from: Data(contentsOf: url)
            )
            try model.validate(sampleRate: sampleRate)
            return model
        }.sorted { $0.headphoneModel < $1.headphoneModel }
    }
}
