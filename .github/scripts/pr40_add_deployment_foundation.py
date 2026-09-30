from pathlib import Path

profiles_path = Path('NotchSixty/State/ProductProfiles.swift')
fir_path = Path('NotchSixty/Audio/RoomCorrectionFIRDesigner.swift')
project_path = Path('NotchSixty/State/RoomCorrectionProjectController.swift')
fir_tests_path = Path('NotchSixtyTests/RoomCorrectionFIRDesignerTests.swift')
project_tests_path = Path('NotchSixtyTests/RoomCorrectionProjectControllerTests.swift')

profiles = profiles_path.read_text()
profiles = profiles.replace(
'''    case roomCorrectionCalibrationVersion(Int)\n''',
'''    case roomCorrectionCalibrationVersion(Int)\n    case selectedSystemProfileRequired\n''',
1)
profiles = profiles.replace(
'''        case .roomCorrectionCalibrationVersion(let version):\n            return "Room-correction calibration metadata uses unsupported schema version \\(version)."\n''',
'''        case .roomCorrectionCalibrationVersion(let version):\n            return "Room-correction calibration metadata uses unsupported schema version \\(version)."\n        case .selectedSystemProfileRequired:\n            return "Select a Playback System before changing deployed room correction."\n''',
1)

anchor = '''    func setSelectedSystemRoomCorrectionCalibration(_ summary: RoomCorrectionCalibrationSummary?) {\n'''
assert anchor in profiles
method = r'''    func replaceSelectedSystemRoomCorrection(
        _ configuration: RoomCorrectionConfiguration,
        calibrationSummary summary: RoomCorrectionCalibrationSummary?
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        if let summary, summary.schemaVersion != RoomCorrectionCalibrationSummary.currentSchemaVersion {
            throw ProductProfileError.roomCorrectionCalibrationVersion(summary.schemaVersion)
        }

        let previousEngineConfiguration = engine.roomCorrectionConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceRoomCorrectionConfiguration(configuration)
            systemProfiles[index].state.roomCorrection = configuration
            systemProfiles[index].state.roomCorrectionCalibration = summary
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceRoomCorrectionConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func setSelectedSystemRoomCorrectionEnabled(_ enabled: Bool) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        var configuration = systemProfiles[index].state.roomCorrection
        configuration.enabled = enabled
        try replaceSelectedSystemRoomCorrection(
            configuration,
            calibrationSummary: systemProfiles[index].state.roomCorrectionCalibration
        )
    }

'''
profiles = profiles.replace(anchor, method + anchor, 1)

old_persist = '''    private func persist() {\n        do {\n            let directory = storageURL.deletingLastPathComponent()\n            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)\n            let archive = Archive(\n                userContentPresets: userContentPresets,\n                systemProfiles: systemProfiles,\n                selectedContentPresetID: selectedContentPresetID,\n                selectedSystemProfileID: selectedSystemProfileID\n            )\n            let encoder = JSONEncoder()\n            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]\n            let data = try encoder.encode(archive)\n            try data.write(to: storageURL, options: .atomic)\n        } catch {\n            lastErrorDescription = error.localizedDescription\n        }\n    }\n'''
new_persist = '''    private func persist() {\n        do {\n            try persistThrowing()\n        } catch {\n            lastErrorDescription = error.localizedDescription\n        }\n    }\n\n    private func persistThrowing() throws {\n        let directory = storageURL.deletingLastPathComponent()\n        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)\n        let archive = Archive(\n            userContentPresets: userContentPresets,\n            systemProfiles: systemProfiles,\n            selectedContentPresetID: selectedContentPresetID,\n            selectedSystemProfileID: selectedSystemProfileID\n        )\n        let encoder = JSONEncoder()\n        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]\n        let data = try encoder.encode(archive)\n        try data.write(to: storageURL, options: .atomic)\n    }\n'''
assert old_persist in profiles
profiles = profiles.replace(old_persist, new_persist, 1)

