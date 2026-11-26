import XCTest
@testable import NotchSixty

/// A convolution program the kernel needs when a corpus record is written.
struct E23KernelProgram {
    var kind: UnifiedGraphProgramKind
    var left: [Float]
    var right: [Float]?
    var declared: UInt32
}

/// E23 T1b: the only remaining use of `N60RenderKernel` by the stereo parity tests. It runs only when a corpus record
/// is written (`N60_E23_WRITE_CORPUS=1`, see `E23Corpus`). E23 K2 deletes this file together with the kernel.
enum E23KernelReference {
    static func render(
        _ snapshot: N60DSPGraphSnapshot, programs: [E23KernelProgram], input: [[Float]]
    ) throws -> [[Float]] {
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        var s = snapshot
        for program in programs {
            var info = N60ConvolutionProgramInfo()
            let count = UInt32(program.left.count)
            let ok: Bool = program.left.withUnsafeBufferPointer { l in
                func call(_ r: UnsafePointer<Float>?) -> Bool {
                    switch program.kind {
                    case .convolution:
                        return N60RenderKernelPrepareConvolutionProgram(kernel, 0, l.baseAddress!, r, count, program.declared, &info)
                    case .roomCorrection:
                        return N60RenderKernelPrepareRoomCorrectionProgram(kernel, 0, l.baseAddress!, r, count, program.declared, &info)
                    case .speakerIR:
                        return N60RenderKernelPrepareSpeakerIRProgram(kernel, 0, l.baseAddress!, r, count, program.declared, &info)
                    }
                }
                if let right = program.right { return right.withUnsafeBufferPointer { call($0.baseAddress) } }
                return call(nil)
            }
            XCTAssertTrue(ok)
            switch program.kind {
            case .convolution: XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&s, 0, info, true))
            case .roomCorrection: XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&s, 0, info, true))
            case .speakerIR: XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerIRProgram(&s, 0, info, true))
            }
        }
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, s))
        var left = [Float](repeating: 0, count: input[0].count)
        var right = left
        for i in 0..<left.count {
            N60RenderKernelProcessStereoFrame(kernel, input[0][i], input[1][i], &left[i], &right[i])
        }
        return [left, right]
    }
}
