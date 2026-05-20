import AVFoundation
import Combine
import CoreVideo
import Foundation
import SwiftUI

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
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS) }
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
                do { try cameraManager.switchToDevice(dev, quality: quality, fps: targetFPS) }
                catch { status = .error(error.localizedDescription) }
            }
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

    init() {
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

        self.smoothPacing = UserDefaults.standard.bool(forKey: "smoothPacing")
    }

    func currentDevice() -> AVCaptureDevice? {
        availableCameras.first(where: { $0.uniqueID == selectedCameraID })
    }

    func refreshCameras() {
        availableCameras = CameraManager.availableDevices()
    }

    func start() {
        guard !isBroadcasting, !isTransitioning else { return }
        isTransitioning = true

        Task {
            let granted = await CameraManager.requestAccess()
            guard granted else {
                self.status = .error("Camera permission denied. Enable in System Settings → Privacy & Security → Camera.")
                self.isTransitioning = false
                return
            }
            guard let device = self.currentDevice() else {
                self.status = .error("No camera selected.")
                self.isTransitioning = false
                return
            }

            do {
                try self.cameraManager.switchToDevice(device, quality: self.quality, fps: self.targetFPS)
            } catch {
                self.status = .error(error.localizedDescription)
                self.isTransitioning = false
                return
            }

            guard let s = NDISender(sourceName: self.sourceName, clockVideo: self.smoothPacing) else {
                self.status = .error("Failed to create NDI sender. Is the NDI runtime installed?")
                self.isTransitioning = false
                return
            }
            self.sender = s

            let fpsN = Int32(self.targetFPS * 1000)
            let fpsD: Int32 = 1000
            let rec = self.recorder
            self.cameraManager.onFrame = { [weak self] pb, pts in
                guard let self else { return }
                if let snd = self.senderRef() {
                    snd.send(pb, frameRateN: fpsN, frameRateD: fpsD)
                }
                self.observeDimensionsIfNeeded(pb)
                rec.append(pixelBuffer: pb, pts: pts)
            }

            self.cameraManager.start()
            self.isBroadcasting = true
            self.isTransitioning = false
            self.status = .live(width: 0, height: 0, fps: self.targetFPS)
        }
    }

    func stop() {
        guard isBroadcasting, !isTransitioning else { return }
        isTransitioning = true
        if recorder.isRecording { recorder.stop() }
        cameraManager.onFrame = nil
        cameraManager.stop()
        sender?.stop()
        sender = nil
        isBroadcasting = false
        status = .idle
        isTransitioning = false
    }

    private func restartSender() {
        sender?.stop()
        sender = NDISender(sourceName: sourceName, clockVideo: smoothPacing)
        if sender == nil {
            status = .error("Failed to recreate NDI sender.")
        }
    }

    private func senderRef() -> NDISender? {
        return sender
    }

    private var lastReportedDims: (Int, Int) = (0, 0)
    private func observeDimensionsIfNeeded(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        if (w, h) != lastReportedDims {
            lastReportedDims = (w, h)
            let fps = self.targetFPS
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isBroadcasting else { return }
                self.status = .live(width: w, height: h, fps: fps)
            }
        }
    }
}