old_design = '''struct RoomCorrectionDesign: Identifiable, Codable, Equatable, Sendable {\n    var id: UUID = UUID()\n    var name: String\n    var createdAt: Date\n    var sampleRate: Double\n    var parameters: RoomCorrectionDesignParameters\n    var target: RoomCorrectionTargetCurve? = nil\n    var filter: RoomCorrectionFilter\n'''
new_design = '''struct RoomCorrectionDesignSourcePosition: Codable, Equatable, Sendable {\n    var id: UUID\n    var weight: Double\n}\n\nstruct RoomCorrectionDesign: Identifiable, Codable, Equatable, Sendable {\n    var id: UUID = UUID()\n    var name: String\n    var createdAt: Date\n    var sampleRate: Double\n    var parameters: RoomCorrectionDesignParameters\n    var target: RoomCorrectionTargetCurve? = nil\n    var sourcePositions: [RoomCorrectionDesignSourcePosition]? = nil\n    var effectiveCorrectionLowHz: Double? = nil\n    var effectiveCorrectionHighHz: Double? = nil\n    var filter: RoomCorrectionFilter\n'''
assert old_design in profiles
profiles = profiles.replace(old_design, new_design, 1)

old_validation = '''        if let target = design.target { try validateTarget(target) }\n        let filter = design.filter\n'''
new_validation = '''        if let target = design.target { try validateTarget(target) }\n        if let sourcePositions = design.sourcePositions {\n            guard !sourcePositions.isEmpty,\n                  Set(sourcePositions.map(\\.id)).count == sourcePositions.count,\n                  sourcePositions.allSatisfy({ $0.weight.isFinite && $0.weight > 0 }) else {\n                throw RoomCorrectionProjectError.invalidProject("Correction design source positions are invalid.")\n            }\n        }\n        switch (design.effectiveCorrectionLowHz, design.effectiveCorrectionHighHz) {\n        case (nil, nil):\n            break\n        case let (low?, high?) where low.isFinite && high.isFinite && low > 0 && high > low:\n            break\n        default:\n            throw RoomCorrectionProjectError.invalidProject("Correction design effective range is invalid.")\n        }\n        let filter = design.filter\n'''
assert old_validation in profiles
profiles = profiles.replace(old_validation, new_validation, 1)
profiles_path.write_text(profiles)

fir = fir_path.read_text()
fir = fir.replace(
'''    case nonFiniteFilter\n    case nonFiniteResponse\n''',
'''    case nonFiniteFilter\n    case nonFiniteResponse\n    case invalidDeploymentHeadroom(Double)\n''',
1)
fir = fir.replace(
'''        case .nonFiniteResponse:\n            return "Generated room-correction FIR response is non-finite."\n''',
'''        case .nonFiniteResponse:\n            return "Generated room-correction FIR response is non-finite."\n        case .invalidDeploymentHeadroom(let headroom):\n            return "Room-correction deployment headroom \\(headroom) dB is invalid."\n''',
1)
fir = fir.replace(
'''        usableHighHz: Double? = nil,\n        name proposedName: String = "Room Correction",\n''',
'''        usableHighHz: Double? = nil,\n        sourcePositions: [RoomCorrectionDesignSourcePosition]? = nil,\n        name proposedName: String = "Room Correction",\n''',
1)
fir = fir.replace(
'''            parameters: parameters,\n            target: target,\n            filter: filter,\n''',
'''            parameters: parameters,\n            target: target,\n            sourcePositions: sourcePositions,\n            effectiveCorrectionLowHz: preview.effectiveCorrectionLowHz,\n            effectiveCorrectionHighHz: preview.effectiveCorrectionHighHz,\n            filter: filter,\n''',
1)
append_anchor = '''private struct RoomCorrectionFIRSpectrum {\n'''
assert append_anchor in fir
extension = r'''extension RoomCorrectionDesign {
    /// Returns the exact filter deployed to the Playback System. The sidecar
    /// design remains unscaled for reproducibility; deployment embeds the
    /// design's explicit safety headroom in the room-owned FIR rather than
    /// mutating Content Preset headroom.
    func deploymentFilter() throws -> RoomCorrectionFilter {
        guard recommendedHeadroomDB.isFinite, recommendedHeadroomDB >= 0 else {
            throw RoomCorrectionFIRDesignError.invalidDeploymentHeadroom(recommendedHeadroomDB)
        }
        let scale = pow(10.0, -recommendedHeadroomDB / 20.0)
        guard scale.isFinite, scale > 0, scale <= 1 else {
            throw RoomCorrectionFIRDesignError.invalidDeploymentHeadroom(recommendedHeadroomDB)
        }
        func scaled(_ taps: [Float]) throws -> [Float] {
            let output = taps.map { Float(Double($0) * scale) }
            guard output.allSatisfy(\.isFinite) else {
                throw RoomCorrectionFIRDesignError.nonFiniteFilter
            }
            return output
        }
        return RoomCorrectionFilter(
            name: filter.name,
            sampleRate: filter.sampleRate,
            leftTaps: try scaled(filter.leftTaps),
            rightTaps: try filter.rightTaps.map(scaled),
            declaredLatencyFrames: filter.declaredLatencyFrames
        )
    }
}

'''
fir = fir.replace(append_anchor, extension + append_anchor, 1)
fir_path.write_text(fir)

