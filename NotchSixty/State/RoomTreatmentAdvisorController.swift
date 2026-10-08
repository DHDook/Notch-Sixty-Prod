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
            try geometryStore.delete(
                projectID: projectID
            )
            geometryDraft = nil
            savedGeometry = nil
            geometryAnalysis = nil
            geometryValidationMessage = nil
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
