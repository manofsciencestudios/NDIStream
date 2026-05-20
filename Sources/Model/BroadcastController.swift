import AVFoundation
import Combine
import CoreVideo
import Foundation

@MainActor
final class BroadcastController: ObservableObject {
    enum Status: Equatable {
        case idle
        case live(width: Int, height: Int, fps: Int)
        case error(String)
    }

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String {
        didSet {
            UserDefaults.standard.set(selectedCameraID, forKey: "lastCameraID")
            if isBroadcasting, let dev = currentDevice() {
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS, pixelFormat: pixelFormat) }
                catch { status = .error(error.localizedDescription) }
            }
        }
    }
    @Published var sourceName: String {
        didSet {
            UserDefaults.standard.set(sourceName, forKey: "lastSourceName")
            if isBroadcasting { restartSender() }
        }
    }
    @Published var targetFPS: Int {
        didSet {
            UserDefaults.standard.set(targetFPS, forKey: "targetFPS")
            if isBroadcasting { cameraManager.setFPS(targetFPS) }
        }
    }
    @Published var quality: QualityPreset {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "quality")
            if isBroadcasting, let dev = currentDevice() {
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS, pixelFormat: pixelFormat) }
                catch { status = .error(error.localizedDescription) }
            }
        }
    }
    @Published var pixelFormat: CapturePixelFormat {
        didSet {
            UserDefaults.standard.set(pixelFormat.rawValue, forKey: "pixelFormat")
            cameraManager.setPixelFormat(pixelFormat)
        }
    }
    @Published var smoothPacing: Bool {
        didSet {
            UserDefaults.standard.set(smoothPacing, forKey: "smoothPacing")
            if isBroadcasting { restartSender() }
        }
    }
    @Published var isBroadcasting: Bool = false
    @Published var isTransitioning: Bool = false
    @Published var status: Status = .idle

    let cameraManager = CameraManager()
    let recorder = Recorder(filenamePrefix: "Sender")
    private var sender: NDISender?
    private let senderLock = NSLock()

    private func setSender(_ s: NDISender?) {
        senderLock.lock()
        sender = s
        senderLock.unlock()
    }

    private func currentSender() -> NDISender? {
        senderLock.lock()
        let s = sender
        senderLock.unlock()
        return s
    }

    init() {
        DebugLog.write("BroadcastController.init")
        let cameras = CameraManager.availableDevices()
        self.availableCameras = cameras

        let saved = UserDefaults.standard.string(forKey: "lastCameraID")
        if let saved, cameras.contains(where: { $0.uniqueID == saved }) {
            self.selectedCameraID = saved
        } else if let facetime = cameras.first(where: { $0.localizedName.lowercased().contains("facetime") }) {
            self.selectedCameraID = facetime.uniqueID
        } else {
            self.selectedCameraID = cameras.first?.uniqueID ?? ""
        }

        self.sourceName = UserDefaults.standard.string(forKey: "lastSourceName") ?? "Mac Camera"

        let savedFPS = UserDefaults.standard.integer(forKey: "targetFPS")
        self.targetFPS = (savedFPS == 30 || savedFPS == 60) ? savedFPS : 30

        let savedQuality = UserDefaults.standard.string(forKey: "quality").flatMap(QualityPreset.init(rawValue:))
        self.quality = savedQuality ?? .native

        let savedPixelFormat = UserDefaults.standard.string(forKey: "pixelFormat").flatMap(CapturePixelFormat.init(rawValue:))
        self.pixelFormat = savedPixelFormat ?? .bgra

        self.smoothPacing = UserDefaults.standard.bool(forKey: "smoothPacing")
        cameraManager.setPixelFormat(pixelFormat)
        DebugLog.write("BroadcastController selectedCameraID=\(selectedCameraID) sourceName=\(sourceName) fps=\(targetFPS) quality=\(quality.rawValue) pixelFormat=\(pixelFormat.rawValue) smoothPacing=\(smoothPacing)")
    }

    func currentDevice() -> AVCaptureDevice? {
        availableCameras.first(where: { $0.uniqueID == selectedCameraID })
    }

    func refreshCameras() {
        availableCameras = CameraManager.availableDevices()
        DebugLog.write("refreshCameras count=\(availableCameras.count) selected=\(selectedCameraID)")
    }

    func start() {
        DebugLog.write("BroadcastController.start requested isBroadcasting=\(isBroadcasting) isTransitioning=\(isTransitioning)")
        guard !isBroadcasting, !isTransitioning else { return }
        isTransitioning = true

        Task {
            let granted = await CameraManager.requestAccess()
            guard granted else {
                DebugLog.write("ERROR camera permission denied")
                self.status = .error("Camera permission denied. Enable in System Settings → Privacy & Security → Camera.")
                self.isTransitioning = false
                return
            }
            guard let device = self.currentDevice() else {
                DebugLog.write("ERROR no currentDevice selectedCameraID=\(self.selectedCameraID) available=\(self.availableCameras.map { $0.localizedName })")
                self.status = .error("No camera selected.")
                self.isTransitioning = false
                return
            }

            do {
                try self.cameraManager.switchToDevice(device, quality: self.quality, fps: self.targetFPS, pixelFormat: self.pixelFormat)
            } catch {
                DebugLog.write("ERROR switchToDevice failed \(error.localizedDescription)")
                self.status = .error(error.localizedDescription)
                self.isTransitioning = false
                return
            }

            guard let s = NDISender(sourceName: self.sourceName, clockVideo: self.smoothPacing) else {
                DebugLog.write("ERROR NDISender create failed sourceName=\(self.sourceName)")
                self.status = .error("Failed to create NDI sender. Is the NDI runtime installed?")
                self.isTransitioning = false
                return
            }
            DebugLog.write("NDISender created sourceName=\(self.sourceName) clockVideo=\(self.smoothPacing)")
            self.setSender(s)

            let fpsN = Int32(self.targetFPS * 1000)
            let fpsD: Int32 = 1000
            let rec = self.recorder
            var sentFrameCount = 0
            self.cameraManager.onFrame = { [weak self] pb, pts in
                guard let self else { return }
                if let snd = self.currentSender() {
                    sentFrameCount += 1
                    if sentFrameCount == 1 || sentFrameCount % 60 == 0 {
                        DebugLog.write("sender onFrame \(sentFrameCount) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) pf=\(CVPixelBufferGetPixelFormatType(pb)) pts=\(pts.seconds)")
                    }
                    snd.send(pb, frameRateN: fpsN, frameRateD: fpsD)
                } else {
                    DebugLog.write("WARN onFrame with nil sender")
                }
                self.observeDimensionsIfNeeded(pb)
                rec.append(pixelBuffer: pb, pts: pts)
            }

            self.cameraManager.start()
            self.isBroadcasting = true
            self.isTransitioning = false
            self.status = .live(width: 0, height: 0, fps: self.targetFPS)
            DebugLog.write("BroadcastController.start completed")
        }
    }

    func stop() {
        DebugLog.write("BroadcastController.stop requested")
        guard isBroadcasting, !isTransitioning else { return }
        isTransitioning = true
        if recorder.isRecording { recorder.stop() }
        cameraManager.onFrame = nil
        cameraManager.stop()
        let outgoing = currentSender()
        setSender(nil)
        outgoing?.stop()
        isBroadcasting = false
        status = .idle
        isTransitioning = false
        DebugLog.write("BroadcastController.stop completed")
    }

    private func restartSender() {
        DebugLog.write("restartSender")
        let outgoing = currentSender()
        setSender(nil)
        outgoing?.stop()
        let fresh = NDISender(sourceName: sourceName, clockVideo: smoothPacing)
        setSender(fresh)
        if fresh == nil {
            DebugLog.write("ERROR restartSender failed")
            status = .error("Failed to recreate NDI sender.")
        } else {
            DebugLog.write("restartSender succeeded")
        }
    }

    private var lastReportedDims: (Int, Int) = (0, 0)
    private func observeDimensionsIfNeeded(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        if (w, h) != lastReportedDims {
            lastReportedDims = (w, h)
            DebugLog.write("observeDimensions \(w)x\(h)")
            let fps = self.targetFPS
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isBroadcasting else { return }
                self.status = .live(width: w, height: h, fps: fps)
            }
        }
    }
}