project = project_path.read_text()
old_call = '''            sampleRate: sweep.sampleRate,\n            usableLowHz: usable.low,\n            usableHighHz: usable.high,\n            name: proposedName,\n'''
new_call = '''            sampleRate: sweep.sampleRate,\n            usableLowHz: usable.low,\n            usableHighHz: usable.high,\n            sourcePositions: updated.measurements\n                .filter { $0.included && $0.weight > 0 }\n                .map { RoomCorrectionDesignSourcePosition(id: $0.id, weight: $0.weight) },\n            name: proposedName,\n'''
assert old_call in project
project = project.replace(old_call, new_call, 1)

anchor = '''    func selectDesign(id: UUID, modifiedAt: Date = Date()) throws {\n'''
assert anchor in project
summary_method = r'''    func deploymentSummary(for design: RoomCorrectionDesign) throws -> RoomCorrectionCalibrationSummary {
        let current = try requiredProject()
        guard current.designs.contains(where: { $0.id == design.id }) else {
            throw RoomCorrectionProjectControllerError.designNotFound(design.id)
        }
        let sourceIDs = design.sourcePositions?.map(\.id)
            ?? current.aggregate?.includedPositionIDs
            ?? []
        let sourceSet = Set(sourceIDs)
        let measurementDate = current.measurements
            .filter { sourceSet.contains($0.id) }
            .flatMap { [$0.left.capturedAt, $0.right.capturedAt] }
            .max()
        let targetName = design.target?.name ?? current.target?.name ?? "Custom Target"
        return RoomCorrectionCalibrationSummary(
            projectID: current.id,
            activeDesignID: design.id,
            measurementDate: measurementDate,
            designDate: design.createdAt,
            positionCount: sourceIDs.count,
            correctionLowHz: design.effectiveCorrectionLowHz ?? design.parameters.correctionLowHz,
            correctionHighHz: design.effectiveCorrectionHighHz ?? design.parameters.correctionHighHz,
            targetName: targetName,
            smoothingOctaves: design.parameters.smoothingOctaves,
            maximumBoostDB: design.parameters.maximumBoostDB,
            maximumCutDB: design.parameters.maximumCutDB,
            recommendedHeadroomDB: design.recommendedHeadroomDB,
            algorithmVersion: design.algorithmVersion
        )
    }

'''
project = project.replace(anchor, summary_method + anchor, 1)
project_path.write_text(project)

fir_tests = fir_tests_path.read_text()
insert = r'''

    func testDeploymentFilterEmbedsRecommendedHeadroomWithoutMutatingDesign() throws {
        let frequencies: [Double] = [20, 80, 200, 1_000, 5_000, 10_000, 20_000]
        let measured = aggregate(
            frequencies: frequencies,
            left: Array(repeating: -3, count: frequencies.count),
            right: Array(repeating: -3, count: frequencies.count)
        )
        let result = try RoomCorrectionFIRDesigner().design(
            aggregate: measured,
            target: RoomCorrectionBuiltInTarget.flat.curve,
            parameters: parameters(taps: 1_024),
            sampleRate: 48_000
        )
        let original = result.design.filter
        let deployed = try result.design.deploymentFilter()
        let expectedScale = pow(10.0, -result.design.recommendedHeadroomDB / 20.0)

        XCTAssertEqual(result.design.filter, original, "Deployment normalization must not mutate the reproducible design asset")
        XCTAssertEqual(deployed.sampleRate, original.sampleRate)
        XCTAssertEqual(deployed.declaredLatencyFrames, original.declaredLatencyFrames)
        XCTAssertEqual(deployed.leftTaps.count, original.leftTaps.count)
        for index in deployed.leftTaps.indices {
            XCTAssertEqual(
                Double(deployed.leftTaps[index]),
                Double(original.leftTaps[index]) * expectedScale,
                accuracy: 0.000_001
            )
        }
    }
'''
assert fir_tests.endswith('\n}\n')
fir_tests = fir_tests[:-3] + insert + '\n}\n'
fir_tests_path.write_text(fir_tests)

