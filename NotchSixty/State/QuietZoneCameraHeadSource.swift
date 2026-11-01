import AVFoundation
import Foundation
import Vision

/// E4 S26b: head position from the Mac camera, on-device only.
///
/// Frames are processed in memory by Vision's 3D body pose request; only the head position (a few
/// numbers) is kept. Nothing is stored, logged or sent. Sandbox: needs the camera entitlement and
/// `NSCameraUsageDescription`. Started only when the `e4.head-position-camera` flag is on and the
/// listener has chosen "follow" (the caller decides; this type never reads flags). Control plane
/// only, never an audio thread. Needs a Mac with a camera; bench-checked, not unit-tested.
final class QuietZoneCameraHeadSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Error { case denied, noCamera, cannotConfigure }

    private let placement: QuietZoneCameraPlacement
    private let onPose: @Sendable (QuietZoneHeadPose) -> Void
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "notchsixty.head-camera", qos: .userInitiated)
    private var lastFrameTime = 0.0
    /// About 10 poses per second is plenty for a head that moves slowly.
    private static let minimumInterval = 0.1

    init(placement: QuietZoneCameraPlacement, onPose: @escaping @Sendable (QuietZoneHeadPose) -> Void) {
        self.placement = placement
        self.onPose = onPose
    }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { throw Failure.denied }
        guard let device = AVCaptureDevice.default(for: .video) else { throw Failure.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.cannotConfigure
        }
        session.sessionPreset = .vga640x480
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard now - lastFrameTime >= Self.minimumInterval else { return }
        lastFrameTime = now
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let body = request.results?.first,
              let head = try? body.cameraRelativePosition(.topHead) else { return }
        let t = head.columns.3
        onPose(placement.roomPosition(
            cameraX: Double(t.x), cameraY: Double(t.y), cameraZ: Double(t.z),
            confidence: Double(body.confidence), time: now))
    }
}
