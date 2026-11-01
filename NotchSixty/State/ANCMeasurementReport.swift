import Foundation

/// E4 S31: the "Export measurement report" for reviewers. It joins the S16 verified readout, the S28
/// noise-survey predictions and the S17 safety log in one document that round-trips through JSON, so
/// a reviewer can compare the published numbers with what the app itself recorded.
///
/// Control plane only (main actor); text only, no audio. Predictions are estimates, as in S28.
struct ANCMeasurementReport: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct Prediction: Codable, Equatable, Sendable {
        var centerHz: Double
        var noiseClass: String
        var levelDB: Double
        var predictedReductionDB: Double
    }

    struct Event: Codable, Equatable, Sendable {
        var ageSeconds: Double
        var kind: String
        var message: String
    }

    var schema: Int
    var appVersion: String
    var build: String
    var generatedAt: Date
    /// S16, for example "-12 dB at 43 Hz, verified"; nil when nothing is armed or verified.
    var verifiedReadout: String?
    /// S28 survey findings that predict a reduction.
    var predictions: [Prediction]
    /// Plain statements from the survey (includes the physical envelope).
    var surveyStatements: [String]
    /// S17 events from the last 60 s, oldest first.
    var safetyEvents: [Event]
    var lastDisarmExplanation: String?

    init(
        version: String,
        build: String,
        verifiedReadout: String?,
        survey: QuietZoneNoiseSurveyReport?,
        recorder: SafetyFlightRecorder,
        now: Date = Date()
    ) {
        schema = Self.currentSchema
        appVersion = version
        self.build = build
        generatedAt = now
        self.verifiedReadout = verifiedReadout
        predictions = (survey?.findings ?? [])
            .filter { $0.predictedReductionDB > 0 }
            .map {
                Prediction(
                    centerHz: $0.centerHz,
                    noiseClass: $0.noiseClass.rawValue,
                    levelDB: $0.levelDB,
                    predictedReductionDB: $0.predictedReductionDB
                )
            }
        surveyStatements = survey?.statements ?? []
        safetyEvents = recorder.recent(now: now).map {
            Event(ageSeconds: max(0, now.timeIntervalSince($0.time)), kind: $0.kind.rawValue, message: $0.message)
        }
        lastDisarmExplanation = recorder.lastDisarmExplanation
    }

    /// True when there is anything beyond the header to report.
    var hasContent: Bool {
        verifiedReadout != nil || !predictions.isEmpty || !safetyEvents.isEmpty || lastDisarmExplanation != nil
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ANCMeasurementReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ANCMeasurementReport.self, from: data)
    }

    /// Lines for the diagnostics export; empty when there is nothing to report so a plain export is unchanged.
    var diagnosticsLines: [String] {
        guard hasContent else { return [] }
        var lines = ["Measurement Report (reviewer export, estimates marked):"]
        lines.append("  Verified: \(verifiedReadout ?? "none")")
        if predictions.isEmpty {
            lines.append("  Predictions: none surveyed")
        } else {
            for p in predictions {
                lines.append(String(format: "  Predicted %.0f dB at %.0f Hz (%@, %.1f dB level, estimate)",
                                    p.predictedReductionDB, p.centerHz, p.noiseClass, p.levelDB))
            }
        }
        return lines
    }
}
