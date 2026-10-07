import Foundation

struct SOFAVector3: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = SOFAVector3(x: 0, y: 0, z: 0)

    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        Self(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    func dot(_ other: Self) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Self) -> Self {
        Self(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    func normalized() throws -> Self {
        let length = magnitude
        guard isFinite, length.isFinite, length > 1.0e-12 else {
            throw SOFAImportError.invalidCoordinateFrame
        }
        return self * (1.0 / length)
    }
}

struct SOFAListenerFrame: Equatable, Sendable {
    var position: SOFAVector3
    var forward: SOFAVector3
    var right: SOFAVector3
    var up: SOFAVector3

    init(
        position: SOFAVector3,
        view: SOFAVector3,
        up proposedUp: SOFAVector3
    ) throws {
        guard position.isFinite else {
            throw SOFAImportError.invalidCoordinateFrame
        }
        let forward = try view.normalized()
        let right = try forward.cross(proposedUp).normalized()
        let up = try right.cross(forward).normalized()

        // Reject nearly parallel view/up declarations rather than creating an
        // unstable coordinate frame.
        guard abs(forward.dot(up)) < 1.0e-6,
              abs(forward.dot(right)) < 1.0e-6,
              abs(right.dot(up)) < 1.0e-6 else {
            throw SOFAImportError.invalidCoordinateFrame
        }

        self.position = position
        self.forward = forward
        self.right = right
        self.up = up
    }

    func sphericalPosition(
        of worldPosition: SOFAVector3
    ) throws -> SOFASphericalPosition {
        let relative = worldPosition - position
        let distance = relative.magnitude
        guard relative.isFinite,
              distance.isFinite,
              distance > 1.0e-9 else {
            throw SOFAImportError.invalidSourcePosition
        }

        let front = relative.dot(forward)
        let rightward = relative.dot(right)
        let upward = relative.dot(up)
        let horizontal = hypot(front, rightward)
        let azimuth =
            atan2(rightward, front) * 180.0 / Double.pi
        let elevation =
            atan2(upward, horizontal) * 180.0 / Double.pi

        guard azimuth.isFinite,
              elevation.isFinite else {
            throw SOFAImportError.invalidSourcePosition
        }
        return SOFASphericalPosition(
            azimuthDegrees: azimuth,
            elevationDegrees: elevation,
            distanceMeters: distance
        )
    }
}

struct SOFASphericalPosition: Equatable, Sendable {
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var distanceMeters: Double
}

struct SOFAImportProvenance: Codable, Equatable, Sendable {
    var sourceFormat = "AES69/SOFA"
    var sourceFileName: String
    var sofaConvention: String?
    var sofaConventionVersion: String?
    var sofaVersion: String?
    var dataType: String?
    var roomType: String?
    var sourceLicense: String?
    var title: String?
    var measurementCount: Int
    var receiverCount: Int
    var emitterCount: Int
    var sourceTapCount: Int
    var delayBakeCommonOffsetSamples: Double
    var fractionalDelayKernelRadius: Int
}

struct SOFAFIRDataset: Sendable {
    var sampleRate: Double
    var measurementCount: Int
    var receiverCount: Int
    var emitterCount: Int
    var tapCount: Int
    var emitterDependent: Bool
    var provenance: SOFAImportProvenance
    var listenerFrames: [SOFAListenerFrame]
    var sourcePositions: [SOFAVector3]
    var emitterPositions: [SOFAVector3]
    var delaysSamples: [Double]
    var impulseResponses: [Float]

    var signalEmitterCount: Int {
        emitterDependent ? emitterCount : 1
    }

    func validate() throws {
        guard sampleRate.isFinite, sampleRate > 0,
              measurementCount > 0,
              receiverCount > 0,
              emitterCount > 0,
              tapCount > 0,
              listenerFrames.count == measurementCount,
              sourcePositions.count == measurementCount,
              emitterPositions.count
                == measurementCount * emitterCount else {
            throw SOFAImportError.invalidDataset
        }

        let signalCount =
            measurementCount * receiverCount * signalEmitterCount
        guard delaysSamples.count == signalCount,
              impulseResponses.count == signalCount * tapCount,
              delaysSamples.allSatisfy(\.isFinite),
              impulseResponses.allSatisfy(\.isFinite) else {
            throw SOFAImportError.invalidDataset
        }
    }

    func delaySamples(
        measurement: Int,
        receiver: Int,
        emitter: Int
    ) -> Double {
        delaysSamples[
            signalIndex(
                measurement: measurement,
                receiver: receiver,
                emitter: emitter
            )
        ]
    }

    func impulseResponse(
        measurement: Int,
        receiver: Int,
        emitter: Int
    ) -> ArraySlice<Float> {
        let signal = signalIndex(
            measurement: measurement,
            receiver: receiver,
            emitter: emitter
        )
        let start = signal * tapCount
        return impulseResponses[start..<(start + tapCount)]
    }

    func effectiveEmitterWorldPosition(
        measurement: Int,
        emitter: Int
    ) -> SOFAVector3 {
        sourcePositions[measurement]
            + emitterPositions[
                measurement * emitterCount + emitter
            ]
    }

    private func signalIndex(
        measurement: Int,
        receiver: Int,
        emitter: Int
    ) -> Int {
        precondition(
            measurement >= 0 && measurement < measurementCount
                && receiver >= 0 && receiver < receiverCount
                && emitter >= 0 && emitter < signalEmitterCount
        )
        return (
            measurement * receiverCount + receiver
        ) * signalEmitterCount + emitter
    }
}

enum SOFAImportError: Error, Equatable, LocalizedError {
    case nativeReader(Int, String)
    case invalidDataset
    case unsupportedReceiverCount(Int)
    case unsupportedEmitterCount(Int)
    case invalidCoordinateFrame
    case invalidSourcePosition
    case invalidDelay(Double)
    case normalizedTapCountTooLarge(Int)
    case bridgeReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .nativeReader(_, let description):
            return description
        case .invalidDataset:
            return "The SOFA FIR dataset is internally inconsistent."
        case .unsupportedReceiverCount(let count):
            return "Binaural SOFA import requires exactly two receivers; the dataset declares \(count)."
        case .unsupportedEmitterCount(let count):
            return "This binaural profile requires one emitter per measurement; the SOFA dataset declares \(count). The generic SOFA dataset remains representable for later multichannel processing."
        case .invalidCoordinateFrame:
            return "The SOFA listener view/up vectors do not define a stable listener coordinate frame."
        case .invalidSourcePosition:
            return "The SOFA source/emitter geometry cannot be reduced to a finite non-zero listener-relative position."
        case .invalidDelay(let delay):
            return "The SOFA dataset declares an unusable Data.Delay value of \(delay) samples."
        case .normalizedTapCountTooLarge(let count):
            return "Baking SOFA delay metadata would require \(count) FIR taps, exceeding the realtime binaural limit."
        case .bridgeReadFailed(let field):
            return "The native SOFA reader could not copy \(field) from the validated file."
        }
    }
}

