import XCTest
@testable import NotchSixty

/// E23 T1b: the frozen corpus. Until the render kernel is deleted (E23 K2) it was the independent reference for the
/// multi-stage parity tests. Each case now compares the graph's output with a record checked in under
/// `NotchSixtyTests/Fixtures/E23Corpus/`: the latency in frames, 64 block RMS values (dB), the peak (dB) and the first 64
/// samples after the latency, per lane (design note 4; the sample count is the T2 cut, G26). A record is compared within
/// 0.01 dB block RMS and 1e-5 absolute per sample (owner, Q3).
///
/// A record is written only by a Debug run with `N60_E23_WRITE_CORPUS=1`. That run renders the kernel as well
/// (`E23KernelReference`), runs the test's own kernel-parity assertions on the pair, and only then stores the graph's output,
/// so a record is always one that agreed with the kernel at the test's original tolerance. After K2 a record can no longer
/// be regenerated against the kernel; changing one is then a deliberate DSP change with a cited reason.
/// `N60_E23_CORPUS_OUT` names the directory to write to (default: the checked-in fixtures directory).
enum E23Corpus {
    static let blockCount = 64
    static let sampleCount = 64
    static let blockToleranceDB: Float = 0.01
    static let sampleTolerance: Float = 1e-5
    /// Blocks quieter than this read as this level, so near-silence does not make the dB comparison noisy.
    static let floorDB: Float = -120

    struct Lane: Equatable {
        var peakDB: Float
        var blocksDB: [Float]
        var samples: [Float]
    }

    struct Record: Equatable {
        var latency: Int
        var lanes: [Lane]
    }

    static var isWriting: Bool { ProcessInfo.processInfo.environment["N60_E23_WRITE_CORPUS"] == "1" }

    // MARK: Summary and comparison