project_tests = project_tests_path.read_text()
insert = r'''

    func testGeneratedDesignSnapshotsSourcePositionsRangeAndDeploymentSummary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 10),
            sweep: sweep(),
            microphone: microphone()
        )
        let secondID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 20),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setMeasurementWeight(id: firstID, weight: 1)
        try fixture.controller.setMeasurementWeight(id: secondID, weight: 2)
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 80,
            correctionHighHz: 2_000,
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            requestedTapCount: 1_024
        )
        let design = try fixture.controller.generateDesign(
            parameters: parameters,
            name: "Deploy Fixture",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            design.sourcePositions,
            [
                RoomCorrectionDesignSourcePosition(id: firstID, weight: 1),
                RoomCorrectionDesignSourcePosition(id: secondID, weight: 2),
            ]
        )
        XCTAssertEqual(design.effectiveCorrectionLowHz, 100, accuracy: 0.000_001)
        XCTAssertEqual(design.effectiveCorrectionHighHz, 1_000, accuracy: 0.000_001)
        let summary = try fixture.controller.deploymentSummary(for: design)
        XCTAssertEqual(summary.projectID, fixture.controller.project?.id)
        XCTAssertEqual(summary.activeDesignID, design.id)
        XCTAssertEqual(summary.positionCount, 2)
        XCTAssertEqual(summary.targetName, "Flat")
        XCTAssertEqual(summary.correctionLowHz, 100, accuracy: 0.000_001)
        XCTAssertEqual(summary.correctionHighHz, 1_000, accuracy: 0.000_001)
        XCTAssertEqual(summary.measurementDate, Date(timeIntervalSince1970: 20))
    }

    func testProfileRoomCorrectionDeploymentChangesOnlyRoomOwnedStateAndRestoresWithoutSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let beforeSystem = try XCTUnwrap(profiles.selectedSystemProfile).state
        let filter = RoomCorrectionFilter(
            name: "Deployed Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let configuration = RoomCorrectionConfiguration(enabled: true, filter: filter)
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 200),
            positionCount: 2,
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            targetName: "Flat",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 3.5,
            algorithmVersion: "fixture"
        )

        try profiles.replaceSelectedSystemRoomCorrection(configuration, calibrationSummary: summary)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, configuration)
        var expectedSystem = beforeSystem
        expectedSystem.roomCorrection = configuration
        expectedSystem.roomCorrectionCalibration = summary
        XCTAssertEqual(profiles.selectedSystemProfile?.state, expectedSystem)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrection, configuration)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, configuration)
    }

    func testProfileDeploymentPersistenceFailureRollsBackEngineAndProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeEngine = engine.roomCorrectionConfiguration
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)
        let configuration = RoomCorrectionConfiguration(
            enabled: true,
            filter: RoomCorrectionFilter(
                name: "Rollback Fixture",
                sampleRate: nil,
                leftTaps: [1],
                rightTaps: nil,
                declaredLatencyFrames: 0
            )
        )

        XCTAssertThrowsError(
            try profiles.replaceSelectedSystemRoomCorrection(configuration, calibrationSummary: nil)
        )
        XCTAssertEqual(engine.roomCorrectionConfiguration, beforeEngine)
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }
'''
assert project_tests.endswith('\n}\n')
project_tests = project_tests[:-3] + insert + '\n}\n'
project_tests_path.write_text(project_tests)
