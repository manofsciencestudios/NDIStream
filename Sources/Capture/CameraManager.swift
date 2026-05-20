import AVFoundation
import CoreMedia
import Foundation

enum QualityPreset: String, CaseIterable, Identifiable {
    case native, p720, p540
    var id: String { rawValue }
    var label: String {
        switch self {
        case .native: return "Native"
        case .p720: return "720p"
        case .p540: return "540p"
        }
    }
    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .native: return .high
        case .p720: return .hd1280x720
        case .p540: return .iFrame960x540
        }
    }
}

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "NDIStream.CameraManager.SampleQueue")
    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .high
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    static func availableDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    func applyQuality(_ quality: QualityPreset) {
        session.beginConfiguration()
        let target = quality.sessionPreset
        if session.canSetSessionPreset(target) {
            session.sessionPreset = target
        } else {
            session.sessionPreset = .high
        }
        session.commitConfiguration()
    }

    func switchToDevice(_ device: AVCaptureDevice, quality: QualityPreset, fps: Int) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        let target = quality.sessionPreset
        if session.canSetSessionPreset(target) {
            session.sessionPreset = target
        } else {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            currentDevice = device
        } else {
            throw NSError(domain: "NDIStream.CameraManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add input for selected device."])
        }

        applyFPSLocked(fps, device: device)
    }

    func setFPS(_ fps: Int) {
        guard let device = currentDevice else { return }
        applyFPSLocked(fps, device: device)
    }

    private func applyFPSLocked(_ fps: Int, device: AVCaptureDevice) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            // Camera may reject if format doesn't support this rate — leave alone, NDI will reflect actual.
        }
    }

    func start() {
        queue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pb, pts)
    }
}