struct NativeSOFAImporter: Sendable {
    func load(from url: URL) throws -> SOFAFIRDataset {
        var status = N60SOFAStatusOK
        let document: OpaquePointer? =
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return nil }
                return N60SOFADocumentOpen(path, &status)
            }
        guard let document else {
            let description = String(
                cString: N60SOFAStatusDescription(status)
            )
            throw SOFAImportError.nativeReader(
                Int(status.rawValue),
                description
            )
        }
        defer { N60SOFADocumentDestroy(document) }

        var metadata = N60SOFAMetadata()
        guard N60SOFADocumentGetMetadata(
            document,
            &metadata
        ) else {
            throw SOFAImportError.bridgeReadFailed("metadata")
        }

        let measurementCount = Int(metadata.measurementCount)
        let receiverCount = Int(metadata.receiverCount)
        let emitterCount = Int(metadata.emitterCount)
        let tapCount = Int(metadata.tapCount)
        let signalEmitterCount =
            metadata.emitterDependent ? emitterCount : 1

        func attribute(_ name: String) -> String? {
            name.withCString { pointer in
                guard let value = N60SOFADocumentGetAttribute(
                    document,
                    pointer
                ) else {
                    return nil
                }
                let text = String(cString: value)
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                return text.isEmpty ? nil : text
            }
        }

        func vector(
            _ field: String,
            _ body: (UnsafeMutablePointer<Double>) -> Bool
        ) throws -> SOFAVector3 {
            var values = [Double](repeating: 0, count: 3)
            let copied = values.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return false }
                return body(base)
            }
            guard copied,
                  values.allSatisfy(\.isFinite) else {
                throw SOFAImportError.bridgeReadFailed(field)
            }
            return SOFAVector3(
                x: values[0],
                y: values[1],
                z: values[2]
            )
        }

        var listeners: [SOFAListenerFrame] = []
        var sources: [SOFAVector3] = []
        var emitters: [SOFAVector3] = []
        listeners.reserveCapacity(measurementCount)
        sources.reserveCapacity(measurementCount)
        emitters.reserveCapacity(
            measurementCount * emitterCount
        )

        for measurement in 0..<measurementCount {
            let m = UInt32(measurement)
            let listener = try vector("ListenerPosition") {
                N60SOFADocumentCopyListenerPosition(
                    document, m, $0
                )
            }
            let view = try vector("ListenerView") {
                N60SOFADocumentCopyListenerView(
                    document, m, $0
                )
            }
            let up = try vector("ListenerUp") {
                N60SOFADocumentCopyListenerUp(
                    document, m, $0
                )
            }
            listeners.append(try SOFAListenerFrame(
                position: listener,
                view: view,
                up: up
            ))
            sources.append(try vector("SourcePosition") {
                N60SOFADocumentCopySourcePosition(
                    document, m, $0
                )
            })

            for emitter in 0..<emitterCount {
                let e = UInt32(emitter)
                emitters.append(try vector("EmitterPosition") {
                    N60SOFADocumentCopyEmitterPosition(
                        document, m, e, $0
                    )
                })
            }
        }

        let signalCount =
            measurementCount * receiverCount * signalEmitterCount
        var delays = [Double]()
        delays.reserveCapacity(signalCount)
        var impulseResponses = [Float]()
        impulseResponses.reserveCapacity(signalCount * tapCount)

        for measurement in 0..<measurementCount {
            for receiver in 0..<receiverCount {
                for emitter in 0..<signalEmitterCount {
                    var delay = 0.0
                    guard N60SOFADocumentGetDelaySamples(
                        document,
                        UInt32(measurement),
                        UInt32(receiver),
                        UInt32(emitter),
                        &delay
                    ), delay.isFinite else {
                        throw SOFAImportError.bridgeReadFailed(
                            "Data.Delay"
                        )
                    }
                    delays.append(delay)

                    var response = [Float](
                        repeating: 0,
                        count: tapCount
                    )
                    let copied = response.withUnsafeMutableBufferPointer {
                        guard let base = $0.baseAddress else {
                            return false
                        }
                        return N60SOFADocumentCopyImpulseResponse(
                            document,
                            UInt32(measurement),
                            UInt32(receiver),
                            UInt32(emitter),
                            base,
                            UInt32(tapCount)
                        )
                    }
                    guard copied,
                          response.allSatisfy(\.isFinite) else {
                        throw SOFAImportError.bridgeReadFailed(
                            "Data.IR"
                        )
                    }
                    impulseResponses.append(contentsOf: response)
                }
            }
        }

        let provenance = SOFAImportProvenance(
            sourceFileName: url.lastPathComponent,
            sofaConvention: attribute("SOFAConventions"),
            sofaConventionVersion:
                attribute("SOFAConventionsVersion"),
            sofaVersion: attribute("Version"),
            dataType: attribute("DataType"),
            roomType: attribute("RoomType"),
            sourceLicense: attribute("License"),
            title: attribute("Title"),
            measurementCount: measurementCount,
            receiverCount: receiverCount,
            emitterCount: emitterCount,
            sourceTapCount: tapCount,
            delayBakeCommonOffsetSamples: 0,
            fractionalDelayKernelRadius: 0
        )

        let dataset = SOFAFIRDataset(
            sampleRate: metadata.sampleRate,
            measurementCount: measurementCount,
            receiverCount: receiverCount,
            emitterCount: emitterCount,
            tapCount: tapCount,
            emitterDependent: metadata.emitterDependent,
            provenance: provenance,
            listenerFrames: listeners,
            sourcePositions: sources,
            emitterPositions: emitters,
            delaysSamples: delays,
            impulseResponses: impulseResponses
        )
        try dataset.validate()
        return dataset
    }
}

