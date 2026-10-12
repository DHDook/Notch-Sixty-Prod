import Combine
import Foundation

/// Session-scoped, read-only ownership for the Room Advisor.
///
/// This controller deliberately has no preset/profile-controller dependency.
/// It reads Room Correction projects directly from their store so selecting a
/// project here cannot select or mutate a Playback System.
@MainActor
final class RoomTreatmentAdvisorController: ObservableObject {
    let store: RoomCorrectionProjectStore
    let geometryStore: RoomGeometryStore
    let advancedPlacementStore: RoomAdvancedPlacementStore
    private let advancedPlacementExplorer = RoomAdvancedPlacementExplorer()
    let treatmentStore: RoomPassiveTreatmentStore
    private let treatmentDesigner = RoomPassiveTreatmentDesigner()
    private let treatmentVerifier = RoomTreatmentVerifier()
    private let analyzer = RoomTreatmentAdvisorAnalyzer()
    private let geometryAnalyzer =
        RoomGeometryPlacementAnalyzer()

    @Published private(set) var availableProjects:
        [RoomCorrectionProject] = []
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedProject:
        RoomCorrectionProject?
    @Published private(set) var report:
        RoomTreatmentAdvisorReport?
    @Published var geometryDraft: RoomGeometryModel?
    @Published private(set) var savedGeometry:
        RoomGeometryModel?
    @Published private(set) var geometryAnalysis:
        RoomGeometryAnalysis?
    @Published private(set) var geometryValidationMessage:
        String?
    @Published private(set) var advancedPlacementDraft: RoomAdvancedPlacementSettings?
    @Published private(set) var savedAdvancedPlacement: RoomAdvancedPlacementSettings?
    @Published private(set) var advancedPlacementExperiments: [RoomAdvancedPlacementExperiment] = []
    @Published private(set) var selectedAdvancedExperiment: RoomAdvancedPlacementExperiment?
    @Published private(set) var advancedPlacementMessage: String?
    @Published private(set) var toeInMeasurementEvidence: [RoomAdvancedToeInEvidence] = []
    @Published private(set) var toeInEvidenceMessage: String?
    @Published private(set) var availablePhysicalSubSets: [SpeakerOptimizerMeasurementSet] = []
    @Published var physicalSubBaselineID: UUID?
    @Published var physicalSubCandidateID: UUID?
    @Published private(set) var physicalSubComparison: RoomAdvancedSubPlacementComparison?
    @Published private(set) var physicalSubComparisonMessage: String?
    @Published var treatmentDraft: RoomPassiveTreatmentPlan?
    @Published private(set) var savedTreatmentPlan: RoomPassiveTreatmentPlan?
    @Published private(set) var treatmentAnalysis: RoomPassiveTreatmentDesignSummary?
    @Published private(set) var treatmentMessage: String?
    @Published private(set) var verificationReport: RoomTreatmentVerificationReport?
    @Published var verificationFollowUpID: UUID?
    @Published private(set) var lastErrorDescription: String?

    init(store: RoomCorrectionProjectStore) {
        self.store = store
        self.geometryStore =
            RoomGeometryStore(projectStore: store)
        self.advancedPlacementStore =
            RoomAdvancedPlacementStore(projectStore: store)
        self.treatmentStore = RoomPassiveTreatmentStore(projectStore: store)
    }

    var treatmentHasUnsavedChanges: Bool {
        treatmentDraft != savedTreatmentPlan
    }

    var canEditTreatment: Bool {
        geometryDraft != nil &&
        geometryDraft == savedGeometry &&
        selectedProjectID != nil
    }

    var treatmentFollowUpProjects: [RoomCorrectionProject] {
        availableProjects.filter { $0.id != selectedProjectID }
    }

    var geometryHasUnsavedChanges: Bool {
        geometryDraft != savedGeometry
    }

    var advancedPlacementHasUnsavedChanges: Bool {
        advancedPlacementDraft != savedAdvancedPlacement
    }

    func prepareForUse() {
        reloadProjects()
    }

