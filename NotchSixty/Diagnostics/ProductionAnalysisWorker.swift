import Accelerate
import Foundation

struct ProductionSpectrumBand: Identifiable, Equatable, Sendable {
    let frequencyHz: Double
    let inputDB: Float
    let outputDB: Float
    let inputPeakHoldDB: Float
    let outputPeakHoldDB: Float

    var id: Double { frequencyHz }
}

struct ProductionGoniometerPoint: Equatable, Sendable {
    let x: Float
    let y: Float
}

struct ProductionAnalysisSnapshot: Equatable, Sendable {
    var demandMask: UInt32 = 0
    var sampleRate: Double = 0
    var availableFrames: UInt32 = 0
    var capturedFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var spectrum: [ProductionSpectrumBand] = []
    var phaseCorrelation: Float = 0
    var phaseCorrelationValid = false
    var goniometer: [ProductionGoniometerPoint] = []

    static let empty = ProductionAnalysisSnapshot()
}

enum ProductionAnalysisMath {
    static let spectrumFloorDB: Float = -80
    static let spectrumCeilingDB: Float = 0

    static func fftSize(sampleRate: Double) -> Int {
        if sampleRate > 288_000 { return 32_768 }
        if sampleRate > 144_000 { return 16_384 }
        if sampleRate > 72_000 { return 8_192 }
        return 4_096
    }

    static func phaseCorrelation(left: [Float], right: [Float], count: Int) -> Float? {
        let usable = min(count, min(left.count, right.count))
        guard usable > 0 else { return nil }

        var cross = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        for index in 0..<usable {
            let l = Double(left[index])
            let r = Double(right[index])
            cross += l * r
            leftEnergy += l * l
            rightEnergy += r * r
        }

        let denominator = sqrt(leftEnergy * rightEnergy)
        guard denominator > 1.0e-12 else { return nil }
        return Float(min(max(cross / denominator, -1), 1))
    }

    static func goniometerPoint(left: Float, right: Float) -> ProductionGoniometerPoint {
        let rotation = Float(0.7071067811865476)
        return ProductionGoniometerPoint(
            x: (left - right) * rotation,
            y: (left + right) * rotation
        )
    }
}

/// Independently authored production RTA. It intentionally analyzes copied
/// bridge samples off the realtime callback. The transform setup and all work
/// buffers are retained across updates so steady-state analysis does not rebuild
/// FFT state or allocate large scratch vectors.
final class ProductionSpectrumAnalyzer {
    private static let bandCount = 96
    private static let peakHoldUpdates = 20       // ~1 s at the worker's 20 Hz cadence.
    private static let peakDecayDBPerUpdate: Float = 0.75

    private var setup: vDSP_DFT_Setup?
    private var configuredSize = 0
    private var window: [Float] = []
    private var windowSum: Float = 1
    private var zeroImaginary: [Float] = []
    private var inputWindowed: [Float] = []
    private var outputWindowed: [Float] = []
    private var inputReal: [Float] = []
    private var inputImaginary: [Float] = []
    private var outputReal: [Float] = []
    private var outputImaginary: [Float] = []
    private var inputPeakHold: [Float] = []
    private var outputPeakHold: [Float] = []
    private var inputPeakAge: [Int] = []
    private var outputPeakAge: [Int] = []
    private var resetPeakHoldRequested = true

