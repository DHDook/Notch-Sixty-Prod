import Combine
import Foundation

enum RoomCorrectionSpatialAggregationError: Error, Equatable, LocalizedError {
    case noIncludedPositions
    case zeroTotalWeight
    case invalidWeight(positionID: UUID)
    case sampleRateMismatch(positionID: UUID)
    case missingTransferFunction(positionID: UUID, pass: RoomCorrectionMeasurementPass)
    case incompatibleFrequencyGrid(positionID: UUID, pass: RoomCorrectionMeasurementPass)
    case invalidResponse(positionID: UUID, pass: RoomCorrectionMeasurementPass)

    var errorDescription: String? {
        switch self {
        case .noIncludedPositions:
            return "No room-measurement positions are included in the aggregate."
        case .zeroTotalWeight:
            return "Included room-measurement positions have zero total weight."
        case .invalidWeight(let positionID):
            return "Room-measurement position \(positionID.uuidString) has an invalid weight."
        case .sampleRateMismatch(let positionID):
            return "Room-measurement position \(positionID.uuidString) uses a different sample rate."
        case .missingTransferFunction(let positionID, let pass):
            return "Room-measurement position \(positionID.uuidString) has no \(pass.rawValue) transfer function."
        case .incompatibleFrequencyGrid(let positionID, let pass):
            return "Room-measurement position \(positionID.uuidString) has an incompatible \(pass.rawValue) frequency grid."
        case .invalidResponse(let positionID, let pass):
            return "Room-measurement position \(positionID.uuidString) has invalid \(pass.rawValue) response data."
        }
    }
}

/// Spatial aggregation deliberately works in the logarithmic magnitude domain.
/// Phase/timing remain attached to each seat measurement and are never averaged
/// as unrelated complex spectra across listening positions.
struct RoomCorrectionSpatialAggregator: Sendable {
    func aggregate(
        positions: [RoomCorrectionMeasurementPosition],
        generatedAt: Date = Date()
    ) throws -> RoomCorrectionAggregateResponse {
        let included = positions.filter(\.included)
        guard !included.isEmpty else {
            throw RoomCorrectionSpatialAggregationError.noIncludedPositions
        }

        for position in included {
            guard position.weight.isFinite, position.weight >= 0 else {
                throw RoomCorrectionSpatialAggregationError.invalidWeight(positionID: position.id)
            }
        }

        let contributors = included.filter { $0.weight > 0 }
        let totalWeight = contributors.reduce(0) { $0 + $1.weight }
        guard totalWeight.isFinite, totalWeight > 0 else {
            throw RoomCorrectionSpatialAggregationError.zeroTotalWeight
        }
        guard let referencePosition = contributors.first else {
            throw RoomCorrectionSpatialAggregationError.zeroTotalWeight
        }

        for position in contributors.dropFirst() {
            guard abs(position.sampleRate - referencePosition.sampleRate) < 0.5 else {
                throw RoomCorrectionSpatialAggregationError.sampleRateMismatch(positionID: position.id)
            }
        }

        let left = try aggregatePass(
            .left,
            contributors: contributors,
            totalWeight: totalWeight
        )
        let right = try aggregatePass(
            .right,
            contributors: contributors,
            totalWeight: totalWeight
        )

        return RoomCorrectionAggregateResponse(
            generatedAt: generatedAt,
            includedPositionIDs: included.map(\.id),
            leftResponse: left,
            rightResponse: right
        )
    }

    private func aggregatePass(
        _ pass: RoomCorrectionMeasurementPass,
        contributors: [RoomCorrectionMeasurementPosition],
        totalWeight: Double
    ) throws -> RoomCorrectionFrequencyResponse {
        guard let first = contributors.first else {
            throw RoomCorrectionSpatialAggregationError.zeroTotalWeight
        }
        let reference = try response(for: first, pass: pass)
        try validateResponse(reference, positionID: first.id, pass: pass)

        var weightedMagnitude = [Double](repeating: 0, count: reference.magnitudeDB.count)
        for position in contributors {
            let response = try response(for: position, pass: pass)
            try validateResponse(response, positionID: position.id, pass: pass)
            guard frequencyGridsMatch(reference.frequenciesHz, response.frequenciesHz) else {
                throw RoomCorrectionSpatialAggregationError.incompatibleFrequencyGrid(
                    positionID: position.id,
                    pass: pass
                )
            }
            let normalizedWeight = position.weight / totalWeight
            for index in weightedMagnitude.indices {
                weightedMagnitude[index] += response.magnitudeDB[index] * normalizedWeight
            }
        }

        return RoomCorrectionFrequencyResponse(
            frequenciesHz: reference.frequenciesHz,
            magnitudeDB: weightedMagnitude,
            phaseRadians: nil
        )
    }

