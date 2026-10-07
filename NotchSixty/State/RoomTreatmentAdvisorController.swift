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
    @Published private(set) var lastErrorDescription: String?

    init(store: RoomCorrectionProjectStore) {
        self.store = store
        self.geometryStore =
            RoomGeometryStore(projectStore: store)
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
            return
        }
        selectedProject = project
        report = analyzer.analyze(project: project)
        loadGeometry(for: project.id)
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
    }
}