    deinit {
        if let setup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    func requestPeakHoldReset() {
        resetPeakHoldRequested = true
    }

    func analyze(
        input: [Float],
        output: [Float],
        count: Int,
        sampleRate: Double
    ) -> [ProductionSpectrumBand] {
        let transformSize = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
        guard count >= transformSize,
              input.count >= transformSize,
              output.count >= transformSize,
              sampleRate.isFinite,
              sampleRate > 0,
              configureIfNeeded(size: transformSize) else {
            return []
        }

        let sourceOffset = count - transformSize
        for index in 0..<transformSize {
            let windowValue = window[index]
            inputWindowed[index] = input[sourceOffset + index] * windowValue
            outputWindowed[index] = output[sourceOffset + index] * windowValue
        }

        execute(inputWindowed, outputReal: &inputReal, outputImaginary: &inputImaginary)
        execute(outputWindowed, outputReal: &outputReal, outputImaginary: &outputImaginary)

        let nyquist = sampleRate * 0.5
        let maximumFrequency = min(20_000.0, nyquist * 0.98)
        guard maximumFrequency > 20 else { return [] }
        let ratio = maximumFrequency / 20.0
        let amplitudeScale = 2.0 / max(Double(windowSum), Double.leastNonzeroMagnitude)

        var currentInput = [Float](repeating: ProductionAnalysisMath.spectrumFloorDB, count: Self.bandCount)
        var currentOutput = currentInput
        var frequencies = [Double](repeating: 20, count: Self.bandCount)

        for band in 0..<Self.bandCount {
            let lowerFraction = Double(band) / Double(Self.bandCount)
            let upperFraction = Double(band + 1) / Double(Self.bandCount)
            let lowerHz = 20.0 * pow(ratio, lowerFraction)
            let upperHz = 20.0 * pow(ratio, upperFraction)
            frequencies[band] = sqrt(lowerHz * upperHz)

            var firstBin = max(1, Int(floor(lowerHz * Double(transformSize) / sampleRate)))
            var lastBin = min(transformSize / 2, Int(ceil(upperHz * Double(transformSize) / sampleRate)))
            if lastBin < firstBin {
                let nearest = min(
                    transformSize / 2,
                    max(1, Int(round(frequencies[band] * Double(transformSize) / sampleRate)))
                )
                firstBin = nearest
                lastBin = nearest
            }

            var inputMagnitude = 0.0
            var outputMagnitude = 0.0
            if firstBin <= lastBin {
                for bin in firstBin...lastBin {
                    let inReal = Double(inputReal[bin])
                    let inImag = Double(inputImaginary[bin])
                    let outReal = Double(outputReal[bin])
                    let outImag = Double(outputImaginary[bin])
                    inputMagnitude = max(inputMagnitude, hypot(inReal, inImag))
                    outputMagnitude = max(outputMagnitude, hypot(outReal, outImag))
                }
            }

            currentInput[band] = decibels(amplitude: inputMagnitude * amplitudeScale)
            currentOutput[band] = decibels(amplitude: outputMagnitude * amplitudeScale)
        }

        updatePeakHold(current: currentInput, hold: &inputPeakHold, age: &inputPeakAge)
        updatePeakHold(current: currentOutput, hold: &outputPeakHold, age: &outputPeakAge)
        resetPeakHoldRequested = false

        return (0..<Self.bandCount).map { index in
            ProductionSpectrumBand(
                frequencyHz: frequencies[index],
                inputDB: currentInput[index],
                outputDB: currentOutput[index],
                inputPeakHoldDB: inputPeakHold[index],
                outputPeakHoldDB: outputPeakHold[index]
            )
        }
    }

    private func configureIfNeeded(size: Int) -> Bool {
        if configuredSize == size, setup != nil { return true }

        if let setup {
            vDSP_DFT_DestroySetup(setup)
            self.setup = nil
        }
        guard let newSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            configuredSize = 0
            return false
        }

        setup = newSetup
        configuredSize = size
        window = [Float](repeating: 0, count: size)
        zeroImaginary = [Float](repeating: 0, count: size)
        inputWindowed = [Float](repeating: 0, count: size)
        outputWindowed = [Float](repeating: 0, count: size)
        inputReal = [Float](repeating: 0, count: size)
        inputImaginary = [Float](repeating: 0, count: size)
        outputReal = [Float](repeating: 0, count: size)
        outputImaginary = [Float](repeating: 0, count: size)

        if size == 1 {
            window[0] = 1
        } else {
            let denominator = Float(size - 1)
            for index in 0..<size {
                window[index] = 0.5 - 0.5 * cos(2 * .pi * Float(index) / denominator)
            }
        }
        windowSum = window.reduce(0, +)

        inputPeakHold = [Float](repeating: ProductionAnalysisMath.spectrumFloorDB, count: Self.bandCount)
        outputPeakHold = inputPeakHold
        inputPeakAge = [Int](repeating: 0, count: Self.bandCount)
        outputPeakAge = inputPeakAge
        resetPeakHoldRequested = true
        return true
    }