    private func response(
        for position: RoomCorrectionMeasurementPosition,
        pass: RoomCorrectionMeasurementPass
    ) throws -> RoomCorrectionFrequencyResponse {
        let response: RoomCorrectionFrequencyResponse?
        switch pass {
        case .left: response = position.left.transferFunction
        case .right: response = position.right.transferFunction
        }
        guard let response else {
            throw RoomCorrectionSpatialAggregationError.missingTransferFunction(
                positionID: position.id,
                pass: pass
            )
        }
        return response
    }

    private func validateResponse(
        _ response: RoomCorrectionFrequencyResponse,
        positionID: UUID,
        pass: RoomCorrectionMeasurementPass
    ) throws {
        guard !response.frequenciesHz.isEmpty,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 }),
              response.magnitudeDB.allSatisfy(\.isFinite) else {
            throw RoomCorrectionSpatialAggregationError.invalidResponse(
                positionID: positionID,
                pass: pass
            )
        }

        var previous = 0.0
        for frequency in response.frequenciesHz {
            guard frequency > previous else {
                throw RoomCorrectionSpatialAggregationError.invalidResponse(
                    positionID: positionID,
                    pass: pass
                )
            }
            previous = frequency
        }
    }

    private func frequencyGridsMatch(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            let tolerance = max(1.0e-6, abs(lhs[index]) * 1.0e-9)
            if abs(lhs[index] - rhs[index]) > tolerance { return false }
        }
        return true
    }
}

enum RoomCorrectionProjectControllerError: Error, Equatable, LocalizedError {
    case noSelectedPlaybackSystem
    case projectPlaybackSystemMismatch(expected: UUID, actual: UUID)
    case incompatibleSweepSettings
    case incompatibleMicrophone
    case analysisSampleRateMismatch(expected: Double, actual: Double)
    case invalidPositionName
    case invalidWeight(Double)
    case positionNotFound(UUID)
    case measurementAlreadyRetained

    var errorDescription: String? {
        switch self {
        case .noSelectedPlaybackSystem:
            return "Select a Playback System before saving room measurements."
        case .projectPlaybackSystemMismatch(let expected, let actual):
            return "Room-correction project belongs to Playback System \(actual.uuidString), not \(expected.uuidString)."
        case .incompatibleSweepSettings:
            return "This measurement used different sweep settings. Start a new room-correction project before combining it with these positions."
        case .incompatibleMicrophone:
            return "This measurement used a different microphone, input channel, or calibration curve. Start a new project before combining it with these positions."
        case .analysisSampleRateMismatch(let expected, let actual):
            return "Analyzed measurement rate \(actual) Hz does not match the project sweep rate \(expected) Hz."
        case .invalidPositionName:
            return "Listening-position name cannot be empty."
        case .invalidWeight(let weight):
            return "Listening-position weight \(weight) is invalid."
        case .positionNotFound(let id):
            return "Listening position \(id.uuidString) was not found."
        case .measurementAlreadyRetained:
            return "This analyzed measurement is already saved in the current project."
        }
    }
}

@MainActor
final class RoomCorrectionProjectController: ObservableObject {
    let profiles: ProductProfileController
    let store: RoomCorrectionProjectStore

    private let aggregator = RoomCorrectionSpatialAggregator()

    @Published private(set) var project: RoomCorrectionProject?
    @Published private(set) var lastErrorDescription: String?

