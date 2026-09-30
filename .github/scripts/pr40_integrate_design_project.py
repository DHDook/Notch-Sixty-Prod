from pathlib import Path

controller_path = Path('NotchSixty/State/RoomCorrectionProjectController.swift')
tests_path = Path('NotchSixtyTests/RoomCorrectionProjectControllerTests.swift')

controller = controller_path.read_text()

old = '''    case positionNotFound(UUID)\n    case measurementAlreadyRetained\n'''
new = '''    case positionNotFound(UUID)\n    case measurementAlreadyRetained\n    case aggregateUnavailable\n    case targetUnavailable\n    case designNotFound(UUID)\n    case measurementNotDesignable(positionID: UUID, pass: RoomCorrectionMeasurementPass)\n    case noUsableMeasurementRange\n'''
assert old in controller
controller = controller.replace(old, new, 1)

old = '''        case .measurementAlreadyRetained:\n            return "This analyzed measurement is already saved in the current project."\n        }\n'''
new = '''        case .measurementAlreadyRetained:\n            return "This analyzed measurement is already saved in the current project."\n        case .aggregateUnavailable:\n            return "Retain and include at least one weighted room measurement before previewing or designing correction."\n        case .targetUnavailable:\n            return "Choose or import a room-correction target before previewing or designing correction."\n        case .designNotFound(let id):\n            return "Room-correction design \\(id.uuidString) was not found in the current project."\n        case .measurementNotDesignable(let positionID, let pass):\n            return "Room measurement \\(positionID.uuidString) has insufficient \\(pass.rawValue) quality for correction design. Re-measure or exclude that position."\n        case .noUsableMeasurementRange:\n            return "The included measurements do not share a usable frequency range for correction design."\n        }\n'''
assert old in controller
controller = controller.replace(old, new, 1)

old = '''    var aggregate: RoomCorrectionAggregateResponse? { project?.aggregate }\n\n\n    var suggestedPositionName: String {\n'''
new = '''    var aggregate: RoomCorrectionAggregateResponse? { project?.aggregate }\n    var target: RoomCorrectionTargetCurve? { project?.target }\n    var designs: [RoomCorrectionDesign] { project?.designs ?? [] }\n    var selectedDesign: RoomCorrectionDesign? {\n        guard let project, let selectedDesignID = project.selectedDesignID else { return nil }\n        return project.designs.first { $0.id == selectedDesignID }\n    }\n\n    var suggestedPositionName: String {\n'''
assert old in controller
controller = controller.replace(old, new, 1)