    private func execute(
        _ source: [Float],
        outputReal: inout [Float],
        outputImaginary: inout [Float]
    ) {
        guard let setup else { return }
        source.withUnsafeBufferPointer { sourceBuffer in
            zeroImaginary.withUnsafeBufferPointer { imaginaryBuffer in
                outputReal.withUnsafeMutableBufferPointer { realBuffer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        vDSP_DFT_Execute(
                            setup,
                            sourceBuffer.baseAddress!,
                            imaginaryBuffer.baseAddress!,
                            realBuffer.baseAddress!,
                            outputImaginaryBuffer.baseAddress!
                        )
                    }
                }
            }
        }
    }

    private func decibels(amplitude: Double) -> Float {
        guard amplitude.isFinite, amplitude > 0 else {
            return ProductionAnalysisMath.spectrumFloorDB
        }
        let db = Float(20.0 * log10(amplitude))
        return min(
            ProductionAnalysisMath.spectrumCeilingDB,
            max(ProductionAnalysisMath.spectrumFloorDB, db)
        )
    }

    private func updatePeakHold(current: [Float], hold: inout [Float], age: inout [Int]) {
        guard hold.count == current.count, age.count == current.count else {
            hold = current
            age = [Int](repeating: 0, count: current.count)
            return
        }
        if resetPeakHoldRequested {
            hold = current
            age = [Int](repeating: 0, count: current.count)
            return
        }

        for index in current.indices {
            if current[index] >= hold[index] {
                hold[index] = current[index]
                age[index] = 0
            } else if age[index] < Self.peakHoldUpdates {
                age[index] += 1
            } else {
                hold[index] = max(current[index], hold[index] - Self.peakDecayDBPerUpdate)
            }
        }
    }
}

/// Owns analysis state for one transport session. The worker's serial queue is
/// the sole reader of the bridge analysis ring, which preserves the SPSC
/// contract. SwiftUI receives only compact immutable snapshots.
final class ProductionAnalysisWorker: @unchecked Sendable {
    private static let historyCapacity = 32_768
    private static let drainCapacity = 8_192
    private static let correlationCapacity = 8_192
    private static let goniometerHistoryFrames = 4_096
    private static let goniometerPointLimit = 384

    private let bridge: OpaquePointer
    private let queue = DispatchQueue(
        label: "com.dhdook.NotchSixty.production-analysis",
        qos: .userInitiated
    )
    private let snapshotLock = NSLock()

    private var timer: DispatchSourceTimer?
    private var demandMask: UInt32 = 0
    private var sampleRate: Double = 0
    private var stopped = false

    private var drainBuffer = [N60AnalysisFrame](
        repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
        count: ProductionAnalysisWorker.drainCapacity
    )
    private var inputHistory = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var outputHistory = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var outputLeftHistory = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var outputRightHistory = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var historyWriteIndex = 0
    private var historyCount = 0

    private var latestInput = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var latestOutput = [Float](repeating: 0, count: ProductionAnalysisWorker.historyCapacity)
    private var latestLeft = [Float](repeating: 0, count: ProductionAnalysisWorker.correlationCapacity)
    private var latestRight = [Float](repeating: 0, count: ProductionAnalysisWorker.correlationCapacity)

    private let spectrumAnalyzer = ProductionSpectrumAnalyzer()
    private var publishedSnapshot = ProductionAnalysisSnapshot.empty

    init(bridge: OpaquePointer) {
        self.bridge = bridge
    }

