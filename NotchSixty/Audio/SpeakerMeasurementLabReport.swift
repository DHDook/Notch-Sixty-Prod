import Foundation

enum SpeakerMeasurementLabReportAnalysisKind:
    String, Codable, Equatable, Sendable {
    case directivity
    case nearFieldLF
    case quasiAnechoic
    case levelDependence
    case coherentTiming
    case protectedDriverOptimization
    case protectedDriverTiming
    case protectedDriverCrossoverSum
}

struct SpeakerMeasurementLabReportMetric:
    Codable, Equatable, Sendable {
    var name: String
    var value: String
}

struct SpeakerMeasurementLabAnalysisSummary:
    Codable, Equatable, Sendable {
    var kind: SpeakerMeasurementLabReportAnalysisKind
    var title: String
    var available: Bool
    var metrics: [SpeakerMeasurementLabReportMetric]
    var warnings: [String]
}

struct SpeakerMeasurementLabProtocolSummary:
    Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var mode: String
    var target: String
    var distanceMeters: Double
    var horizontalAngleDegrees: Double
    var verticalAngleDegrees: Double
    var repeatCount: Int
    var completedRepeatCount: Int
    var excitationLevelDBFS: Double?
    var nearFieldComponentKind: String?
    var coherentPairID: UUID?
    var coherentLeg: String?
    var protectedDriverBus: String?
    var complete: Bool
}

struct SpeakerMeasurementLabCaptureSummary:
    Codable, Equatable, Sendable {
    var id: UUID
    var protocolID: UUID
    var repeatIndex: Int
    var capturedAt: Date
    var source: String
    var estimatedSNRDB: Double?
    var clipped: Bool
    var directArrivalMilliseconds: Double?
    var usableLowHz: Double?
    var usableHighHz: Double?
    var protectedPathAuthenticated: Bool
    var sharedTimeReferenceQualified: Bool
}

struct SpeakerMeasurementLabCompactReport:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var generatedAt: Date
    var sessionID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var microphoneDeviceUID: String
    var microphoneInputChannelIndex: Int
    var microphoneCalibrationFingerprint: String?
    var createdAt: Date
    var modifiedAt: Date
    var protocolSummaries: [SpeakerMeasurementLabProtocolSummary]
    var captureSummaries: [SpeakerMeasurementLabCaptureSummary]
    var analysisSummaries: [SpeakerMeasurementLabAnalysisSummary]
    var warnings: [String]
    /// Persisted safety/interpretation flags so exported JSON carries these
    /// boundaries instead of relying on in-process computed properties.
    var measurementOnly: Bool = true
    var canDeploy: Bool = false
    var containsRawImpulseData: Bool = false
}

enum SpeakerMeasurementLabReportError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case exportEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Advanced Speaker Measurement Lab report cannot be generated from an invalid session."
        case .exportEncodingFailed:
            return "Advanced Speaker Measurement Lab report export could not be encoded."
        }
    }
}