    init(
        profiles: ProductProfileController,
        store: RoomCorrectionProjectStore = RoomCorrectionProjectStore()
    ) {
        self.profiles = profiles
        self.store = store
    }

    var selectedPlaybackSystemID: UUID? { profiles.selectedSystemProfileID }
    var selectedPlaybackSystemName: String { profiles.selectedSystemProfileName }

    var positions: [RoomCorrectionMeasurementPosition] {
        project?.measurements ?? []
    }

    var aggregate: RoomCorrectionAggregateResponse? { project?.aggregate }

    func prepareForUse() {
        do {
            try reloadForSelectedPlaybackSystem()
            lastErrorDescription = nil
        } catch {
            project = nil
            lastErrorDescription = error.localizedDescription
        }
    }

    func reloadForSelectedPlaybackSystem() throws {
        guard let systemID = selectedPlaybackSystemID else {
            project = nil
            throw RoomCorrectionProjectControllerError.noSelectedPlaybackSystem
        }

        if project?.playbackSystemID == systemID { return }

        if let projectID = profiles.selectedSystemProfile?.state.roomCorrectionCalibration?.projectID {
            let loaded = try store.load(projectID)
            guard loaded.playbackSystemID == systemID else {
                throw RoomCorrectionProjectControllerError.projectPlaybackSystemMismatch(
                    expected: systemID,
                    actual: loaded.playbackSystemID
                )
            }
            project = loaded
            lastErrorDescription = nil
            return
        }

        var candidates: [RoomCorrectionProject] = []
        for id in try store.existingProjectIDs() {
            guard let loaded = try? store.load(id), loaded.playbackSystemID == systemID else { continue }
            candidates.append(loaded)
        }
        project = candidates.max { lhs, rhs in lhs.modifiedAt < rhs.modifiedAt }
        lastErrorDescription = nil
    }

    func contains(_ analysis: RoomCorrectionMeasurementAnalysis) -> Bool {
        guard let project else { return false }
        return project.measurements.contains {
            $0.left.capturedAt == analysis.left.capturedAt
                && $0.right.capturedAt == analysis.right.capturedAt
        }
    }

