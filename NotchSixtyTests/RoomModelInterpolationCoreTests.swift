import XCTest
@testable import NotchSixty

/// E29 S3 (`e29.room-model`): the interpolation core through the Swift import. The maths and the image-source
/// reference room are covered at the eight rates by `core/tests/test_roommodel.cpp`; these tests cover the imported
/// surface: struct sizes, refusal outside the trust radius, and agreement at the eight rates between a query at a
/// measured point and that point's own response.
final class RoomModelInterpolationCoreTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func query(rate: Double, at: [Double], count: Int) -> n60_roommodel_query {
        var q = n60_roommodel_query()
        q.structSize = UInt32(MemoryLayout<n60_roommodel_query>.size)
        q.fftSize = 4096
        q.sampleRate = rate
        q.source = (-2, 0.5, 1)
        q.query = (at[0], at[1], at[2])
        q.neighbourCount = UInt32(count)
        return q
    }

    private func result() -> n60_roommodel_result {
        var r = n60_roommodel_result()
        r.structSize = UInt32(MemoryLayout<n60_roommodel_result>.size)
        return r
    }

    /// A direct arrival at the geometric delay from the source, with a late reflection scaled by `gain`.
    private func ir(rate: Double, position: [Double], gain: Float) -> [Float] {
        var h = [Float](repeating: 0, count: 2048)
        h[100] = 1
        h[100 + 300] = gain
        return h
    }

    func testCoreVersionAndSizesMatchTheHeader() {
        XCTAssertEqual(n60_roommodel_abi_version(), UInt32(N60_ROOMMODEL_ABI_VERSION))
        XCTAssertEqual(n60_roommodel_crossover_hz(0.5, 343), 171.5, accuracy: 1e-9)
    }

    func testQueryAtAMeasuredPointReturnsItsOwnLevelsAtEveryRate() {
        for rate in Self.rates {
            let pos = [0.5, 1.0, 1.2]
            let h = ir(rate: rate, position: pos, gain: 0.5)
            h.withUnsafeBufferPointer { buf in
                var nb = n60_roommodel_neighbour(position: (pos[0], pos[1], pos[2]), ir: buf.baseAddress,
                                                 irFrames: UInt32(buf.count), phaseTrusted: 1, repeatScatterDb: 0)
                var q = query(rate: rate, at: pos, count: 1)
                var r = result()
                XCTAssertEqual(n60_roommodel_interpolate(&q, &nb, &r, nil, nil), Int32(N60_ROOMMODEL_OK))
                XCTAssertEqual(r.neighboursUsed, 1)
                XCTAssertEqual(r.complexValid, 1)
                // A direct arrival plus a half-height echo: the level sits within +-4 dB of the impulse level (0 dB).
                XCTAssertEqual(r.levelDb.8, 0, accuracy: 4.0, "rate \(rate)")
            }
        }
    }

    func testQueryBeyondTheTrustRadiusIsNotMeasured() {
        let h = ir(rate: 48_000, position: [0.5, 1.0, 1.2], gain: 0)
        h.withUnsafeBufferPointer { buf in
            var nb = n60_roommodel_neighbour(position: (0.5, 1.0, 1.2), ir: buf.baseAddress,
                                             irFrames: UInt32(buf.count), phaseTrusted: 1, repeatScatterDb: 0)
            var q = query(rate: 48_000, at: [1.2, 1.0, 1.2], count: 1)  // 0.7 m away
            var r = result()
            XCTAssertEqual(n60_roommodel_interpolate(&q, &nb, &r, nil, nil), Int32(N60_ROOMMODEL_NOT_MEASURED))
            XCTAssertEqual(r.reason, Int32(N60_ROOMMODEL_REASON_OUTSIDE_TRUST))
            XCTAssertEqual(r.neighboursUsed, 0)
        }
    }

    func testBadArgumentsAreRefusedNotCrashed() {
        var q = query(rate: 48_000, at: [0, 0, 0], count: 0)
        var r = result()
        XCTAssertEqual(n60_roommodel_interpolate(nil, nil, &r, nil, nil), Int32(N60_ROOMMODEL_ERR_ARGUMENT))
        q.fftSize = 1000
        XCTAssertEqual(n60_roommodel_interpolate(&q, nil, &r, nil, nil), Int32(N60_ROOMMODEL_ERR_ARGUMENT))
    }
}