/// Builds a compact, human-auditable Lab report without copying raw impulse
/// arrays or full transfer-function grids into the export.
///
/// Specialized analyses are attempted only after their protocol groups are
/// complete. Failed analysis remains visible as an unavailable report item
/// rather than silently disappearing.
struct SpeakerMeasurementLabReportBuilder: Sendable {
    func build(
        session: SpeakerMeasurementLabSession,
        generatedAt: Date = Date()
    ) throws -> SpeakerMeasurementLabCompactReport {
        do {
            try session.validateStructure()
        } catch {
            throw SpeakerMeasurementLabReportError.invalidSession
        }

        let protocols = session.protocols.map { labProtocol in
            let count = session.captures.filter {
                $0.protocolID == labProtocol.id
            }.count
            return SpeakerMeasurementLabProtocolSummary(
                id: labProtocol.id,
                name: labProtocol.name,
                mode: modeName(labProtocol.request.mode),
                target: targetName(labProtocol.request.target),
                distanceMeters:
                    labProtocol.request.geometry.distanceMeters,
                horizontalAngleDegrees:
                    labProtocol.request.geometry.horizontalAngleDegrees,
                verticalAngleDegrees:
                    labProtocol.request.geometry.verticalAngleDegrees,
                repeatCount: labProtocol.request.repeatCount,
                completedRepeatCount: count,
                excitationLevelDBFS:
                    labProtocol.excitationLevelDBFS,
                nearFieldComponentKind:
                    labProtocol.nearFieldComponent?.kind.rawValue,
                coherentPairID: labProtocol.coherentPairID,
                coherentLeg: labProtocol.coherentLeg?.rawValue,
                protectedDriverBus:
                    labProtocol.protectedDriverBus?.displayName,
                complete: count >= labProtocol.request.repeatCount
            )
        }

        let captures = session.captures.sorted {
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt < $1.capturedAt
            }
            if $0.protocolID != $1.protocolID {
                return $0.protocolID.uuidString
                    < $1.protocolID.uuidString
            }
            return $0.repeatIndex < $1.repeatIndex
        }.map { capture in
            SpeakerMeasurementLabCaptureSummary(
                id: capture.id,
                protocolID: capture.protocolID,
                repeatIndex: capture.repeatIndex,
                capturedAt: capture.capturedAt,
                source: capture.source.displayName,
                estimatedSNRDB:
                    capture.quality.estimatedSNRDB,
                clipped: capture.quality.clipped,
                directArrivalMilliseconds:
                    capture.quality.directArrivalSeconds.map {
                        $0 * 1_000
                    },
                usableLowHz: capture.quality.usableLowHz,
                usableHighHz: capture.quality.usableHighHz,
                protectedPathAuthenticated:
                    capture.protectedDriverProvenance != nil,
                sharedTimeReferenceQualified:
                    capture.sharedClockReference?
                        .sharedTimeOriginQualified == true
            )
        }

