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
    private let analyzer = RoomTreatmentAdvisorAnalyzer()

    @Published private(set) var availableProjects:
        [RoomCorrectionProject] = []
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedProject:
        RoomCorrectionProject?
    @Published private(set) var report:
        RoomTreatmentAdvisorReport?
    @Published private(set) var lastErrorDescription: String?

    init(store: RoomCorrectionProjectStore) {
        self.store = store
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
            return
        }
        selectedProject = project
        report = analyzer.analyze(project: project)
    }
}