old = '''    func setMeasurementWeight(id: UUID, weight: Double, modifiedAt: Date = Date()) throws {\n        guard weight.isFinite, weight >= 0 else {\n            throw RoomCorrectionProjectControllerError.invalidWeight(weight)\n        }\n        var updated = try requiredProject()\n        guard let index = updated.measurements.firstIndex(where: { $0.id == id }) else {\n            throw RoomCorrectionProjectControllerError.positionNotFound(id)\n        }\n        updated.measurements[index].weight = weight\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        try persistAndPublish(updated)\n    }\n\n    private func projectForMutation(\n'''
new = '''    func setMeasurementWeight(id: UUID, weight: Double, modifiedAt: Date = Date()) throws {\n        guard weight.isFinite, weight >= 0 else {\n            throw RoomCorrectionProjectControllerError.invalidWeight(weight)\n        }\n        var updated = try requiredProject()\n        guard let index = updated.measurements.firstIndex(where: { $0.id == id }) else {\n            throw RoomCorrectionProjectControllerError.positionNotFound(id)\n        }\n        updated.measurements[index].weight = weight\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        try persistAndPublish(updated)\n    }\n\n    func setTarget(_ target: RoomCorrectionTargetCurve, modifiedAt: Date = Date()) throws {\n        var updated = try requiredProject()\n        updated.target = target\n        // A target edit invalidates candidate selection, but retained historical\n        // designs remain reproducibility assets. Deployed playback is owned by\n        // the Playback System profile and is intentionally untouched here.\n        updated.selectedDesignID = nil\n        updated.modifiedAt = modifiedAt\n        try persistAndPublish(updated)\n    }\n\n    func previewDesign(\n        parameters: RoomCorrectionDesignParameters\n    ) throws -> RoomCorrectionCorrectionPreview {\n        let current = try requiredProject()\n        guard let aggregate = current.aggregate else {\n            throw RoomCorrectionProjectControllerError.aggregateUnavailable\n        }\n        guard let target = current.target else {\n            throw RoomCorrectionProjectControllerError.targetUnavailable\n        }\n        let usable = try usableDesignRange(in: current)\n        return try RoomCorrectionCorrectionPreviewDesigner().preview(\n            aggregate: aggregate,\n            target: target,\n            parameters: parameters,\n            usableLowHz: usable.low,\n            usableHighHz: usable.high\n        )\n    }\n\n    @discardableResult\n    func generateDesign(\n        parameters: RoomCorrectionDesignParameters,\n        name proposedName: String = "Room Correction",\n        createdAt: Date = Date()\n    ) throws -> RoomCorrectionDesign {\n        var updated = try requiredProject()\n        guard let aggregate = updated.aggregate else {\n            throw RoomCorrectionProjectControllerError.aggregateUnavailable\n        }\n        guard let target = updated.target else {\n            throw RoomCorrectionProjectControllerError.targetUnavailable\n        }\n        guard let sweep = updated.sweep else {\n            throw RoomCorrectionProjectControllerError.aggregateUnavailable\n        }\n        let usable = try usableDesignRange(in: updated)\n        let result = try RoomCorrectionFIRDesigner().design(\n            aggregate: aggregate,\n            target: target,\n            parameters: parameters,\n            sampleRate: sweep.sampleRate,\n            usableLowHz: usable.low,\n            usableHighHz: usable.high,\n            name: proposedName,\n            createdAt: createdAt\n        )\n        updated.designs.append(result.design)\n        updated.selectedDesignID = result.design.id\n        updated.modifiedAt = createdAt\n        try persistAndPublish(updated)\n        return result.design\n    }\n\n    func selectDesign(id: UUID, modifiedAt: Date = Date()) throws {\n        var updated = try requiredProject()\n        guard updated.designs.contains(where: { $0.id == id }) else {\n            throw RoomCorrectionProjectControllerError.designNotFound(id)\n        }\n        updated.selectedDesignID = id\n        updated.modifiedAt = modifiedAt\n        try persistAndPublish(updated)\n    }\n\n    func deleteDesign(id: UUID, modifiedAt: Date = Date()) throws {\n        var updated = try requiredProject()\n        guard updated.designs.contains(where: { $0.id == id }) else {\n            throw RoomCorrectionProjectControllerError.designNotFound(id)\n        }\n        updated.designs.removeAll { $0.id == id }\n        if updated.selectedDesignID == id { updated.selectedDesignID = nil }\n        updated.modifiedAt = modifiedAt\n        try persistAndPublish(updated)\n    }\n\n    private func projectForMutation(\n'''
assert old in controller
controller = controller.replace(old, new, 1)

old = '''    private func aggregateOrNil(\n        _ positions: [RoomCorrectionMeasurementPosition],\n        generatedAt: Date\n    ) throws -> RoomCorrectionAggregateResponse? {\n'''
new = '''    private func usableDesignRange(in project: RoomCorrectionProject) throws -> (low: Double, high: Double) {\n        guard let aggregate = project.aggregate,\n              let aggregateLow = aggregate.leftResponse.frequenciesHz.first,\n              let aggregateHigh = aggregate.leftResponse.frequenciesHz.last else {\n            throw RoomCorrectionProjectControllerError.aggregateUnavailable\n        }\n        let contributors = project.measurements.filter { $0.included && $0.weight > 0 }\n        guard !contributors.isEmpty else {\n            throw RoomCorrectionProjectControllerError.aggregateUnavailable\n        }\n\n        var low = aggregateLow\n        var high = aggregateHigh\n        for position in contributors {\n            for (pass, measurement) in [\n                (RoomCorrectionMeasurementPass.left, position.left),\n                (RoomCorrectionMeasurementPass.right, position.right),\n            ] {\n                let quality = measurement.quality\n                guard quality.sweepComplete,\n                      !quality.clipped,\n                      let snr = quality.estimatedSNRDB,\n                      snr >= RoomCorrectionMeasurementAnalyzer.lowSNRWarningDB,\n                      let usableLow = quality.usableLowHz,\n                      let usableHigh = quality.usableHighHz,\n                      usableLow.isFinite, usableHigh.isFinite,\n                      usableLow > 0, usableHigh > usableLow else {\n                    throw RoomCorrectionProjectControllerError.measurementNotDesignable(\n                        positionID: position.id,\n                        pass: pass\n                    )\n                }\n                low = max(low, usableLow)\n                high = min(high, usableHigh)\n            }\n        }\n        guard high > low else {\n            throw RoomCorrectionProjectControllerError.noUsableMeasurementRange\n        }\n        return (low, high)\n    }\n\n    private func aggregateOrNil(\n        _ positions: [RoomCorrectionMeasurementPosition],\n        generatedAt: Date\n    ) throws -> RoomCorrectionAggregateResponse? {\n'''
assert old in controller
controller = controller.replace(old, new, 1)