    func setDemand(_ requestedMask: UInt32, sampleRate: Double) {
        let sanitized = requestedMask & UInt32(N60_ANALYSIS_DEMAND_ALL)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let changed = self.demandMask != sanitized || self.sampleRate != sampleRate
            self.demandMask = sanitized
            self.sampleRate = sampleRate
            if changed {
                self.clearHistory()
                self.spectrumAnalyzer.requestPeakHoldReset()
            }
            self.updateTimer()
            if sanitized == 0 {
                self.publish(.empty)
            }
        }
    }

    func snapshot() -> ProductionAnalysisSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return publishedSnapshot
    }

    func resetSpectrumPeakHold() {
        queue.async { [weak self] in
            self?.spectrumAnalyzer.requestPeakHoldReset()
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            demandMask = 0
        }
    }

    private func updateTimer() {
        if demandMask == 0 {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(50),
            leeway: .milliseconds(5)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        guard !stopped, demandMask != 0, sampleRate > 0 else { return }
        drainCapturedFrames()

        let capture = N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(bridge)
        var next = ProductionAnalysisSnapshot(
            demandMask: demandMask,
            sampleRate: sampleRate,
            availableFrames: capture.availableFrames,
            capturedFrames: capture.capturedFrames,
            droppedFrames: capture.droppedFrames,
            spectrum: [],
            phaseCorrelation: 0,
            phaseCorrelationValid: false,
            goniometer: []
        )

        if (demandMask & UInt32(N60_ANALYSIS_DEMAND_SPECTRUM)) != 0 {
            let transformSize = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
            if historyCount >= transformSize {
                copyLatestMono(count: transformSize)
                next.spectrum = spectrumAnalyzer.analyze(
                    input: latestInput,
                    output: latestOutput,
                    count: transformSize,
                    sampleRate: sampleRate
                )
            }
        }

        if (demandMask & UInt32(N60_ANALYSIS_DEMAND_STEREO)) != 0 {
            let requestedCorrelationFrames = Int(min(max(sampleRate * 0.1, 1_024), Double(Self.correlationCapacity)))
            let correlationFrames = min(historyCount, requestedCorrelationFrames)
            if correlationFrames > 0 {
                copyLatestStereo(count: correlationFrames)
                if let correlation = ProductionAnalysisMath.phaseCorrelation(
                    left: latestLeft,
                    right: latestRight,
                    count: correlationFrames
                ) {
                    next.phaseCorrelation = correlation
                    next.phaseCorrelationValid = true
                }
            }
            next.goniometer = makeGoniometerPoints()
        }

        publish(next)
    }

    private func drainCapturedFrames() {
        for _ in 0..<16 {
            let readCount = drainBuffer.withUnsafeMutableBufferPointer { buffer in
                Int(N60RealtimeAudioBridgeReadAnalysisFrames(
                    bridge,
                    buffer.baseAddress!,
                    UInt32(buffer.count)
                ))
            }
            if readCount == 0 { break }

            for index in 0..<readCount {
                let frame = drainBuffer[index]
                inputHistory[historyWriteIndex] = (frame.inputLeft + frame.inputRight) * 0.5
                outputHistory[historyWriteIndex] = (frame.outputLeft + frame.outputRight) * 0.5
                outputLeftHistory[historyWriteIndex] = frame.outputLeft
                outputRightHistory[historyWriteIndex] = frame.outputRight
                historyWriteIndex += 1
                if historyWriteIndex == Self.historyCapacity { historyWriteIndex = 0 }
                if historyCount < Self.historyCapacity { historyCount += 1 }
            }

            if readCount < drainBuffer.count { break }
        }
    }

    private func clearHistory() {
        historyWriteIndex = 0
        historyCount = 0
    }

    private func copyLatestMono(count: Int) {
        let usable = min(count, min(historyCount, Self.historyCapacity))
        let start = (historyWriteIndex - usable + Self.historyCapacity) % Self.historyCapacity
        for index in 0..<usable {
            let sourceIndex = (start + index) % Self.historyCapacity
            latestInput[index] = inputHistory[sourceIndex]
            latestOutput[index] = outputHistory[sourceIndex]
        }
    }

    private func copyLatestStereo(count: Int) {
        let usable = min(count, min(historyCount, Self.correlationCapacity))
        let start = (historyWriteIndex - usable + Self.historyCapacity) % Self.historyCapacity
        for index in 0..<usable {
            let sourceIndex = (start + index) % Self.historyCapacity
            latestLeft[index] = outputLeftHistory[sourceIndex]
            latestRight[index] = outputRightHistory[sourceIndex]
        }
    }

    private func makeGoniometerPoints() -> [ProductionGoniometerPoint] {
        let usable = min(historyCount, Self.goniometerHistoryFrames)
        guard usable > 0 else { return [] }
        let pointCount = min(usable, Self.goniometerPointLimit)
        let stride = max(usable / pointCount, 1)
        let start = (historyWriteIndex - usable + Self.historyCapacity) % Self.historyCapacity

        var points: [ProductionGoniometerPoint] = []
        points.reserveCapacity(pointCount)
        var offset = 0
        while offset < usable, points.count < pointCount {
            let sourceIndex = (start + offset) % Self.historyCapacity
            points.append(ProductionAnalysisMath.goniometerPoint(
                left: outputLeftHistory[sourceIndex],
                right: outputRightHistory[sourceIndex]
            ))
            offset += stride
        }
        return points
    }

    private func publish(_ snapshot: ProductionAnalysisSnapshot) {
        snapshotLock.lock()
        publishedSnapshot = snapshot
        snapshotLock.unlock()
    }
}
