import Foundation

/// Swift face of the portable crossover filter library (`n60/xover.h`, E8 S1).
///
/// Offline only: designs and evaluates crossover filters on a control or UI thread, never from an
/// audio callback. The graph stages added in later E8 slices run the same core code, so what the
/// editor predicts is what renders.
enum CrossoverCore {
    enum CoreError: Error, Equatable {
        case status(Int32)
    }

    enum Family: UInt32, CaseIterable, Codable, Sendable {
        case butterworth = 0
        case bessel = 1
        case linkwitzRiley = 2

        /// Orders the library designs: Butterworth and Bessel 1-8, Linkwitz-Riley 2, 4, 6, 8 (6 to 48 dB/oct).
        var orders: [Int] {
            self == .linkwitzRiley ? [2, 4, 6, 8] : Array(1...8)
        }
    }

    /// One filter: family, order and corner. High-pass and low-pass are specified independently.
    struct FilterSpec: Equatable, Hashable, Codable, Sendable {
        var family: Family
        var order: Int
        var cornerHz: Double

        var slopeDBPerOctave: Int { 6 * order }

        fileprivate var raw: n60_xover_spec {
            var spec = n60_xover_spec()
            spec.struct_size = UInt32(MemoryLayout<n60_xover_spec>.size)
            spec.family = family.rawValue
            spec.order = UInt32(order)
            spec.corner_hz = cornerHz
            return spec
        }
    }

    struct Biquad: Equatable, Sendable {
        var b0, b1, b2, a1, a2: Double
    }

    /// A designed cascade of biquads at one sample rate.
    struct Cascade: Equatable, Sendable {
        var sections: [Biquad]
        var sampleRate: Double

        fileprivate init(_ raw: n60_xover_cascade, sampleRate: Double) {
            var list: [Biquad] = []
            withUnsafeBytes(of: raw.sections) { buffer in
                let sections = buffer.bindMemory(to: n60_xover_biquad.self)
                for index in 0..<Int(raw.count) {
                    let s = sections[index]
                    list.append(Biquad(b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2))
                }
            }
            self.sections = list
            self.sampleRate = sampleRate
        }

        fileprivate var raw: n60_xover_cascade {
            var cascade = n60_xover_cascade()
            cascade.count = UInt32(sections.count)
            withUnsafeMutableBytes(of: &cascade.sections) { buffer in
                let out = buffer.bindMemory(to: n60_xover_biquad.self)
                for (index, s) in sections.enumerated() {
                    out[index] = n60_xover_biquad(b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2)
                }
            }
            return cascade
        }

        func response(atHz hz: Double) throws -> (re: Double, im: Double) {
            var cascade = raw
            var re = 0.0, im = 0.0
            let status = n60_xover_response(&cascade, sampleRate, hz, &re, &im)
            guard status == N60_XOVER_OK else { throw CoreError.status(status) }
            return (re, im)
        }

        func magnitudeDB(atHz hz: Double) throws -> Double {
            var cascade = raw
            var db = 0.0
            let status = n60_xover_magnitude_db(&cascade, sampleRate, hz, &db)
            guard status == N60_XOVER_OK else { throw CoreError.status(status) }
            return db
        }

        /// Largest pole radius; stable when below 1.
        var maxPoleRadius: Double {
            var cascade = raw
            return n60_xover_max_pole_radius(&cascade)
        }
    }

    static var abiVersion: UInt32 { n60_xover_abi_version() }

    static func design(_ spec: FilterSpec, highPass: Bool, sampleRate: Double) throws -> Cascade {
        var raw = spec.raw
        var out = n60_xover_cascade()
        let status = n60_xover_design(&raw, highPass ? 1 : 0, sampleRate, &out)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return Cascade(out, sampleRate: sampleRate)
    }

    /// Linkwitz transform from a closed-box response (f0, q0) to (fp, qp).
    static func linkwitzTransform(
        f0: Double, q0: Double, fp: Double, qp: Double, sampleRate: Double
    ) throws -> Cascade {
        var out = n60_xover_cascade()
        let status = n60_xover_linkwitz(f0, q0, fp, qp, sampleRate, &out)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return Cascade(out, sampleRate: sampleRate)
    }

    /// True when a Linkwitz-Riley pair of this order needs its high-pass inverted to sum flat.
    static func linkwitzRileyInvertsHighPass(order: Int) -> Bool {
        n60_xover_lr_inverts_hp(UInt32(order)) != 0
    }

    /// Peak-to-peak ripple (dB) of the summed low-pass and high-pass, 20 Hz to min(20 kHz, 0.45 fs).
    static func summedRippleDB(
        lowPass: FilterSpec, highPass: FilterSpec, invertHighPass: Bool, sampleRate: Double
    ) throws -> Double {
        var lp = lowPass.raw, hp = highPass.raw
        var ripple = 0.0
        let status = n60_xover_sum_ripple_db(&lp, &hp, invertHighPass ? 1 : 0, sampleRate, &ripple)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return ripple
    }
}