struct SOFABinauralAssetAdapter: Sendable {
    static let fractionalDelayKernelRadius = 8
    static let integerTolerance = 1.0e-9

    func makeAsset(
        from dataset: SOFAFIRDataset,
        sourceURL: URL
    ) throws -> BinauralProfileAsset {
        try dataset.validate()
        guard dataset.receiverCount == 2 else {
            throw SOFAImportError.unsupportedReceiverCount(
                dataset.receiverCount
            )
        }
        guard dataset.signalEmitterCount == 1 else {
            throw SOFAImportError.unsupportedEmitterCount(
                dataset.signalEmitterCount
            )
        }

        guard let minimumDelay = dataset.delaysSamples.min(),
              let maximumDelay = dataset.delaysSamples.max(),
              minimumDelay.isFinite,
              maximumDelay.isFinite else {
            throw SOFAImportError.invalidDataset
        }

        // Preserve relative delay even when a source file uses a negative
        // reference by adding one common offset to every receiver response.
        let commonOffset = max(0, -minimumDelay)
        let effectiveMaximum = maximumDelay + commonOffset
        guard effectiveMaximum.isFinite,
              effectiveMaximum >= 0 else {
            throw SOFAImportError.invalidDelay(effectiveMaximum)
        }

        let hasFractionalDelay = dataset.delaysSamples.contains {
            let shifted = $0 + commonOffset
            return abs(shifted - shifted.rounded())
                > Self.integerTolerance
        }
        let radius = hasFractionalDelay
            ? Self.fractionalDelayKernelRadius
            : 0
        let commonLead = radius > 0 ? radius - 1 : 0
        let tailGuard = radius > 0 ? radius : 0
        let normalizedTapCount =
            dataset.tapCount
            + Int(ceil(effectiveMaximum))
            + commonLead
            + tailGuard

        guard normalizedTapCount > 0,
              normalizedTapCount
                <= Int(N60_BINAURAL_MAX_TAPS) else {
            throw SOFAImportError.normalizedTapCountTooLarge(
                normalizedTapCount
            )
        }

        var measurements: [BinauralMeasurement] = []
        measurements.reserveCapacity(dataset.measurementCount)

        for measurement in 0..<dataset.measurementCount {
            let emitterWorld = dataset
                .effectiveEmitterWorldPosition(
                    measurement: measurement,
                    emitter: 0
                )
            let spherical = try dataset
                .listenerFrames[measurement]
                .sphericalPosition(of: emitterWorld)

            let left = try bakeDelay(
                Array(dataset.impulseResponse(
                    measurement: measurement,
                    receiver: 0,
                    emitter: 0
                )),
                delaySamples:
                    dataset.delaySamples(
                        measurement: measurement,
                        receiver: 0,
                        emitter: 0
                    ) + commonOffset,
                outputCount: normalizedTapCount,
                commonLead: commonLead,
                radius: radius
            )
            let right = try bakeDelay(
                Array(dataset.impulseResponse(
                    measurement: measurement,
                    receiver: 1,
                    emitter: 0
                )),
                delaySamples:
                    dataset.delaySamples(
                        measurement: measurement,
                        receiver: 1,
                        emitter: 0
                    ) + commonOffset,
                outputCount: normalizedTapCount,
                commonLead: commonLead,
                radius: radius
            )

            measurements.append(BinauralMeasurement(
                azimuthDegrees: spherical.azimuthDegrees,
                elevationDegrees: spherical.elevationDegrees,
                distanceMeters: spherical.distanceMeters,
                leftIR: left,
                rightIR: right
            ))
        }

        var provenance = dataset.provenance
        provenance.delayBakeCommonOffsetSamples = commonOffset
        provenance.fractionalDelayKernelRadius = radius

        let title = provenance.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName =
            (title?.isEmpty == false ? title : nil)
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let roomType = provenance.roomType?.lowercased()
        let kind: BinauralAssetKind =
            roomType?.contains("free field") == false
            ? .brir
            : .hrtf

        var asset = BinauralProfileAsset(
            displayName: displayName,
            originalSourceName: sourceURL.lastPathComponent,
            sampleRate: dataset.sampleRate,
            tapCount: normalizedTapCount,
            kind: kind,
            measurements: measurements
        )
        asset.importProvenance = provenance
        try asset.validate()
        return asset
    }

