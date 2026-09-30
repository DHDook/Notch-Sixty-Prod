from pathlib import Path

profiles_path = Path('NotchSixty/State/ProductProfiles.swift')
fir_path = Path('NotchSixty/Audio/RoomCorrectionFIRDesigner.swift')
controller_path = Path('NotchSixty/State/RoomCorrectionProjectController.swift')
fir_tests_path = Path('NotchSixtyTests/RoomCorrectionFIRDesignerTests.swift')
project_tests_path = Path('NotchSixtyTests/RoomCorrectionProjectControllerTests.swift')

profiles = profiles_path.read_text()
old = '''    var sampleRate: Double\n    var parameters: RoomCorrectionDesignParameters\n    var filter: RoomCorrectionFilter\n'''
new = '''    var sampleRate: Double\n    var parameters: RoomCorrectionDesignParameters\n    var target: RoomCorrectionTargetCurve? = nil\n    var filter: RoomCorrectionFilter\n'''
assert old in profiles
profiles = profiles.replace(old, new, 1)
old = '''        let filter = design.filter\n        let tapCount = filter.leftTaps.count\n'''
new = '''        if let target = design.target { try validateTarget(target) }\n        let filter = design.filter\n        let tapCount = filter.leftTaps.count\n'''
assert old in profiles
profiles = profiles.replace(old, new, 1)
profiles_path.write_text(profiles)

fir = fir_path.read_text()
old = '''            sampleRate: sampleRate,\n            parameters: parameters,\n            filter: filter,\n'''
new = '''            sampleRate: sampleRate,\n            parameters: parameters,\n            target: target,\n            filter: filter,\n'''
assert old in fir
fir = fir.replace(old, new, 1)
fir_path.write_text(fir)

controller = controller_path.read_text()
old = '''        updated.measurements.append(position)\n        updated.modifiedAt = retainedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: retainedAt)\n        try persistAndPublish(updated)\n'''
new = '''        updated.measurements.append(position)\n        updated.modifiedAt = retainedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: retainedAt)\n        updated.selectedDesignID = nil\n        try persistAndPublish(updated)\n'''
assert old in controller
controller = controller.replace(old, new, 1)
old = '''        updated.measurements[index].included = included\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        try persistAndPublish(updated)\n'''
new = '''        updated.measurements[index].included = included\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        updated.selectedDesignID = nil\n        try persistAndPublish(updated)\n'''
assert old in controller
controller = controller.replace(old, new, 1)
old = '''        updated.measurements[index].weight = weight\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        try persistAndPublish(updated)\n'''
new = '''        updated.measurements[index].weight = weight\n        updated.modifiedAt = modifiedAt\n        updated.aggregate = try aggregateOrNil(updated.measurements, generatedAt: modifiedAt)\n        updated.selectedDesignID = nil\n        try persistAndPublish(updated)\n'''
assert old in controller
controller = controller.replace(old, new, 1)
controller_path.write_text(controller)

fir_tests = fir_tests_path.read_text()
old = '''        XCTAssertEqual(result.design.algorithmVersion, RoomCorrectionFIRDesigner.algorithmVersion)\n        XCTAssertEqual(result.design.filter.leftTaps[0], 1, accuracy: 0.000_01)\n'''
new = '''        XCTAssertEqual(result.design.algorithmVersion, RoomCorrectionFIRDesigner.algorithmVersion)\n        XCTAssertEqual(result.design.target, RoomCorrectionBuiltInTarget.flat.curve)\n        XCTAssertEqual(result.design.filter.leftTaps[0], 1, accuracy: 0.000_01)\n'''
assert old in fir_tests
fir_tests = fir_tests.replace(old, new, 1)
fir_tests_path.write_text(fir_tests)

project_tests = project_tests_path.read_text()
insert = r'''

    func testAggregateMutationInvalidatesSelectedCandidateButRetainsDesignHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try fixture.controller.retainMeasurement(
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

        try fixture.controller.setMeasurementWeight(id: id, weight: 2)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [design.id])
    }
'''
assert project_tests.endswith('\n}\n')
project_tests = project_tests[:-3] + insert + '\n}\n'
project_tests_path.write_text(project_tests)