    @discardableResult
    func retainMeasurement(
        _ analysis: RoomCorrectionMeasurementAnalysis,
        sweep: RoomCorrectionSweepSettings,
        microphone: RoomCorrectionMicrophone,
        name proposedName: String? = nil,
        retainedAt: Date = Date()
    ) throws -> UUID {
        guard let systemID = selectedPlaybackSystemID else {
            throw RoomCorrectionProjectControllerError.noSelectedPlaybackSystem
        }
        guard abs(analysis.sampleRate - sweep.sampleRate) < 0.5 else {
            throw RoomCorrectionProjectControllerError.analysisSampleRateMismatch(
                expected: sweep.sampleRate,
                actual: analysis.sampleRate
            )
        }
        guard !contains(analysis) else {
            throw RoomCorrectionProjectControllerError.measurementAlreadyRetained
        }

        var updated = try projectForMutation(
            systemID: systemID,
            sweep: sweep,
            microphone: microphone,
            now: retainedAt
        )
        let name = try normalizedPositionName(
            proposedName ?? Self.defaultPositionName(index: updated.measurements.count)
        )
        let position = RoomCorrectionMeasurementPosition(
            name: name,
            included: true,
            weight: 1,
            sampleRate: analysis.sampleRate,
            left: analysis.left,
            right: analysis.right
        )
        updated.measurements.append(position)
        updated.modifiedAt = retainedAt
        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: retainedAt)
        try persistAndPublish(updated)
        return position.id
    }

    func renameMeasurement(id: UUID, to proposedName: String, modifiedAt: Date = Date()) throws {
        var updated = try requiredProject()
        guard let index = updated.measurements.firstIndex(where: { $0.id == id }) else {
            throw RoomCorrectionProjectControllerError.positionNotFound(id)
        }
        updated.measurements[index].name = try normalizedPositionName(proposedName)
        updated.modifiedAt = modifiedAt
        try persistAndPublish(updated)
    }

    func setMeasurementIncluded(id: UUID, included: Bool, modifiedAt: Date = Date()) throws {
        var updated = try requiredProject()
        guard let index = updated.measurements.firstIndex(where: { $0.id == id }) else {
            throw RoomCorrectionProjectControllerError.positionNotFound(id)
        }
        updated.measurements[index].included = included
        updated.modifiedAt = modifiedAt
        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)
        try persistAndPublish(updated)
    }

    func setMeasurementWeight(id: UUID, weight: Double, modifiedAt: Date = Date()) throws {
        guard weight.isFinite, weight >= 0 else {
            throw RoomCorrectionProjectControllerError.invalidWeight(weight)
        }
        var updated = try requiredProject()
        guard let index = updated.measurements.firstIndex(where: { $0.id == id }) else {
            throw RoomCorrectionProjectControllerError.positionNotFound(id)
        }
        updated.measurements[index].weight = weight
        updated.modifiedAt = modifiedAt
        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)
        try persistAndPublish(updated)
    }

    private func projectForMutation(
        systemID: UUID,
        sweep: RoomCorrectionSweepSettings,
        microphone: RoomCorrectionMicrophone,
        now: Date
    ) throws -> RoomCorrectionProject {
        var result: RoomCorrectionProject
        if let existing = project {
            guard existing.playbackSystemID == systemID else {
                throw RoomCorrectionProjectControllerError.projectPlaybackSystemMismatch(
                    expected: systemID,
                    actual: existing.playbackSystemID
                )
            }
            result = existing
        } else {
            result = RoomCorrectionProject(
                playbackSystemID: systemID,
                name: "\(selectedPlaybackSystemName) Room Correction",
                createdAt: now,
                modifiedAt: now
            )
        }

        if let existingSweep = result.sweep, existingSweep != sweep {
            throw RoomCorrectionProjectControllerError.incompatibleSweepSettings
        }
        if let existingMicrophone = result.microphone {
            guard Self.microphonesAreCompatible(existingMicrophone, microphone) else {
                throw RoomCorrectionProjectControllerError.incompatibleMicrophone
            }
        }

        result.sweep = sweep
        if result.microphone == nil {
            result.microphone = microphone
        } else {
            // Keep stable identity/calibration but refresh a user-visible device name.
            result.microphone?.displayName = microphone.displayName
        }
        return result
    }

    private func requiredProject() throws -> RoomCorrectionProject {
        guard let systemID = selectedPlaybackSystemID else {
            throw RoomCorrectionProjectControllerError.noSelectedPlaybackSystem
        }
        guard let project else {
            throw RoomCorrectionProjectControllerError.noSelectedPlaybackSystem
        }
        guard project.playbackSystemID == systemID else {
            throw RoomCorrectionProjectControllerError.projectPlaybackSystemMismatch(
                expected: systemID,
                actual: project.playbackSystemID
            )
        }
        return project
    }

    private func aggregateOrNil(
        _ positions: [RoomCorrectionMeasurementPosition],
        generatedAt: Date
    ) throws -> RoomCorrectionAggregateResponse? {
        do {
            return try aggregator.aggregate(positions: positions, generatedAt: generatedAt)
        } catch RoomCorrectionSpatialAggregationError.noIncludedPositions {
            return nil
        } catch RoomCorrectionSpatialAggregationError.zeroTotalWeight {
            return nil
        }
    }

    private func persistAndPublish(_ updated: RoomCorrectionProject) throws {
        try store.save(updated)
        project = updated
        lastErrorDescription = nil
    }

    private func normalizedPositionName(_ proposedName: String) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RoomCorrectionProjectControllerError.invalidPositionName
        }
        return trimmed
    }

    private static func defaultPositionName(index: Int) -> String {
        switch index {
        case 0: return "Center"
        case 1: return "Left"
        case 2: return "Right"
        default: return "Position \(index + 1)"
        }
    }

    private static func microphonesAreCompatible(
        _ lhs: RoomCorrectionMicrophone,
        _ rhs: RoomCorrectionMicrophone
    ) -> Bool {
        lhs.stableID == rhs.stableID
            && lhs.inputChannelIndex == rhs.inputChannelIndex
            && lhs.calibration == rhs.calibration
    }
}