    private func bakeDelay(
        _ input: [Float],
        delaySamples: Double,
        outputCount: Int,
        commonLead: Int,
        radius: Int
    ) throws -> [Float] {
        guard delaySamples.isFinite,
              delaySamples >= 0 else {
            throw SOFAImportError.invalidDelay(delaySamples)
        }

        var output = [Double](
            repeating: 0,
            count: outputCount
        )
        let rounded = delaySamples.rounded()
        if abs(delaySamples - rounded) <= Self.integerTolerance {
            let shift = Int(rounded) + commonLead
            guard shift >= 0,
                  shift + input.count <= output.count else {
                throw SOFAImportError.normalizedTapCountTooLarge(
                    outputCount
                )
            }
            for index in input.indices {
                output[shift + index] = Double(input[index])
            }
        } else {
            let integer = Int(floor(delaySamples))
            let fraction = delaySamples - Double(integer)
            let tapOffsets = Array((-(radius - 1))...radius)
            var weights = tapOffsets.map {
                Self.lanczos(
                    Double($0) - fraction,
                    radius: radius
                )
            }
            let sum = weights.reduce(0, +)
            guard sum.isFinite, abs(sum) > 1.0e-12 else {
                throw SOFAImportError.invalidDelay(delaySamples)
            }
            for index in weights.indices {
                weights[index] /= sum
            }

            for inputIndex in input.indices {
                let sample = Double(input[inputIndex])
                for (weightIndex, offset) in tapOffsets.enumerated() {
                    let outputIndex =
                        inputIndex + integer + offset + commonLead
                    guard outputIndex >= 0,
                          outputIndex < output.count else {
                        continue
                    }
                    output[outputIndex] +=
                        sample * weights[weightIndex]
                }
            }
        }

        guard output.allSatisfy(\.isFinite) else {
            throw SOFAImportError.invalidDataset
        }
        return output.map(Float.init)
    }

    private static func lanczos(
        _ x: Double,
        radius: Int
    ) -> Double {
        let a = Double(radius)
        let magnitude = abs(x)
        if magnitude < 1.0e-12 { return 1 }
        if magnitude >= a { return 0 }
        return sinc(x) * sinc(x / a)
    }

    private static func sinc(_ x: Double) -> Double {
        if abs(x) < 1.0e-12 { return 1 }
        let angle = Double.pi * x
        return sin(angle) / angle
    }
}
