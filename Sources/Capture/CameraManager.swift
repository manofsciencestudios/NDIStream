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

enum CapturePixelFormat: String, CaseIterable, Identifiable {
    case bgra, uyvy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bgra: return "BGRA"
        case .uyvy: return "UYVY"
        }
    }

    var cvPixelFormat: OSType {
        switch self {
        case .bgra: return kCVPixelFormatType_32BGRA
        case .uyvy: return kCVPixelFormatType_422YpCbCr8
        }
    }
}

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "NDIStream.CameraManager.SampleQueue")
    private var currentInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var frameCount = 0
    private var requestedPixelFormat: CapturePixelFormat = .bgra

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        DebugLog.write("CameraManager.init")
        session.beginConfiguration()
        session.sessionPreset = .high
        DebugLog.write("sessionPreset requested=.high canSetHigh=\(session.canSetSessionPreset(.high))")
        applyOutputPixelFormat(.bgra)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
            DebugLog.write("video output added settings=\(String(describing: output.videoSettings))")
        } else {
            DebugLog.write("ERROR cannot add AVCaptureVideoDataOutput")
        }
        session.commitConfiguration()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
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
        let devices = session.devices
        DebugLog.write("availableDevices count=\(devices.count) types=\(types.map { $0.rawValue }.joined(separator: ","))")
        for dev in devices {
            DebugLog.write("device name=\(dev.localizedName) id=\(dev.uniqueID) model=\(dev.modelID) connected=\(dev.isConnected) suspended=\(dev.isSuspended)")
        }
        return devices
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

    func switchToDevice(_ device: AVCaptureDevice,
                        quality: QualityPreset,
                        fps: Int,
                        pixelFormat: CapturePixelFormat) throws {
        DebugLog.write("switchToDevice name=\(device.localizedName) id=\(device.uniqueID) quality=\(quality.rawValue) fps=\(fps) pixelFormat=\(pixelFormat.rawValue)")
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        let target = quality.sessionPreset
        if session.canSetSessionPreset(target) {
            session.sessionPreset = target
            DebugLog.write("sessionPreset set \(target.rawValue)")
        } else {
            session.sessionPreset = .high
            DebugLog.write("sessionPreset fallback .high; target \(target.rawValue) unsupported")
        }
        applyOutputPixelFormat(pixelFormat)

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            currentDevice = device
            DebugLog.write("input added for \(device.localizedName)")
        } else {
            DebugLog.write("ERROR cannot add input for \(device.localizedName)")
            throw NSError(domain: "NDIStream.CameraManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add input for selected device."])
        }

        noteRequestedFPS(fps, device: device)
    }

    func setFPS(_ fps: Int) {
        guard let device = currentDevice else { return }
        noteRequestedFPS(fps, device: device)
    }

    func setPixelFormat(_ pixelFormat: CapturePixelFormat) {
        requestedPixelFormat = pixelFormat
        session.beginConfiguration()
        applyOutputPixelFormat(pixelFormat)
        session.commitConfiguration()
    }

    private func applyOutputPixelFormat(_ pixelFormat: CapturePixelFormat) {
        requestedPixelFormat = pixelFormat
        let chosen = pixelFormat.cvPixelFormat
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: chosen
        ]
        DebugLog.write("video output pixelFormat requested=\(pixelFormat.rawValue) chosen=\(Self.fourCCString(chosen)) settings=\(String(describing: output.videoSettings))")
    }

    private func noteRequestedFPS(_ fps: Int, device: AVCaptureDevice) {
        DebugLog.write("fps request \(fps); leaving camera timing automatic for compatibility. activeFormat=\(device.activeFormat)")
    }

    func start() {
        DebugLog.write("CameraManager.start requested")
        queue.async { [session] in
            if !session.isRunning {
                DebugLog.write("session.startRunning begin inputs=\(session.inputs.count) outputs=\(session.outputs.count)")
                session.startRunning()
                DebugLog.write("session.startRunning returned isRunning=\(session.isRunning)")
            } else {
                DebugLog.write("session.startRunning skipped already running")
            }
        }
    }

    func stop() {
        DebugLog.write("CameraManager.stop requested")
        queue.async { [session] in
            if session.isRunning {
                DebugLog.write("session.stopRunning begin")
                session.stopRunning()
                DebugLog.write("session.stopRunning returned isRunning=\(session.isRunning)")
            }
        }
    }

    static func requestAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DebugLog.write("camera authorization status before=\(status.rawValue)")
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            DebugLog.write("camera authorization prompt result granted=\(granted)")
            return granted
        default:
            DebugLog.write("camera authorization denied/restricted status=\(status.rawValue)")
            return false
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount += 1
        if frameCount == 1 || frameCount % 60 == 0 {
            DebugLog.write("frame \(frameCount) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) pf=\(Self.fourCCString(CVPixelBufferGetPixelFormatType(pb))) bytesPerRow=\(CVPixelBufferGetBytesPerRow(pb)) pts=\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pb, pts)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        DebugLog.write("AVCaptureSessionRuntimeError \(error?.localizedDescription ?? "unknown") code=\(error?.code ?? 0)")
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        DebugLog.write("AVCaptureSessionWasInterrupted userInfo=\(note.userInfo ?? [:])")
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        DebugLog.write("AVCaptureSessionInterruptionEnded")
    }

    private static func fourCCString(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
    }
}
