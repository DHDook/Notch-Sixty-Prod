import XCTest
@testable import NotchSixty

/// E13 S11 (`e13.headphones-page`): the built-in generic HRTF. The maths is covered at the eight rates by
/// `core/tests/test_hrtf.cpp`; these tests cover the Swift side: the asset is valid and native at each rate, the
/// cache generates it without resampling, a Virtual Speakers profile with no import validates and prepares for every
/// layout the page offers, and the translator builds a graph from it.
final class GenericHRTFTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func energy(_ ir: [Float]) -> Double { ir.reduce(0) { $0 + Double($1) * Double($1) } }

    func testAssetIsValidAndNativeAtEveryRate() throws {
        for rate in Self.rates {
            let asset = try XCTUnwrap(GenericHRTF.asset(sampleRate: rate), "rate \(rate)")
            try asset.validate()
            XCTAssertEqual(asset.sampleRate, rate)
            XCTAssertEqual(asset.tapCount, Int(n60_hrtf_generic_taps(rate)))
            XCTAssertEqual(asset.measurements.count, GenericHRTF.azimuths.count * GenericHRTF.elevations.count)
            XCTAssertTrue(asset.providesElevationSets)
            XCTAssertEqual(asset, GenericHRTF.asset(sampleRate: rate), "deterministic")
        }
    }

    func testLeftSourceIsLouderAndEarlierInTheLeftEar() throws {
        for rate in Self.rates {
            let asset = try XCTUnwrap(GenericHRTF.asset(sampleRate: rate))
            let left = try XCTUnwrap(asset.measurements.first { $0.azimuthDegrees == -60 && $0.elevationDegrees == 0 })
            XCTAssertGreaterThan(energy(left.leftIR), energy(left.rightIR), "rate \(rate)")
            func peak(_ ir: [Float]) -> Int { ir.indices.max { abs(ir[$0]) < abs(ir[$1]) }! }
            XCTAssertLessThan(peak(left.leftIR), peak(left.rightIR), "rate \(rate)")
        }
    }

    func testNoImportProfileValidatesAndPreparesForEveryLayout() throws {
        for rate in Self.rates {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.enabled = true
            profile.spatialMode = .virtualSpeakers
            profile.binauralProfile = GenericHRTF.reference
            for layout in OutputProgramLayout.allCases {
                profile.programLayout = layout
                XCTAssertNoThrow(try profile.validateStructure(sampleRate: rate), "\(layout) at \(rate)")
                let asset = try XCTUnwrap(GenericHRTF.asset(sampleRate: rate))
                let prepared = try asset.prepare(for: layout)
                XCTAssertEqual(prepared.leftIRs.count, layout.roles.count * asset.tapCount)
            }
        }
    }

    func testCacheGeneratesNativelyWithoutResampling() throws {
        let cache = BinauralResampledAssetCache()
        let store = BinauralProfileAssetStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("generic-hrtf-\(UUID().uuidString)"))
        for rate in Self.rates {
            let asset = try cache.asset(for: GenericHRTF.reference, sampleRate: rate, store: store)
            XCTAssertEqual(asset.sampleRate, rate)
            XCTAssertEqual(asset.tapCount, Int(n60_hrtf_generic_taps(rate)))
        }
        XCTAssertEqual(cache.conversionCount, 0)
    }

    func testStoreLoadsTheGenericReferenceWithoutAFile() throws {
        let store = BinauralProfileAssetStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("generic-hrtf-\(UUID().uuidString)"))
        let asset = try store.load(id: GenericHRTF.assetID)
        XCTAssertEqual(asset.reference, GenericHRTF.reference)
        XCTAssertEqual(try store.existingAssetIDs(), [])
    }

    func testTranslatorBuildsAGraphFromTheGenericProfile() throws {
        for rate in [44_100.0, 96_000, 384_000] {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.enabled = true
            profile.spatialMode = .virtualSpeakers
            profile.programLayout = .sevenOneFour
            profile.binauralProfile = GenericHRTF.reference
            let asset = try XCTUnwrap(GenericHRTF.asset(sampleRate: rate))
            let result = UnifiedGraphTranslator.binauralBaseSpec(
                asset: asset, layout: .sevenOneFour, profile: profile, outputChannels: 2,
                sampleRate: rate, headTracking: true)
            if case .failure(let reason) = result { XCTFail("rate \(rate): \(reason)") }
        }
    }
}
