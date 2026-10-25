import Foundation
import SwiftUI

// E12 S1: the System area. With `e12.guided-setup` on, the sidebar's System
// group becomes one System row whose tabs host the existing workspaces.
// With the flag off nothing here is reachable and the sidebar is unchanged.

/// The tabs of the System area.
enum ProductionSystemTab: String, CaseIterable, Identifiable, Hashable {
    case overview
    case speakers
    case room
    case measure
    case calibrate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .speakers: return "Speakers"
        case .room: return "Room"
        case .measure: return "Measure"
        case .calibrate: return "Calibrate"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "checklist"
        case .speakers: return "hifispeaker.2.fill"
        case .room: return "wand.and.stars.inverse"
        case .measure: return "waveform.badge.magnifyingglass"
        case .calibrate: return "speaker.wave.3.fill"
        }
    }
}

/// The two halves of the Calibrate tab.
enum ProductionCalibrateSection: String, CaseIterable, Identifiable, Hashable {
    case alignment
    case correction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alignment: return "Alignment"
        case .correction: return "Bass and correction"
        }
    }
}

/// Where a section lives when the System area is on.
struct ProductionDestination: Equatable {
    var section: ProductionSection
    var systemTab: ProductionSystemTab?
    var calibrateSection: ProductionCalibrateSection?
}

extension ProductionSection {
    /// Sidebar rows of the System group with the System area on.
    static let systemAreaSections: [ProductionSection] = [.system, .headphones, .activeAcoustics]

    /// Sidebar rows of the Tools group with the System area on (Room Advisor moved to System).
    static let systemAreaTools: [ProductionSection] = [.blindListening]

    /// The destination for a section with the System area on. The old
    /// workspace sections stay valid as aliases of a System tab, so menu
    /// commands and stored selections keep working.
    var systemAreaDestination: ProductionDestination {
        switch self {
        case .system:
            return ProductionDestination(section: .system, systemTab: .overview)
        case .speakers:
            return ProductionDestination(section: .system, systemTab: .speakers)
        case .roomAdvisor:
            return ProductionDestination(section: .system, systemTab: .room)
        case .measurementLab:
            return ProductionDestination(section: .system, systemTab: .measure)
        case .speakerCalibration:
            return ProductionDestination(
                section: .system, systemTab: .calibrate, calibrateSection: .alignment)
        case .roomCorrection:
            return ProductionDestination(
                section: .system, systemTab: .calibrate, calibrateSection: .correction)
        default:
            return ProductionDestination(section: self)
        }
    }
}

/// What the Overview tab says about the selected output's calibration.
enum SystemCalibrationStatus: Equatable {
    case notCalibrated
    case unverified(RoomCorrectionCalibrationSummary)
    case verified(RoomCorrectionCalibrationSummary)

    /// A calibration is verified only when a passing verification names the
    /// design that is active in the profile.
    static func resolve(
        summary: RoomCorrectionCalibrationSummary?,
        verifiedDesignID: UUID?
    ) -> SystemCalibrationStatus {
        guard let summary else { return .notCalibrated }
        if let verifiedDesignID, verifiedDesignID == summary.activeDesignID {
            return .verified(summary)
        }
        return .unverified(summary)
    }

    var headline: String {
        switch self {
        case .notCalibrated: return "Not calibrated"
        case .unverified: return "Calibrated, not verified"
        case .verified: return "Calibrated and verified"
        }
    }

    var detail: String {
        switch self {
        case .notCalibrated:
            return "This output has no room correction. Measure it in the Measure tab, then design a correction in Calibrate."
        case .unverified(let summary):
            return "Correction \"\(summary.targetName)\" from \(summary.positionCount) position(s) is active. It has no passing verification yet."
        case .verified(let summary):
            return "Correction \"\(summary.targetName)\" from \(summary.positionCount) position(s) passed verification."
        }
    }

    var systemImage: String {
        switch self {
        case .notCalibrated: return "circle.dashed"
        case .unverified: return "exclamationmark.circle"
        case .verified: return "checkmark.seal.fill"
        }
    }
}

struct ProductionSystemAreaView: View {
    @ObservedObject var navigation: ProductionNavigation
    let overview: AnyView
    let speakers: AnyView
    let room: AnyView
    let measure: AnyView
    let alignment: AnyView
    let correction: AnyView

    var body: some View {
        VStack(spacing: 0) {
            Picker("System tab", selection: $navigation.systemTab) {
                ForEach(ProductionSystemTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            switch navigation.systemTab {
            case .overview: overview
            case .speakers: speakers
            case .room: room
            case .measure: measure
            case .calibrate:
                VStack(spacing: 0) {
                    Picker("Calibrate section", selection: $navigation.calibrateSection) {
                        ForEach(ProductionCalibrateSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    Divider()
                    switch navigation.calibrateSection {
                    case .alignment: alignment
                    case .correction: correction
                    }
                }
            }
        }
    }
}

struct ProductionSystemOverviewView: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var navigation: ProductionNavigation
    var entryCard = AnyView(EmptyView())

    private var status: SystemCalibrationStatus {
        SystemCalibrationStatus.resolve(
            summary: profiles.selectedSystemProfile?.state.roomCorrectionCalibration,
            verifiedDesignID: nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: status.systemImage)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.headline).font(.headline)
                            Text(status.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(outputLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                }

                entryCard

                ForEach(ProductionSystemTab.allCases.filter { $0 != .overview }) { tab in
                    Button {
                        navigation.systemTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var outputLine: String {
        guard let output = engine.selectedOutputDevice else { return "No output selected" }
        return "Output: \(output.name)"
            + (profiles.selectedSystemProfile.map { " · profile \($0.name)" } ?? "")
    }
}