controller_path.write_text(controller)

tests = tests_path.read_text()
old = '''    private func analysis(\n        capturedAt: TimeInterval,\n        leftMagnitude: [Double] = [0, 0],\n        rightMagnitude: [Double] = [0, 0],\n        frequencies: [Double] = [100, 1_000],\n        sampleRate: Double = 48_000\n    ) -> RoomCorrectionMeasurementAnalysis {\n'''
new = '''    private func analysis(\n        capturedAt: TimeInterval,\n        leftMagnitude: [Double] = [0, 0],\n        rightMagnitude: [Double] = [0, 0],\n        frequencies: [Double] = [100, 1_000],\n        sampleRate: Double = 48_000,\n        clipped: Bool = false,\n        snr: Double = 45,\n        sweepComplete: Bool = true\n    ) -> RoomCorrectionMeasurementAnalysis {\n'''
assert old in tests
tests = tests.replace(old, new, 1)
tests = tests.replace('''            clipped: false,\n            playbackPeakDBFS: -18,\n            capturePeakDBFS: -12,\n            estimatedNoiseFloorDBFS: -70,\n            estimatedSNRDB: 45,\n            sweepComplete: true,\n''', '''            clipped: clipped,\n            playbackPeakDBFS: -18,\n            capturePeakDBFS: -12,\n            estimatedNoiseFloorDBFS: -70,\n            estimatedSNRDB: snr,\n            sweepComplete: sweepComplete,\n''', 1)

insert = r'''

    func testTargetPreviewAndGeneratedDesignPersistTransactionally() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try fixture.controller.retainMeasurement(
            analysis(
                capturedAt: 1,
                leftMagnitude: [-2, -2],
                rightMagnitude: [2, 2]
            ),
            sweep: sweep(),
            microphone: microphone()
        )
        let target = RoomCorrectionBuiltInTarget.flat.curve
        try fixture.controller.setTarget(target)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 80,
            correctionHighHz: 2_000,
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )

        let preview = try fixture.controller.previewDesign(parameters: parameters)
        XCTAssertEqual(preview.effectiveCorrectionLowHz, 100, accuracy: 0.000_001)
        XCTAssertEqual(preview.effectiveCorrectionHighHz, 1_000, accuracy: 0.000_001)

        let design = try fixture.controller.generateDesign(
            parameters: parameters,
            name: "Fixture Design",
            createdAt: Date(timeIntervalSince1970: 900)
        )
        XCTAssertEqual(fixture.controller.selectedDesign?.id, design.id)
        XCTAssertEqual(fixture.controller.designs.count, 1)
        XCTAssertEqual(design.filter.leftTaps.count, 1_024)
        XCTAssertEqual(design.filter.rightTaps?.count, 1_024)
        XCTAssertEqual(design.filter.sampleRate, 48_000)

        let projectID = try XCTUnwrap(fixture.controller.project?.id)
        let persisted = try fixture.controller.store.load(projectID)
        XCTAssertEqual(persisted.target, target)
        XCTAssertEqual(persisted.selectedDesignID, design.id)
        XCTAssertEqual(persisted.designs, [design])
    }

    func testChangingTargetInvalidatesCandidateSelectionButKeepsDesignHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )
        let design = try fixture.controller.generateDesign(parameters: parameters)
        XCTAssertEqual(fixture.controller.selectedDesign?.id, design.id)

        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.gentleDownwardTilt.curve)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [design.id])
    }

    func testLowConfidenceMeasurementCannotSilentlyEnterCorrectionDesign() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let positionID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1, snr: 10),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )

        XCTAssertThrowsError(try fixture.controller.previewDesign(parameters: parameters)) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectControllerError,
                .measurementNotDesignable(positionID: positionID, pass: .left)
            )
        }
        XCTAssertTrue(fixture.controller.designs.isEmpty)
    }

    func testDesignSelectionAndDeletionPersist() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )
        let first = try fixture.controller.generateDesign(parameters: parameters, name: "First")
        let second = try fixture.controller.generateDesign(parameters: parameters, name: "Second")
        XCTAssertEqual(fixture.controller.selectedDesign?.id, second.id)

        try fixture.controller.selectDesign(id: first.id)
        XCTAssertEqual(fixture.controller.selectedDesign?.id, first.id)
        try fixture.controller.deleteDesign(id: first.id)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [second.id])
    }
'''
assert tests.endswith('\n}\n')
tests = tests[:-3] + insert + '\n}\n'
tests_path.write_text(tests)