        return SpeakerMeasurementLabCompactReport(
            generatedAt: generatedAt,
            sessionID: session.id,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            sampleRate: session.sampleRate,
            microphoneDeviceUID: session.microphone.deviceUID,
            microphoneInputChannelIndex:
                session.microphone.inputChannelIndex,
            microphoneCalibrationFingerprint:
                session.microphone.calibrationFingerprint,
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt,
            protocolSummaries: protocols,
            captureSummaries: captures,
            analysisSummaries:
                analysisSummaries(session: session),
            warnings: [
                "Advanced Speaker Measurement Lab reports are measurement-only and cannot deploy DSP.",
                "Installed-room whole-speaker measurements are not anechoic/free-field specifications.",
                "Quasi-anechoic products use an explicit reflection-window assumption and remain magnitude-only.",
                "Near-field subwoofer data is local radiator/port evidence and is not a far-field system-bass prediction.",
                "Protected-driver captures include the active production crossover and limiter path.",
                "Authenticated coherent timing applies only to the exact linked pair/session/reference path that passed its guards."
            ]
        )
    }

    private func analysisSummaries(
        session: SpeakerMeasurementLabSession
    ) -> [SpeakerMeasurementLabAnalysisSummary] {
        let complete = session.protocols.filter { labProtocol in
            session.captures.filter {
                $0.protocolID == labProtocol.id
            }.count >= labProtocol.request.repeatCount
        }
        var summaries: [SpeakerMeasurementLabAnalysisSummary] = []

        let sources = Array(
            Set(complete.compactMap { $0.acousticSource })
        ).sorted { $0.displayName < $1.displayName }

        for source in sources {
            if let onAxis = complete.first(where: {
                $0.request.mode == .wholeSpeakerOnAxis
                    && $0.acousticSource == source
            }) {
                let offAxis = complete.filter {
                    $0.request.mode == .wholeSpeakerOffAxis
                        && $0.acousticSource == source
                }
                if !offAxis.isEmpty {
                    summaries.append(
                        directivitySummary(
                            session: session,
                            onAxis: onAxis,
                            offAxis: offAxis
                        )
                    )
                }
            }

            let nearField = complete.filter {
                $0.request.mode == .subwooferNearField
                    && $0.acousticSource == source
            }
            if !nearField.isEmpty {
                summaries.append(
                    nearFieldSummary(
                        session: session,
                        protocols: nearField
                    )
                )
            }

            let level = complete.filter {
                $0.request.mode == .wholeSpeakerOnAxis
                    && $0.acousticSource == source
                    && $0.excitationLevelDBFS != nil
            }.sorted {
                ($0.excitationLevelDBFS ?? 0)
                    < ($1.excitationLevelDBFS ?? 0)
            }
            if level.count >= 2 {
                summaries.append(
                    levelDependenceSummary(
                        session: session,
                        lower: level.first!,
                        higher: level.last!
                    )
                )
            }
        }

        for labProtocol in complete where
            labProtocol.request.mode == .wholeSpeakerOnAxis
                || labProtocol.request.mode == .wholeSpeakerOffAxis {
            summaries.append(
                quasiAnechoicSummary(
                    session: session,
                    labProtocol: labProtocol
                )
            )
        }

        let coherentPairIDs = Set(
            complete.compactMap { labProtocol in
                labProtocol.request.mode == .coherentMainsSubTiming
                    ? labProtocol.coherentPairID : nil
            }
        )
        for pairID in coherentPairIDs.sorted(
            by: { $0.uuidString < $1.uuidString }
        ) {
            let pair = complete.filter {
                $0.coherentPairID == pairID
                    && $0.request.mode == .coherentMainsSubTiming
            }
            if pair.count == 2 {
                summaries.append(
                    coherentTimingSummary(
                        session: session,
                        pairID: pairID
                    )
                )
            }
        }

        // PR111: display every protected driver intent, even when incomplete
        // or unqualified. Never mistake a missing result for a flat response.
        for labProtocol in session.protocols where
            labProtocol.request.mode == .protectedDriverNearField {
            summaries.append(
                protectedDriverOptimizationSummary(
                    session: session, labProtocol: labProtocol
                )
            )
        }

        summaries.append(
            contentsOf: protectedDriverTimingSummaries(session: session)
        )
        summaries.append(
            contentsOf: protectedDriverCrossoverSumSummaries(
                session: session
            )
        )

        return summaries
    }

    private func protectedDriverOptimizationSummary(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol
    ) -> SpeakerMeasurementLabAnalysisSummary {
        let title = "\(labProtocol.protectedDriverBus?.displayName ?? labProtocol.name) · protected driver PEQ"
        do {
            let candidate = try ProtectedDriverPEQRecommendationAnalyzer()
                .recommend(
                    session: session,
                    protocolID: labProtocol.id
                )
            var metrics: [SpeakerMeasurementLabReportMetric] = [
                metric("Driver", candidate.targetBus.displayName),
                metric(
                    "Protected usable passband",
                    "\(formatHz(candidate.passbandLowHz))–\(formatHz(candidate.passbandHighHz))"
                ),
                metric("Qualified repeats",
                       "\(candidate.repeatedCaptureIDs.count)"),
                metric("Limiting", candidate.protectedConfiguration.limiterEnabled
                       ? "Required / preserved" : "BLOCKED"),
                metric("Suggested cuts", "\(candidate.cuts.count)"),
                metric("Deployment", "Never · review only")
            ]
            for (index, cut) in candidate.cuts.enumerated() {
                metrics.append(
                    metric(
                        "Cut \(index + 1)",
                        "\(formatHz(cut.frequencyHz)): \(format(cut.gainDB, 2)) dB, Q \(format(cut.q, 2))"
                    )
                )
            }
            return available(
                .protectedDriverOptimization,
                title: title,
                metrics: metrics,
                warnings: [
                    "Measured protected driver *near field*, not an anechoic whole-speaker response. Spectral cuts are only hypotheses; no live Apply or filter deployment.",
                    "Driver polarity, acoustic-center delay, mandatory crossover and limiter are unchanged. Combined-driver summation remains unverified."
                ]
            )
        } catch {
            return unavailable(
                .protectedDriverOptimization,
                title: title,
                error: error
            )
        }
    }

    private func protectedDriverCrossoverSumSummaries(
        session: SpeakerMeasurementLabSession
    ) -> [SpeakerMeasurementLabAnalysisSummary] {
        let protected = session.protocols.filter {
            $0.request.mode == .protectedDriverNearField
                && $0.protectedDriverBus != nil
        }
        guard protected.count >= 2 else { return [] }
        let mode = session.captures.compactMap {
            $0.protectedDriverProvenance?
                .bassManagementConfiguration.physicalOutputMode
        }.first
        guard let mode else { return [] }

        let pairs: [(SpeakerOutputBus, SpeakerOutputBus)]
        switch mode {
        case .biAmp:
            pairs = [
                (.leftLow, .leftHigh),
                (.rightLow, .rightHigh),
            ]
        case .triAmp:
            pairs = [
                (.leftLow, .leftMid),
                (.leftMid, .leftHigh),
                (.rightLow, .rightMid),
                (.rightMid, .rightHigh),
            ]
        default:
            return []
        }

        return pairs.compactMap { firstBus, secondBus in
            let first = protected.filter {
                $0.protectedDriverBus == firstBus
            }
            let second = protected.filter {
                $0.protectedDriverBus == secondBus
            }
            guard !first.isEmpty || !second.isEmpty else { return nil }
            guard first.count == 1, second.count == 1 else {
                return unavailable(
                    .protectedDriverCrossoverSum,
                    title:
                        "\(firstBus.displayName) + \(secondBus.displayName) crossover sum model",
                    error:
                        ProtectedDriverCrossoverSumModelError
                            .timingEvidenceUnavailable
                )
            }
            return protectedDriverCrossoverSumSummary(
                session: session,
                first: first[0],
                second: second[0]
            )
        }
    }

    private func protectedDriverCrossoverSumSummary(
        session: SpeakerMeasurementLabSession,
        first: SpeakerMeasurementLabProtocol,
        second: SpeakerMeasurementLabProtocol
    ) -> SpeakerMeasurementLabAnalysisSummary {
        let title =
            "\(first.protectedDriverBus?.displayName ?? first.name) + " +
            "\(second.protectedDriverBus?.displayName ?? second.name) · crossover sum model"
        do {
            let model = try ProtectedDriverCrossoverSumModelAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: first.id,
                    secondProtocolID: second.id
                )
            let hypothesis: String
            switch model.bestHypothesis {
            case .retainCurrent:
                hypothesis = "Retain current state"
            case .addBoundedDelay:
                hypothesis = "Compare bounded delay"
            case .invertComparedDriver:
                hypothesis =
                    "Compare inversion of \(model.secondBus.displayName)"
            case .addDelayAndInvertComparedDriver:
                hypothesis =
                    "Compare bounded delay + \(model.secondBus.displayName) inversion"
            }
            return available(
                .protectedDriverCrossoverSum,
                title: title,
                metrics: [
                    metric(
                        "Crossover",
                        formatHz(model.crossoverFrequencyHz)
                    ),
                    metric(
                        "Shared samples",
                        "\(model.frequencyPointCount)"
                    ),
                    metric(
                        "Current modeled deficit",
                        format(model.currentMeanCoherenceDeficitDB, 2) + " dB"
                    ),
                    metric(
                        "Candidate modeled deficit",
                        format(model.candidateMeanCoherenceDeficitDB, 2) + " dB"
                    ),
                    metric(
                        "Modeled reduction",
                        format(model.modeledDeficitReductionDB, 2) + " dB"
                    ),
                    metric("Best hypothesis", hypothesis),
                    metric(
                        "Combined-driver capture",
                        "REQUIRED · not yet verified"
                    ),
                    metric("Deployment", "Never · model only"),
                ],
                warnings: model.warnings
            )
        } catch {
            return unavailable(
                .protectedDriverCrossoverSum,
                title: title,
                error: error
            )
        }
    }

    private func protectedDriverTimingSummaries(
        session: SpeakerMeasurementLabSession
    ) -> [SpeakerMeasurementLabAnalysisSummary] {
        let protected = session.protocols.filter {
            $0.request.mode == .protectedDriverNearField
                && $0.protectedDriverBus != nil
        }
        guard protected.count >= 2 else { return [] }

        let mode = session.captures.compactMap {
            $0.protectedDriverProvenance?
                .bassManagementConfiguration.physicalOutputMode
        }.first
        guard let mode else { return [] }

        let pairs: [(SpeakerOutputBus, SpeakerOutputBus)]
        switch mode {
        case .biAmp:
            pairs = [
                (.leftLow, .leftHigh),
                (.rightLow, .rightHigh),
            ]
        case .triAmp:
            pairs = [
                (.leftLow, .leftMid),
                (.leftMid, .leftHigh),
                (.rightLow, .rightMid),
                (.rightMid, .rightHigh),
            ]
        default:
            return []
        }

        return pairs.compactMap { firstBus, secondBus in
            let firstMatches = protected.filter {
                $0.protectedDriverBus == firstBus
            }
            let secondMatches = protected.filter {
                $0.protectedDriverBus == secondBus
            }
            guard !firstMatches.isEmpty || !secondMatches.isEmpty else {
                return nil
            }
            guard firstMatches.count == 1,
                  secondMatches.count == 1 else {
                return unavailable(
                    .protectedDriverTiming,
                    title:
                        "\(firstBus.displayName) + \(secondBus.displayName) protected timing",
                    error:
                        ProtectedDriverTimingRecommendationError.invalidPair
                )
            }
            return protectedDriverTimingSummary(
                session: session,
                first: firstMatches[0],
                second: secondMatches[0]
            )
        }
    }

    private func protectedDriverTimingSummary(
        session: SpeakerMeasurementLabSession,
        first: SpeakerMeasurementLabProtocol,
        second: SpeakerMeasurementLabProtocol
    ) -> SpeakerMeasurementLabAnalysisSummary {
        let title =
            "\(first.protectedDriverBus?.displayName ?? first.name) + " +
            "\(second.protectedDriverBus?.displayName ?? second.name) · protected timing"
        do {
            let result = try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: first.id,
                    secondProtocolID: second.id
                )
            let delay: String
            if let bus = result.delayBus,
               let milliseconds = result.additionalDelayMilliseconds {
                delay =
                    "Add \(format(milliseconds, 3)) ms to \(bus.displayName)"
            } else {
                delay = "No bounded delay suggestion"
            }
            let polarity: String
            switch result.polarityHypothesis {
            case .retainCurrent:
                polarity = "Retain current polarity"
            case .invertComparedDriver:
                polarity =
                    "Compare inversion of \(result.secondBus.displayName)"
            case .inconclusive:
                polarity = "Inconclusive"
            }
            let relativeArrivalText =
                format(result.relativeArrivalMilliseconds, 3) + " ms"
            let phaseDegrees =
                result.wrappedRelativePhaseAtCrossoverRadians
                    * 180 / Double.pi
            let residualPhaseText =
                format(phaseDegrees, 1) + "°"
            let referenceSpreadText =
                format(
                    result.referenceArrivalSpreadMilliseconds,
                    3
                ) + " ms"
            let referenceConsistencyText =
                String(
                    Int(
                        (result.referencePhaseConsistency * 100)
                            .rounded()
                    )
                ) + "%"
            let confidenceText =
                String(
                    Int((result.evidenceConfidence * 100).rounded())
                ) + "%"
            return available(
                .protectedDriverTiming,
                title: title,
                metrics: [
                    metric(
                        "Crossover",
                        formatHz(result.crossoverFrequencyHz)
                    ),
                    metric("Relative arrival", relativeArrivalText),
                    metric("Delay hypothesis", delay),
                    metric("Residual phase", residualPhaseText),
                    metric("Polarity hypothesis", polarity),
                    metric(
                        "Reference arrival spread",
                        referenceSpreadText
                    ),
                    metric(
                        "Reference phase consistency",
                        referenceConsistencyText
                    ),
                    metric("Evidence confidence", confidenceText),
                    metric("Deployment", "Never · review only"),
                ],
                warnings: result.warnings
            )
        } catch {
            return unavailable(
                .protectedDriverTiming,
                title: title,
                error: error
            )
        }
    }

    private func directivitySummary(
        session: SpeakerMeasurementLabSession,
        onAxis: SpeakerMeasurementLabProtocol,
        offAxis: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabAnalysisSummary {
        do {
            let report = try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id,
                    offAxisProtocolIDs: offAxis.map(\.id)
                )
            let largest = report.traces.max {
                $0.angularOffsetDegrees < $1.angularOffsetDegrees
            }
            return available(
                .directivity,
                title: "\(report.source.displayName) directivity",
                metrics: [
                    metric("Traces", "\(report.traces.count)"),
                    metric(
                        "Usable band",
                        "\(formatHz(report.commonUsableLowHz))–\(formatHz(report.commonUsableHighHz))"
                    ),
                    metric(
                        "Reference radius",
                        "\(format(report.referenceDistanceMeters, 2)) m"
                    ),
                    metric(
                        "Largest angle",
                        largest.map {
                            "\(format($0.angularOffsetDegrees, 1))°"
                        } ?? "—"
                    )
                ],
                warnings: report.warnings
            )
        } catch {
            return unavailable(
                .directivity,
                title: "\(onAxis.acousticSource?.displayName ?? onAxis.name) directivity",
                error: error
            )
        }
    }

    private func nearFieldSummary(
        session: SpeakerMeasurementLabSession,
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabAnalysisSummary {
        do {
            let report = try SpeakerMeasurementLabNearFieldLFAnalyzer()
                .analyze(
                    session: session,
                    protocolIDs: protocols.map(\.id)
                )
            return available(
                .nearFieldLF,
                title: "\(report.source.displayName) near-field LF",
                metrics: [
                    metric("Components", "\(report.traces.count)"),
                    metric(
                        "Usable band",
                        "\(formatHz(report.commonUsableLowHz))–\(formatHz(report.commonUsableHighHz))"
                    ),
                    metric(
                        "Phase comparison",
                        report.mergeAssessment.phaseComparisonAvailable
                            ? "Available" : "Unavailable"
                    ),
                    metric(
                        "Far-field composite",
                        report.mergeAssessment
                            .canSynthesizeFarFieldComposite
                            ? "Available" : "Blocked"
                    )
                ],
                warnings:
                    report.warnings
                    + report.mergeAssessment.blockingReasons
            )
        } catch {
            return unavailable(
                .nearFieldLF,
                title: "\(protocols.first?.acousticSource?.displayName ?? "Subwoofer") near-field LF",
                error: error
            )
        }
    }

    private func quasiAnechoicSummary(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol
    ) -> SpeakerMeasurementLabAnalysisSummary {
        do {
            let report =
                try SpeakerMeasurementLabQuasiAnechoicAnalyzer()
                    .analyze(
                        session: session,
                        protocolID: labProtocol.id
                    )
            return available(
                .quasiAnechoic,
                title: "\(labProtocol.name) quasi-anechoic estimate",
                metrics: [
                    metric(
                        "Reliable band",
                        "\(formatHz(report.minimumReliableFrequencyHz))–\(formatHz(report.maximumReliableFrequencyHz))"
                    ),
                    metric(
                        "Window",
                        "\(format(report.window.reflectionFreePostArrivalMilliseconds, 2)) ms"
                    ),
                    metric(
                        "Confidence",
                        "\(Int((report.evidenceConfidence * 100).rounded()))%"
                    ),
                    metric(
                        "Mic calibration",
                        report.microphoneCalibrationApplied
                            ? "Applied" : "Not applied"
                    )
                ],
                warnings: report.warnings
            )
        } catch {
            return unavailable(
                .quasiAnechoic,
                title: "\(labProtocol.name) quasi-anechoic estimate",
                error: error
            )
        }
    }

    private func levelDependenceSummary(
        session: SpeakerMeasurementLabSession,
        lower: SpeakerMeasurementLabProtocol,
        higher: SpeakerMeasurementLabProtocol
    ) -> SpeakerMeasurementLabAnalysisSummary {
        do {
            let report =
                try SpeakerMeasurementLabLevelDependenceAnalyzer()
                    .analyze(
                        session: session,
                        firstProtocolID: lower.id,
                        secondProtocolID: higher.id
                    )
            return available(
                .levelDependence,
                title: "\(report.source.displayName) level dependence",
                metrics: [
                    metric(
                        "Excitation step",
                        "\(format(report.excitationStepDB, 1)) dB"
                    ),
                    metric(
                        "Shape change RMS",
                        "\(format(report.shapeChangeRMSDB, 2)) dB"
                    ),
                    metric(
                        "Max localized compression",
                        "\(format(report.maximumLocalizedCompressionDB, 2)) dB"
                    ),
                    metric(
                        "Material dependence",
                        report.materialLevelDependenceObserved
                            ? "Observed" : "Not observed"
                    )
                ],
                warnings: report.warnings
            )
        } catch {
            return unavailable(
                .levelDependence,
                title: "\(lower.acousticSource?.displayName ?? lower.name) level dependence",
                error: error
            )
        }
    }

    private func coherentTimingSummary(
        session: SpeakerMeasurementLabSession,
        pairID: UUID
    ) -> SpeakerMeasurementLabAnalysisSummary {
        do {
            let report =
                try SpeakerMeasurementLabCoherentTimingAnalyzer()
                    .analyze(
                        session: session,
                        coherentPairID: pairID
                    )
            return available(
                .coherentTiming,
                title: "\(report.main.displayName) + \(report.subwoofer.displayName) coherent timing",
                metrics: [
                    metric(
                        "Relative arrival",
                        "\(format(report.relativeArrivalMilliseconds, 3)) ms"
                    ),
                    metric(
                        "Reference arrival spread",
                        "\(format(report.referenceArrivalSpreadMilliseconds, 3)) ms"
                    ),
                    metric(
                        "Reference phase consistency",
                        "\(Int((report.referencePhaseConsistency * 100).rounded()))%"
                    ),
                    metric(
                        "Clock provenance",
                        report.crossSourceClockProvenanceAuthenticated
                            ? "Authenticated" : "Blocked"
                    )
                ],
                warnings: report.warnings
            )
        } catch {
            return unavailable(
                .coherentTiming,
                title: "Coherent mains/sub timing",
                error: error
            )
        }
    }

    private func available(
        _ kind: SpeakerMeasurementLabReportAnalysisKind,
        title: String,
        metrics: [SpeakerMeasurementLabReportMetric],
        warnings: [String]
    ) -> SpeakerMeasurementLabAnalysisSummary {
        SpeakerMeasurementLabAnalysisSummary(
            kind: kind,
            title: title,
            available: true,
            metrics: metrics,
            warnings: warnings
        )
    }

    private func unavailable(
        _ kind: SpeakerMeasurementLabReportAnalysisKind,
        title: String,
        error: Error
    ) -> SpeakerMeasurementLabAnalysisSummary {
        SpeakerMeasurementLabAnalysisSummary(
            kind: kind,
            title: title,
            available: false,
            metrics: [],
            warnings: [
                error.localizedDescription.isEmpty
                    ? "Analysis prerequisites were not satisfied."
                    : error.localizedDescription
            ]
        )
    }

    private func metric(
        _ name: String,
        _ value: String
    ) -> SpeakerMeasurementLabReportMetric {
        SpeakerMeasurementLabReportMetric(
            name: name,
            value: value
        )
    }

    private func modeName(
        _ mode: SpeakerMeasurementLabMode
    ) -> String {
        switch mode {
        case .wholeSpeakerOnAxis:
            return "Whole speaker · On axis"
        case .wholeSpeakerOffAxis:
            return "Whole speaker · Off axis"
        case .subwooferNearField:
            return "Subwoofer · Near field"
        case .protectedDriverNearField:
            return "Protected driver · Near field"
        case .coherentMainsSubTiming:
            return "Coherent mains/sub timing"
        }
    }

    private func targetName(
        _ target: SpeakerMeasurementLabTarget
    ) -> String {
        switch target {
        case .acousticSource(let source):
            return source.displayName
        case .protectedDriverBus(let bus):
            return bus.displayName
        case .sourcePair(let main, let subwoofer):
            return "\(main.displayName) + \(subwoofer.displayName)"
        }
    }

    private func format(
        _ value: Double,
        _ places: Int
    ) -> String {
        value.isFinite
            ? String(format: "%.\(places)f", value)
            : "—"
    }

    private func formatHz(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 1_000 {
            return "\(format(value / 1_000, 2)) kHz"
        }
        return "\(format(value, 0)) Hz"
    }
}

