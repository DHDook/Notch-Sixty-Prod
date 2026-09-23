import SwiftUI

struct ProductDSPConfiguration: Equatable, Sendable {
    var eq: EQConfiguration
    var gain: DSPGainConfiguration
    var bassManagement: BassManagementConfiguration
    var roomCorrection: RoomCorrectionConfiguration

    init(
        eq: EQConfiguration = EQConfiguration(),
        gain: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration()
    ) {
        self.eq = eq
        self.gain = gain
        self.bassManagement = bassManagement
        self.roomCorrection = roomCorrection
    }
}

struct ProductConfiguration: Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var selectedOutputUID: String?
    var dsp: ProductDSPConfiguration

    init(
        schemaVersion: Int = ProductConfiguration.currentSchemaVersion,
        selectedOutputUID: String? = nil,
        dsp: ProductDSPConfiguration = ProductDSPConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.selectedOutputUID = selectedOutputUID
        self.dsp = dsp
    }
}

/// Product-level ownership boundary for application state and services.
///
/// `AudioIOEngine` remains the transport/DSP execution controller. Product-facing
/// configuration is exposed here as a compact snapshot so persistence, presets,
/// and the production UI can grow without turning the transport engine into a
/// replacement for the historical monolithic application store.
@MainActor
final class ProductController: ObservableObject {
    let audioEngine: AudioIOEngine

    init() {
        self.audioEngine = AudioIOEngine()
    }

    init(audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
    }

    var configuration: ProductConfiguration {
        ProductConfiguration(
            selectedOutputUID: audioEngine.routeConfiguration.selectedOutputUID,
            dsp: ProductDSPConfiguration(
                eq: audioEngine.eqConfiguration,
                gain: audioEngine.gainConfiguration,
                bassManagement: audioEngine.bassManagementConfiguration,
                roomCorrection: audioEngine.roomCorrectionConfiguration
            )
        )
    }

    func prepareForUse() {
        audioEngine.prepareForUse()
    }

    func shutdownForTermination() {
        audioEngine.shutdownForTermination()
    }
}

@main
struct NotchSixtyApp: App {
    @StateObject private var product = ProductController()

    var body: some Scene {
        WindowGroup {
            // PR #22 establishes product ownership without changing the validated
            // engineering UI yet. Subsequent parity/UI work should target the
            // ProductController boundary rather than adding product concerns to
            // AudioIOEngine.
            ContentView(engine: product.audioEngine)
        }
    }
}