    static func level(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return floorDB }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return max(Float(10 * log10(max(sum / Double(x.count), 1e-30))), floorDB)
    }

    static func summarise(_ output: [[Float]], latency: Int) -> Record {
        let lanes = output.map { lane -> Lane in
            let size = max(lane.count / blockCount, 1)
            let blocks = (0..<blockCount).map { b -> Float in
                let lower = min(b * size, lane.count), upper = min(lower + size, lane.count)
                return level(lane[lower..<upper])
            }
            let peak = lane.reduce(Float(0)) { max($0, abs($1)) }
            let from = min(latency, lane.count)
            var samples = Array(lane[from..<min(from + sampleCount, lane.count)])
            samples += [Float](repeating: 0, count: sampleCount - samples.count)
            return Lane(peakDB: max(20 * log10(max(peak, 1e-12)), floorDB), blocksDB: blocks, samples: samples)
        }
        return Record(latency: latency, lanes: lanes)
    }

    /// Differences between `got` and the frozen `expected`; empty means it matches.
    static func differences(expected: Record, got: Record) -> [String] {
        var found: [String] = []
        if expected.latency != got.latency { found.append("latency \(got.latency), frozen \(expected.latency)") }
        guard expected.lanes.count == got.lanes.count else { return found + ["lane count \(got.lanes.count)"] }
        for (lane, pair) in zip(expected.lanes, got.lanes).enumerated() {
            let (e, g) = pair
            if abs(e.peakDB - g.peakDB) > blockToleranceDB { found.append("lane \(lane) peak \(g.peakDB) dB, frozen \(e.peakDB)") }
            for (index, (a, b)) in zip(e.blocksDB, g.blocksDB).enumerated() where abs(a - b) > blockToleranceDB {
                found.append("lane \(lane) block \(index) \(b) dB, frozen \(a)")
            }
            for (index, (a, b)) in zip(e.samples, g.samples).enumerated() where abs(a - b) > sampleTolerance {
                found.append("lane \(lane) sample \(index) \(b), frozen \(a)")
            }
        }
        return found
    }

    // MARK: Storage

    private struct LaneJSON: Codable { var peakDB: Float; var blocksDB: String; var samples: String }
    private struct RecordJSON: Codable { var latency: Int; var lanes: [LaneJSON] }
    private struct FileJSON: Codable { var format: String; var records: [String: RecordJSON] }
    private static let formatNote = "E23 T1b frozen corpus: arrays are little-endian Float32 as base64; see E23Corpus.swift"

    private static func pack(_ values: [Float]) -> String {
        values.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
    }

    private static func unpack(_ text: String) -> [Float] {
        guard let data = Data(base64Encoded: text) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func encode(_ r: Record) -> RecordJSON {
        RecordJSON(latency: r.latency, lanes: r.lanes.map {
            LaneJSON(peakDB: $0.peakDB, blocksDB: pack($0.blocksDB), samples: pack($0.samples))
        })
    }

    private static func decode(_ r: RecordJSON) -> Record {
        Record(latency: r.latency, lanes: r.lanes.map {
            Lane(peakDB: $0.peakDB, blocksDB: unpack($0.blocksDB), samples: unpack($0.samples))
        })
    }

    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/E23Corpus")
    }

    private static var outputDirectory: URL {
        ProcessInfo.processInfo.environment["N60_E23_CORPUS_OUT"].map { URL(fileURLWithPath: $0) } ?? sourceDirectory
    }

    private final class Marker {}

    private static func fileURL(_ group: String) -> URL? {
        if let bundled = Bundle(for: Marker.self).url(forResource: group, withExtension: "json") { return bundled }
        let direct = sourceDirectory.appendingPathComponent("\(group).json")
        return FileManager.default.isReadableFile(atPath: direct.path) ? direct : nil
    }

    nonisolated(unsafe) private static var cache: [String: [String: Record]] = [:]
    nonisolated(unsafe) private static var occurrences: [String: Int] = [:]

    private static func records(_ group: String, forWriting: Bool) -> [String: Record] {
        if let cached = cache[group] { return cached }
        var loaded: [String: Record] = [:]
        let url = forWriting ? outputDirectory.appendingPathComponent("\(group).json") : fileURL(group)
        if let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(FileJSON.self, from: data) {
            loaded = file.records.mapValues(decode)
        }
        cache[group] = loaded
        return loaded
    }

    private static func store(_ group: String, key: String, _ record: Record) throws {
        var all = records(group, forWriting: true)
        all[key] = record
        cache[group] = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(FileJSON(format: formatNote, records: all.mapValues(encode)))
        try data.write(to: outputDirectory.appendingPathComponent("\(group).json"))
    }

    /// Call from `setUp` of every class that uses `check`: a repeated label inside one test gets its own record.
    static func beginTest() { occurrences = [:] }

    private static func uniqueKey(_ base: String) -> String {
        let n = occurrences[base, default: 0]
        occurrences[base] = n + 1
        return n == 0 ? base : "\(base)#\(n)"
    }

    // MARK: Check

    /// Compares the graph's `output` with the frozen record. When writing, renders the kernel from `snapshot`, `programs`
    /// and `input` too, calls `kernelParity(kernel, graph)` (the test's original assertions) and stores the record.
    static func check(
        group: String, test: String, label: String, rate: Double,
        snapshot: N60DSPGraphSnapshot, programs: [E23KernelProgram] = [], input: [[Float]],
        output: [[Float]], latency: Int, kernelParity: ([[Float]], [[Float]]) throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let key = uniqueKey("\(test)/\(label)/\(Int(rate))")
        let got = summarise(output, latency: latency)
        if isWriting {
            let kernel = try E23KernelReference.render(snapshot, programs: programs, input: input)
            try kernelParity(kernel, output)
            try store(group, key: key, got)
            return
        }
        guard let expected = records(group, forWriting: false)[key] else {
            XCTFail("no frozen corpus record '\(key)' in \(group).json; regenerate with N60_E23_WRITE_CORPUS=1", file: file, line: line)
            return
        }
        let diffs = differences(expected: expected, got: got)
        XCTAssertTrue(diffs.isEmpty, "\(key): \(diffs.prefix(4).joined(separator: "; ")) (\(diffs.count) differences)", file: file, line: line)
    }
}