struct SpeakerMeasurementLabReportExporter: Sendable {
    func jsonData(
        _ report: SpeakerMeasurementLabCompactReport
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(report)
        } catch {
            throw SpeakerMeasurementLabReportError
                .exportEncodingFailed
        }
    }

    func csvData(
        _ report: SpeakerMeasurementLabCompactReport
    ) throws -> Data {
        var lines: [String] = [
            "section,protocol_id,name,mode,target,distance_m,horizontal_deg,vertical_deg,requested_repeats,captured_repeats,excitation_dbfs,complete"
        ]
        for item in report.protocolSummaries {
            lines.append([
                "protocol",
                item.id.uuidString,
                item.name,
                item.mode,
                item.target,
                decimal(item.distanceMeters),
                decimal(item.horizontalAngleDegrees),
                decimal(item.verticalAngleDegrees),
                "\(item.repeatCount)",
                "\(item.completedRepeatCount)",
                item.excitationLevelDBFS.map(decimal) ?? "",
                item.complete ? "true" : "false",
            ].map(csv).joined(separator: ","))
        }

        lines.append("")
        lines.append(
            "section,analysis_kind,title,available,metrics,warnings"
        )
        for analysis in report.analysisSummaries {
            let metrics = analysis.metrics.map {
                "\($0.name)=\($0.value)"
            }.joined(separator: "; ")
            lines.append([
                "analysis",
                analysis.kind.rawValue,
                analysis.title,
                analysis.available ? "true" : "false",
                metrics,
                analysis.warnings.joined(separator: " | "),
            ].map(csv).joined(separator: ","))
        }

        guard let data = lines.joined(separator: "\n")
            .data(using: .utf8) else {
            throw SpeakerMeasurementLabReportError
                .exportEncodingFailed
        }
        return data
    }

    private func decimal(_ value: Double) -> String {
        value.isFinite
            ? String(format: "%.6f", value)
            : ""
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(
            of: "\"",
            with: "\"\""
        )
        return "\"\(escaped)\""
    }
}

extension SpeakerMeasurementLabSessionStore {
    func listRecentSessions(
        limit: Int = 12
    ) throws -> [SpeakerMeasurementLabSession] {
        guard limit > 0,
              FileManager.default.fileExists(
                  atPath: rootDirectory.path
              ) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        var sessions: [SpeakerMeasurementLabSession] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let session = try? decoder.decode(
                      SpeakerMeasurementLabSession.self,
                      from: data
                  ),
                  (try? session.validateStructure()) != nil else {
                continue
            }
            sessions.append(session)
        }
        return Array(
            sessions.sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(limit)
        )
    }
}
