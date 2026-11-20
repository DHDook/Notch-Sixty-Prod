import Darwin
import Foundation
import XCTest
@testable import NotchSixty

/// E21 S1: the portable core's one versioned entry point and its link surface in the app target.
final class N60CoreABITests: XCTestCase {
    func testCoreABIReportsEveryHeaderVersionAndStructSize() {
        var info = n60_core_abi_info()
        info.structSize = UInt32(MemoryLayout<n60_core_abi_info>.size)
        XCTAssertEqual(n60_core_abi(&info, MemoryLayout<n60_core_abi_info>.size), 1)
        XCTAssertEqual(info.structSize, UInt32(MemoryLayout<n60_core_abi_info>.size))
        XCTAssertEqual(info.infoVersion, UInt32(N60_CORE_ABI_INFO_VERSION))
        XCTAssertEqual(info.graphVersion, UInt32(N60_GRAPH_ABI_VERSION))
        XCTAssertEqual(info.measureVersion, UInt32(N60_MEASURE_ABI_VERSION))
        XCTAssertEqual(info.correctVersion, UInt32(N60_CORRECT_ABI_VERSION))
        XCTAssertEqual(info.xoverVersion, UInt32(N60_XOVER_ABI_VERSION))
        XCTAssertEqual(info.headroomVersion, UInt32(N60_HEADROOM_ABI_VERSION))
        XCTAssertEqual(info.mimoVersion, UInt32(N60_MIMO_ABI_VERSION))
        XCTAssertEqual(info.foldVersion, UInt32(N60_FOLD_ABI_VERSION))
        // The library's compiled struct sizes match what Swift imported from the same headers.
        XCTAssertEqual(Int(info.graphDescSize), MemoryLayout<n60_graph_desc>.size)
        XCTAssertEqual(Int(info.stageDescSize), MemoryLayout<n60_stage_desc>.size)
        XCTAssertEqual(Int(info.measureEssSize), MemoryLayout<n60_measure_ess_params>.size)
        XCTAssertEqual(Int(info.correctProblemSize), MemoryLayout<n60_correct_problem>.size)
        XCTAssertEqual(Int(info.xoverSpecSize), MemoryLayout<n60_xover_spec>.size)
        XCTAssertEqual(Int(info.headroomPathSize), MemoryLayout<n60_headroom_path>.size)
        XCTAssertEqual(Int(info.mimoProblemSize), MemoryLayout<n60_mimo_problem>.size)
        XCTAssertEqual(Int(info.foldMatrixSize), MemoryLayout<n60_fold_matrix>.size)
    }

    func testCoreABIRejectsNullAndTruncatedInfo() {
        XCTAssertEqual(n60_core_abi(nil, 64), 0)
        var info = n60_core_abi_info()
        XCTAssertEqual(n60_core_abi(&info, 4), 0)
    }

    func testCoreABIFillsAnOlderShorterStruct() {
        var info = n60_core_abi_info()
        let shortSize = 3 * MemoryLayout<UInt32>.size
        XCTAssertEqual(n60_core_abi(&info, shortSize), 1)
        XCTAssertEqual(Int(info.structSize), shortSize)
        XCTAssertEqual(info.graphVersion, UInt32(N60_GRAPH_ABI_VERSION))
        XCTAssertEqual(info.measureVersion, 0, "fields past the caller's size stay untouched")
    }

    /// One exported symbol from each core translation unit that has a public entry point. A source file missing from
    /// the Xcode libn60core group leaves its symbol out of the app, so this fails instead of the gap surfacing in a
    /// release link. (Translation units with no public symbol are reached through graph.cpp and fail to link.)
    func testEveryCoreTranslationUnitIsLinkedIntoTheApp() {
        let symbols = [
            "n60_graph_abi_version", "n60_fold_matrix_make", "n60_layout_describe", "n60_resample_output_count",
            "n60_measure_ess_describe", "n60_measure_deconvolve", "n60_measure_room_defaults",
            "n60_measure_chirp_defaults", "n60_measure_distortion_defaults", "n60_measure_decay_analyze",
            "n60_measure_waterfall_defaults", "n60_monitor_ring_create", "n60_spl_create", "n60_rta_default_fft_size",
            "n60_measure_predict_treated_length", "n60_mimo_abi_version", "n60_correct_abi_version",
            "n60_correct_design_defaults", "n60_correct_synth_defaults", "n60_correct_bass_channel_defaults",
            "n60_correct_multisub_search", "n60_eq_linear_phase_design", "n60_xover_abi_version", "n60_headroom_abi_version", "n60_core_abi",
        ]
        let handle = dlopen(nil, RTLD_NOW)
        for name in symbols {
            XCTAssertNotNil(dlsym(handle, name), "\(name) is not linked into the app")
        }
    }
}
