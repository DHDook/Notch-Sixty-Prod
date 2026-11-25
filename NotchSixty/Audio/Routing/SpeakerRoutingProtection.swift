import Foundation

// E8 S13: per-driver protection on the routing model (behind `e8.active-commissioning`). Pure value logic, no engine
// access: the role-based default limiter, the cumulative boost guard and the power-limit checks. The compiler turns the
// result into PROTECTION and THERMAL_LIMIT stages on the way's output lane.

extension RoutedWay {
    /// The limiter a way with no choice of its own starts with: the role's default ceiling, 1 ms look-ahead.
    static func defaultLimiter(role: DriverRole) -> RoutingLimiter {
        RoutingLimiter(ceilingDB: role.defaultLimiterCeilingDB)
    }
}

extension SpeakerRoutingConfiguration {
    /// E8 S13: puts the role's default limiter on every way that has none, unless the user switched it off. A way with
    /// no role gets the role inferred from its position and corners, the same rule the migration uses.
    func applyingProtectionDefaults() -> SpeakerRoutingConfiguration {
        var next = self
        let inferred = inferredRoles()
        for s in next.speakers.indices {
            for w in next.speakers[s].ways.indices {
                let way = next.speakers[s].ways[w]
                guard way.limiter == nil, way.limiterDeclined != true else { continue }
                let role = way.role ?? inferred[way.id] ?? .fullRange
                next.speakers[s].ways[w].limiter = RoutedWay.defaultLimiter(role: role)
            }
        }
        return next
    }
}

/// The cumulative gain a way adds inside its passband: trim plus driver EQ, on a grid.
enum RoutingBoostGuard {
    static let warnDB = 12.0
    static let errorDB = 18.0
    /// Boost allowed below the lowest safe frequency, in dB (the grid and the float coefficients are good to this).
    static let belowSafeToleranceDB = 0.1

    struct Peak: Equatable {
        var gainDB: Double
        var hz: Double
    }

    /// Magnitude (dB) of one driver EQ section at `hz`. Only the kinds that boost (peaking, low shelf, high shelf and
    /// the constant-Q peaking) carry gain; the filters and the notch only cut or pass, so they count as 0 dB here.
    static func sectionDB(_ s: RoutingEQSection, atHz hz: Double, sampleRate: Double) -> Double {
        guard [0, 1, 2, 8].contains(s.type), s.frequencyHz > 0, s.q > 0, s.gainDB != 0 else { return 0 }
        let a = pow(10, s.gainDB / 40)
        let w0 = 2 * Double.pi * s.frequencyHz / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * s.q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch s.type {
        case 1:
            let t = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + t); b1 = 2 * a * ((a - 1) - (a + 1) * cw); b2 = a * ((a + 1) - (a - 1) * cw - t)
            a0 = (a + 1) + (a - 1) * cw + t; a1 = -2 * ((a - 1) + (a + 1) * cw); a2 = (a + 1) + (a - 1) * cw - t
        case 2:
            let t = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + t); b1 = -2 * a * ((a - 1) + (a + 1) * cw); b2 = a * ((a + 1) + (a - 1) * cw - t)
            a0 = (a + 1) - (a - 1) * cw + t; a1 = 2 * ((a - 1) - (a + 1) * cw); a2 = (a + 1) - (a - 1) * cw - t
        default:
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        }
        let w = 2 * Double.pi * hz / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag = ((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30)).squareRoot()
        return 20 * log10(max(mag, 1e-12))
    }

    /// 1/24-octave grid from 20 Hz to the lower of 20 kHz and 0.45 of the rate.
    static func grid(sampleRate: Double) -> [Double] {
        let top = min(20_000, 0.45 * sampleRate)
        var out: [Double] = []
        var hz = 20.0
        let step = pow(2, 1.0 / 24)
        while hz <= top { out.append(hz); hz *= step }
        return out
    }

    private static func eqDB(_ way: RoutedWay, atHz hz: Double, sampleRate: Double) -> Double {
        way.eq.reduce(0) { $0 + sectionDB($1, atHz: hz, sampleRate: sampleRate) }
    }

    /// The highest trim-plus-EQ gain inside the way's passband (its high-pass corner to its low-pass corner) and where.
    static func passbandPeak(_ way: RoutedWay, sampleRate: Double) -> Peak {
        let low = way.highPass?.cornerHz ?? 0
        let high = way.lowPass?.cornerHz ?? .infinity
        var best = Peak(gainDB: -.infinity, hz: 0)
        for hz in grid(sampleRate: sampleRate) where hz >= low && hz <= high {
            let db = way.trimDB + eqDB(way, atHz: hz, sampleRate: sampleRate)
            if db > best.gainDB { best = Peak(gainDB: db, hz: hz) }
        }
        // A passband narrower than the grid step falls back to its lower edge.
        if best.gainDB == -.infinity {
            let hz = min(max(low, 20), 20_000)
            best = Peak(gainDB: way.trimDB + eqDB(way, atHz: hz, sampleRate: sampleRate), hz: hz)
        }
        return best
    }

    /// The largest EQ boost (trim excluded: it is not frequency selective) below `safeHz`, and where. nil when none.
    static func boostBelowSafe(_ way: RoutedWay, safeHz: Double, sampleRate: Double) -> Peak? {
        var best: Peak?
        for hz in grid(sampleRate: sampleRate) where hz < safeHz {
            let db = eqDB(way, atHz: hz, sampleRate: sampleRate)
            if db > belowSafeToleranceDB, db > (best?.gainDB ?? 0) { best = Peak(gainDB: db, hz: hz) }
        }
        return best
    }
}

extension SpeakerRoutingConfiguration {
    /// E8 S13: boost-guard errors (above +18 dB in the passband, or any boost below the lowest safe frequency).
    func boostErrors(sampleRate: Double) -> [SpeakerRoutingError] {
        var out: [SpeakerRoutingError] = []
        for speaker in speakers {
            for way in speaker.ways {
                let name = way.name.isEmpty ? way.id.uuidString : way.name
                let peak = RoutingBoostGuard.passbandPeak(way, sampleRate: sampleRate)
                if peak.gainDB > RoutingBoostGuard.errorDB {
                    out.append(.boostTooHigh(way: name, gainDB: peak.gainDB, atHz: peak.hz))
                }
                if way.role != nil, let safe = way.effectiveLowestSafeHz,
                   let below = RoutingBoostGuard.boostBelowSafe(way, safeHz: safe, sampleRate: sampleRate) {
                    out.append(.boostBelowSafe(way: name, gainDB: below.gainDB, atHz: below.hz, safeHz: safe))
                }
            }
        }
        return out
    }

    /// E8 S13: boost warnings (above +12 dB in the passband, not yet an error).
    func boostWarnings(sampleRate: Double) -> [SpeakerRoutingWarning] {
        var out: [SpeakerRoutingWarning] = []
        for speaker in speakers {
            for way in speaker.ways {
                let peak = RoutingBoostGuard.passbandPeak(way, sampleRate: sampleRate)
                if peak.gainDB > RoutingBoostGuard.warnDB, peak.gainDB <= RoutingBoostGuard.errorDB {
                    out.append(.boostHigh(way: way.name.isEmpty ? way.id.uuidString : way.name, gainDB: peak.gainDB, atHz: peak.hz))
                }
            }
        }
        return out
    }
}