    func reloadProjects() {
        do {
            let ids = try store.existingProjectIDs()
            var loaded: [RoomCorrectionProject] = []
            var firstError: Error?
            for id in ids {
                do {
                    loaded.append(try store.load(id))
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            loaded.sort {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.name.localizedStandardCompare(
                    $1.name
                ) == .orderedAscending
            }
            availableProjects = loaded

            let preferredID: UUID?
            if let selectedProjectID,
               loaded.contains(where: {
                   $0.id == selectedProjectID
               }) {
                preferredID = selectedProjectID
            } else {
                preferredID = loaded.first?.id
            }
            selectProject(preferredID)

            if loaded.isEmpty, let firstError {
                lastErrorDescription =
                    firstError.localizedDescription
            } else {
                lastErrorDescription = nil
            }
        } catch {
            availableProjects = []
            selectedProjectID = nil
            selectedProject = nil
            report = nil
            treatmentDraft = nil
            savedTreatmentPlan = nil
            treatmentAnalysis = nil
            verificationReport = nil
            lastErrorDescription = error.localizedDescription
        }
    }

    func selectProject(_ id: UUID?) {
        selectedProjectID = id
        availablePhysicalSubSets = []
        physicalSubBaselineID = nil
        physicalSubCandidateID = nil
        physicalSubComparison = nil
        physicalSubComparisonMessage = nil
        guard let id,
              let project = availableProjects.first(
                where: { $0.id == id }
              ) else {
            selectedProject = nil
            report = nil
            geometryDraft = nil
            savedGeometry = nil
            geometryAnalysis = nil
            geometryValidationMessage = nil
            advancedPlacementDraft = nil
            savedAdvancedPlacement = nil
            advancedPlacementExperiments = []
            selectedAdvancedExperiment = nil
            advancedPlacementMessage = nil
            toeInMeasurementEvidence = []
            toeInEvidenceMessage = nil
            treatmentDraft = nil
            savedTreatmentPlan = nil
            treatmentAnalysis = nil
            treatmentMessage = nil
            verificationFollowUpID = nil
            verificationReport = nil
            return
        }
        selectedProject = project
        report = analyzer.analyze(project: project)
        loadGeometry(for: project.id)
        loadAdvancedPlacement(for: project.id)
        loadTreatment(for: project.id)
        verificationFollowUpID = nil
        verificationReport = nil
    }

    func startGeometryTemplate() {
        guard let projectID = selectedProjectID else {
            geometryValidationMessage =
                RoomGeometryError.noSelectedProject
                    .localizedDescription
            return
        }
        let model =
            RoomGeometryModel.template(
                projectID: projectID
            )
        geometryDraft = model
        geometryValidationMessage = nil
        advancedPlacementDraft = RoomAdvancedPlacementSettings(projectID: projectID)
        savedAdvancedPlacement = nil
        refreshGeometryPreview()
    }

    func setGeometryValue(
        _ keyPath:
            WritableKeyPath<RoomGeometryModel, Double>,
        _ value: Double
    ) {
        guard var model = geometryDraft else {
            return
        }
        model[keyPath: keyPath] = value
        model.modifiedAt = Date()
        geometryDraft = model
        refreshGeometryPreview()
    }

    func replaceGeometryDraft(
        _ model: RoomGeometryModel
    ) {
        guard model.projectID == selectedProjectID else {
            geometryValidationMessage =
                RoomGeometryError.projectMismatch
                    .localizedDescription
            return
        }
        geometryDraft = model
        refreshGeometryPreview()
    }

    func previewPlacementCandidate(
        _ candidate: RoomPlacementCandidate
    ) {
        guard var model = geometryDraft else {
            geometryValidationMessage =
                RoomGeometryError.noGeometry
                    .localizedDescription
            return
        }
        model.listener = candidate.listener
        model.leftSpeaker = candidate.leftSpeaker
        model.rightSpeaker = candidate.rightSpeaker
        model.modifiedAt = Date()
        geometryDraft = model
        refreshGeometryPreview()
    }

    func saveGeometry() {
        guard var model = geometryDraft else {
            geometryValidationMessage =
                RoomGeometryError.noGeometry
                    .localizedDescription
            return
        }
        guard model.projectID == selectedProjectID else {
            geometryValidationMessage =
                RoomGeometryError.projectMismatch
                    .localizedDescription
            return
        }
        model.modifiedAt = Date()
        do {
            let valid = try model.validated()
            try geometryStore.save(valid)
            geometryDraft = valid
            savedGeometry = valid
            geometryValidationMessage = nil
            refreshGeometryPreview()
            refreshTreatmentAnalysis()
        } catch {
            geometryValidationMessage =
                error.localizedDescription
        }
    }

    func revertGeometry() {
        geometryDraft = savedGeometry
        geometryValidationMessage = nil
        refreshGeometryPreview()
    }

    func clearGeometry() {
        guard let projectID = selectedProjectID else {
            return
        }
        do {
            try advancedPlacementStore.delete(projectID: projectID)
            try geometryStore.delete(
                projectID: projectID
            )
            geometryDraft = nil
            savedGeometry = nil
            geometryAnalysis = nil
            geometryValidationMessage = nil
            advancedPlacementDraft = nil
            savedAdvancedPlacement = nil
            advancedPlacementExperiments = []
            selectedAdvancedExperiment = nil
            advancedPlacementMessage = nil
            treatmentAnalysis = nil
            treatmentMessage = "Geometry was cleared. Save room geometry before editing physical treatment."
        } catch {
            geometryValidationMessage =
                error.localizedDescription
        }
    }

    private func loadGeometry(for projectID: UUID) {
        do {
            let loaded =
                try geometryStore.load(
                    projectID: projectID
                )
            geometryDraft = loaded
            savedGeometry = loaded
            geometryValidationMessage = nil
            refreshGeometryPreview()
        } catch {
            geometryDraft = nil
            savedGeometry = nil
            geometryAnalysis = nil
            geometryValidationMessage =
                error.localizedDescription
        }
    }


    // MARK: - PR110 project-only advanced placement planning

    private func loadAdvancedPlacement(for projectID: UUID) {
        advancedPlacementExperiments = []
        selectedAdvancedExperiment = nil
        guard let room = geometryDraft else {
            advancedPlacementDraft = nil
            savedAdvancedPlacement = nil
            advancedPlacementMessage = nil
            return
        }
        do {
            let loaded = try advancedPlacementStore.load(
                projectID: projectID, room: room
            )
            advancedPlacementDraft = loaded ??
                RoomAdvancedPlacementSettings(projectID: projectID)
            savedAdvancedPlacement = loaded
            advancedPlacementMessage = nil
        } catch {
            advancedPlacementDraft =
                RoomAdvancedPlacementSettings(projectID: projectID)
            savedAdvancedPlacement = nil
            advancedPlacementMessage = error.localizedDescription
        }
        refreshAdvancedPlacementPreview()
    }

    private func changeAdvancedPlacement(
        _ changed: RoomAdvancedPlacementSettings
    ) {
        guard let room = geometryDraft else { return }
        do {
            _ = try changed.state(for: room)
            advancedPlacementDraft = changed
            advancedPlacementMessage = nil
            refreshAdvancedPlacementPreview()
        } catch {
            advancedPlacementMessage = error.localizedDescription
        }
    }

    func setAdvancedToeIn(
        _ side: RoomGeometrySpeaker, degrees: Double
    ) {
        guard var next = advancedPlacementDraft else { return }
        if side == .left {
            next.leftToeInDegrees = degrees
        } else {
            next.rightToeInDegrees = degrees
        }
        changeAdvancedPlacement(next)
    }

    func addAdvancedSeat() {
        guard var next = advancedPlacementDraft,
              let room = geometryDraft,
              next.secondarySeats.count < 7 else { return }
        next.secondarySeats.append(room.listener)
        changeAdvancedPlacement(next)
    }

    func addAdvancedSubwoofer() {
        guard var next = advancedPlacementDraft,
              let room = geometryDraft,
              next.subwooferPositions.count < 4 else { return }
        next.subwooferPositions.append(
            RoomGeometryPoint3D(
                x: room.leftSpeaker.x,
                y: room.leftSpeaker.y,
                z: 0.2
            )
        )
        changeAdvancedPlacement(next)
    }

    func removeAdvancedPosition(isSubwoofer: Bool, index: Int) {
        guard var next = advancedPlacementDraft else { return }
        if isSubwoofer {
            guard next.subwooferPositions.indices.contains(index) else { return }
            next.subwooferPositions.remove(at: index)
        } else {
            guard next.secondarySeats.indices.contains(index) else { return }
            next.secondarySeats.remove(at: index)
        }
        changeAdvancedPlacement(next)
    }

    func setAdvancedPositionCoordinate(
        isSubwoofer: Bool, index: Int,
        keyPath: WritableKeyPath<RoomGeometryPoint3D, Double>,
        value: Double
    ) {
        guard var next = advancedPlacementDraft else { return }
        if isSubwoofer {
            guard next.subwooferPositions.indices.contains(index) else { return }
            next.subwooferPositions[index][keyPath: keyPath] = value
        } else {
            guard next.secondarySeats.indices.contains(index) else { return }
            next.secondarySeats[index][keyPath: keyPath] = value
        }
        changeAdvancedPlacement(next)
    }

    func previewAdvancedExperiment(
        _ proposal: RoomAdvancedPlacementExperiment
    ) {
        guard advancedPlacementExperiments.contains(proposal) else {
            advancedPlacementMessage =
                "This placement trial is stale. Regenerate from current geometry."
            return
        }
        // Intentionally never mutates saved OR draft geometry, settings, DSP
        // or calibration. Only displays what the person could physically move.
        selectedAdvancedExperiment = proposal
        physicalSubComparison = nil
        physicalSubComparisonMessage = nil
    }

    func saveAdvancedPlacement() {
        guard let room = geometryDraft,
              room == savedGeometry,
              let settings = advancedPlacementDraft,
              settings.projectID == selectedProjectID else {
            advancedPlacementMessage =
                "Save the actual room geometry before saving advanced placement."
            return
        }
        do {
            try advancedPlacementStore.save(settings, room: room)
            savedAdvancedPlacement = settings
            advancedPlacementMessage = nil
        } catch {
            advancedPlacementMessage = error.localizedDescription
        }
    }

    func revertAdvancedPlacement() {
        guard let projectID = selectedProjectID else { return }
        advancedPlacementDraft = savedAdvancedPlacement ??
            RoomAdvancedPlacementSettings(projectID: projectID)
        advancedPlacementMessage = nil
        refreshAdvancedPlacementPreview()
    }

    /// Explicit read-only lab linkage. A single latest matching Lab session
    /// must qualify, and the user must confirm geometry/hardware have not
    /// moved since its measurement. No cross-session inference.
    func inspectRecentDirectivity(
        physicalGeometryMatchesCapture: Bool
    ) {
        toeInMeasurementEvidence = []
        guard physicalGeometryMatchesCapture,
              let project = selectedProject,
              let room = geometryDraft,
              room == savedGeometry,
              let settings = advancedPlacementDraft,
              settings == savedAdvancedPlacement else {
            toeInEvidenceMessage =
                "Save and confirm unchanged physical room/speaker geometry since the Lab capture before comparing toe-in."
            return
        }
        do {
            let state = try settings.state(for: room)
            let sessions = try SpeakerMeasurementLabSessionStore()
                .listRecentSessions(limit: 24)
                .filter { $0.playbackSystemID == project.playbackSystemID }
            let analyzer = RoomAdvancedToeInEvidenceAnalyzer()
            for session in sessions {
                var matched: [RoomAdvancedToeInEvidence] = []
                for speaker in RoomGeometrySpeaker.allCases {
                    let source: MultichannelCalibrationSource = .speaker(
                        speaker == .left ? .frontLeft : .frontRight
                    )
                    for protocolItem in session.protocols where
                        protocolItem.request.mode == .wholeSpeakerOnAxis
                        && protocolItem.acousticSource == source {
                        if let trials = try? analyzer.evaluate(
                            state: state,
                            playbackSystemID: project.playbackSystemID,
                            session: session,
                            onAxisProtocolID: protocolItem.id,
                            speaker: speaker
                        ) {
                            matched.append(contentsOf: trials)
                            break
                        }
                    }
                }
                if !matched.isEmpty {
                    toeInMeasurementEvidence = matched.sorted {
                        if $0.status != $1.status {
                            return $0.status == .measuredComparison
                        }
                        if let lhs = $0.indicatedSpectralChangeDB,
                           let rhs = $1.indicatedSpectralChangeDB,
                           lhs != rhs { return lhs > rhs }
                        return $0.experimentID < $1.experimentID
                    }
                    toeInEvidenceMessage = matched.contains {
                        $0.status == .measuredComparison
                    } ? "Repeat-qualified Lab directivity evidence; ranking concerns on-axis spectral similarity only, NOT verified room response." :
                        "Lab data found, but neither toe-in trial has angular coverage for a supported comparison."
                    return
                }
            }
            toeInEvidenceMessage =
                "No recent whole-speaker on/off-axis Lab session passed source, microphone, radius, routing and repeat-quality gates for this Playback System."
        } catch {
            toeInEvidenceMessage = error.localizedDescription
        }
    }

    /// Scan local compact PR103 measurement archives, never initiate a sweep
    /// or modify correction/physical routing. The user explicitly picks
    /// BEFORE/AFTER physical Sub capture sets and confirms the matching seats.
    func refreshPhysicalSubMeasurementSets() {
        availablePhysicalSubSets = []
        physicalSubComparison = nil
        physicalSubComparisonMessage = nil
        guard let project = selectedProject else { return }
        do {
            availablePhysicalSubSets = try SpeakerOptimizerMeasurementSetStore()
                .listRecentSets(limit: 64).filter { set in
                    guard set.playbackSystemID == project.playbackSystemID,
                          set.plannedSources.count == 1 else { return false }
                    if case .subwoofer = set.plannedSources[0] {
                        return true
                    }
                    return false
                }
        } catch {
            physicalSubComparisonMessage = error.localizedDescription
        }
    }

    func clearPhysicalSubComparison() {
        physicalSubComparison = nil
        physicalSubComparisonMessage = nil
    }

    func comparePhysicalSubPlacement(
        identicalSeatsAndUnchangedSignalChainConfirmed: Bool
    ) {
        physicalSubComparison = nil
        guard let project = selectedProject,
              let room = geometryDraft, room == savedGeometry,
              let settings = advancedPlacementDraft,
              settings == savedAdvancedPlacement,
              let trial = selectedAdvancedExperiment,
              trial.move == .subwoofer,
              let baselineID = physicalSubBaselineID,
              let candidateID = physicalSubCandidateID,
              let baseline = availablePhysicalSubSets.first(
                where: { $0.id == baselineID }
              ),
              let candidate = availablePhysicalSubSets.first(
                where: { $0.id == candidateID }
              ) else {
            physicalSubComparisonMessage =
                "Save actual room geometry, inspect a physical Sub trial, and choose distinct baseline/candidate measurement sets."
            return
        }
        do {
            physicalSubComparison = try RoomAdvancedSubPlacementComparisonAnalyzer()
                .compare(
                    baseline: baseline,
                    candidate: candidate,
                    state: settings.state(for: room),
                    experiment: trial,
                    playbackSystemID: project.playbackSystemID,
                    physicalSetupConfirmed:
                        identicalSeatsAndUnchangedSignalChainConfirmed
                )
            physicalSubComparisonMessage =
                "Measured relative bass variation across seats; NOT verified SPL or preference. Real-world verification remains required."
        } catch {
            physicalSubComparisonMessage = error.localizedDescription
        }
    }

    private func refreshAdvancedPlacementPreview() {
        physicalSubComparison = nil
        physicalSubComparisonMessage = nil
        toeInMeasurementEvidence = []
        toeInEvidenceMessage = nil
        advancedPlacementExperiments = []
        selectedAdvancedExperiment = nil
        guard let room = geometryDraft,
              let settings = advancedPlacementDraft else { return }
        do {
            advancedPlacementExperiments = try advancedPlacementExplorer
                .experiments(for: settings.state(for: room))
        } catch {
            advancedPlacementMessage = error.localizedDescription
        }
    }

    private func refreshGeometryPreview() {
        guard let model = geometryDraft else {
            geometryAnalysis = nil
            treatmentAnalysis = nil
            return
        }
        do {
            geometryAnalysis =
                try geometryAnalyzer.analyze(
                    model: model,
                    advisorReport: report
                )
            geometryValidationMessage = nil
        } catch {
            geometryAnalysis = nil
            geometryValidationMessage =
                error.localizedDescription
        }
        refreshAdvancedPlacementPreview()
        refreshTreatmentAnalysis()
    }

    func createTreatmentPlan() {
        guard let id = selectedProjectID, canEditTreatment else {
            treatmentMessage = RoomPassiveTreatmentError.geometryRequired.localizedDescription
            return
        }
        treatmentDraft = RoomPassiveTreatmentPlan(projectID: id)
        treatmentMessage = nil
        refreshTreatmentAnalysis()
    }

    func addTreatmentSuggestion(_ suggestion: RoomPassiveTreatmentSuggestion) {
        guard var plan = treatmentDraft, let geometry = savedGeometry,
              canEditTreatment else { return }
        var item = suggestion.placement
        item.id = UUID()
        plan.placements.append(item)
        do {
            _ = try plan.validated(in: geometry)
            treatmentDraft = plan
            treatmentMessage = nil
            refreshTreatmentAnalysis()
        } catch {
            treatmentMessage = error.localizedDescription
        }
    }

    func addManualTreatment(kind: RoomPassiveTreatmentKind, surface: RoomGeometrySurface) {
        guard var plan = treatmentDraft, let geometry = savedGeometry,
              canEditTreatment else { return }
        let extent = RoomPassiveTreatmentPlacement.surfaceSize(surface, dimensions: geometry.dimensions)
        let new = RoomPassiveTreatmentPlacement(
            kind: kind, surface: surface, u: 0.5, v: 0.5,
            widthMeters: min(0.5, extent.0 * 0.4),
            heightMeters: min(0.5, extent.1 * 0.4),
            thicknessMeters: kind == .bassTrap ? 0.30 : 0.10,
            airGapMeters: 0.10
        )
        plan.placements.append(new)
        do {
            _ = try plan.validated(in: geometry)
            treatmentDraft = plan
            treatmentMessage = nil
            refreshTreatmentAnalysis()
        } catch { treatmentMessage = error.localizedDescription }
    }

    func updateTreatmentPlacement(_ changed: RoomPassiveTreatmentPlacement) {
        guard var plan = treatmentDraft,
              let index = plan.placements.firstIndex(where: { $0.id == changed.id })
        else { return }
        plan.placements[index] = changed
        treatmentDraft = plan
        refreshTreatmentAnalysis()
    }

    func removeTreatmentPlacement(_ id: UUID) {
        guard var plan = treatmentDraft else { return }
        plan.placements.removeAll { $0.id == id }
        treatmentDraft = plan
        refreshTreatmentAnalysis()
    }

    func saveTreatmentPlan() {
        guard var plan = treatmentDraft, let geometry = savedGeometry,
              canEditTreatment else {
            treatmentMessage = RoomPassiveTreatmentError.geometryRequired.localizedDescription
            return
        }
        plan.modifiedAt = Date()
        do {
            try treatmentStore.save(plan, geometry: geometry)
            treatmentDraft = plan
            savedTreatmentPlan = plan
            treatmentMessage = nil
            refreshTreatmentAnalysis()
        } catch { treatmentMessage = error.localizedDescription }
    }

    func revertTreatmentPlan() {
        treatmentDraft = savedTreatmentPlan
        treatmentMessage = nil
        refreshTreatmentAnalysis()
    }

    private func loadTreatment(for projectID: UUID) {
        treatmentDraft = nil
        savedTreatmentPlan = nil
        treatmentAnalysis = nil
        treatmentMessage = nil
        guard let geometry = savedGeometry else { return }
        do {
            let plan = try treatmentStore.load(projectID: projectID, geometry: geometry)
            treatmentDraft = plan
            savedTreatmentPlan = plan
            refreshTreatmentAnalysis()
        } catch {
            treatmentMessage = error.localizedDescription
        }
    }

    private func refreshTreatmentAnalysis() {
        guard let plan = treatmentDraft,
              let geometry = geometryDraft,
              let report,
              let geometryAnalysis else {
            treatmentAnalysis = nil
            return
        }
        do {
            treatmentAnalysis = try treatmentDesigner.evaluate(
                plan: plan, geometry: geometry,
                report: report, predictions: geometryAnalysis
            )
            treatmentMessage = nil
        } catch {
            treatmentAnalysis = nil
            treatmentMessage = error.localizedDescription
        }
    }

    func verifyTreatmentFollowUp(_ id: UUID?) {
        verificationFollowUpID = id
        guard let source = selectedProject,
              let id,
              let target = availableProjects.first(where: { $0.id == id })
        else {
            verificationReport = nil
            return
        }
        verificationReport = treatmentVerifier.compare(baseline: source, followUp: target)
    }
}
