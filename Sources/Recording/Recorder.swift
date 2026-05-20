import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class Recorder: ObservableObject, @unchecked Sendable {
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var elapsed: TimeInterval = 0
    @MainActor @Published private(set) var lastError: String? = nil

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let writeQueue = DispatchQueue(label: "NDIStream.Recorder.Write")
    private var startPTS: CMTime?
    private var writerActive = false
    private let writerActiveLock = NSLock()

    @MainActor private var timer: Timer?
    @MainActor private var startWallTime: Date?

    private let prefix: String

    init(filenamePrefix: String) { self.prefix = filenamePrefix }

    private func setWriterActive(_ active: Bool) {
        writerActiveLock.lock()
        writerActive = active
        writerActiveLock.unlock()
    }

    private func isWriterActive() -> Bool {
        writerActiveLock.lock()
        let v = writerActive
        writerActiveLock.unlock()
        return v
    }

    @MainActor
    func start() {
        guard !isRecording else { return }
        isRecording = true
        elapsed = 0
        startWallTime = Date()
        lastError = nil
        setWriterActive(true)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.startPTS = nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startWallTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func append(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard isWriterActive() else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
        writeQueue.async { [weak self] in
            guard let self, self.isWriterActive() else { return }
            if self.writer == nil {
                self.setupWriter(width: w, height: h, pixelFormat: pf, firstPTS: pts)
            }
            guard let writer = self.writer,
                  let input = self.input,
                  let adaptor = self.adaptor else { return }
            if writer.status == .failed {
                self.surface(error: writer.error?.localizedDescription ?? "Writer failed")
                return
            }
            guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                let msg = writer.error?.localizedDescription ?? "Append failed (status \(writer.status.rawValue))"
                self.surface(error: msg)
            }
        }
    }

    @MainActor
    func stop() {
        guard isRecording else { return }
        isRecording = false
        setWriterActive(false)
        timer?.invalidate()
        timer = nil
        writeQueue.async { [weak self] in
            guard let self else { return }
            guard let w = self.writer else {
                self.input = nil
                self.adaptor = nil
                self.startPTS = nil
                return
            }
            self.input?.markAsFinished()
            w.finishWriting {
                if w.status == .failed {
                    let msg = w.error?.localizedDescription ?? "Finalize failed"
                    Task { @MainActor in self.lastError = msg }
                }
            }
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.startPTS = nil
        }
    }

    private func setupWriter(width: Int, height: Int, pixelFormat: OSType, firstPTS: CMTime) {
        let url = Recorder.makeURL(prefix: prefix)
        do {
            try Recorder.ensureDirectory()
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitrate(width: width, height: height),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 60
                ]
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: i,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            guard w.canAdd(i) else {
                surface(error: "Cannot add video input for \(width)×\(height)")
                return
            }
            w.add(i)
            guard w.startWriting() else {
                surface(error: w.error?.localizedDescription ?? "startWriting failed")
                return
            }
            w.startSession(atSourceTime: firstPTS)
            self.writer = w
            self.input = i
            self.adaptor = a
            self.startPTS = firstPTS
        } catch {
            surface(error: error.localizedDescription)
        }
    }

    private func surface(error message: String) {
        setWriterActive(false)
        if let w = writer {
            w.cancelWriting()
        }
        writer = nil
        input = nil
        adaptor = nil
        startPTS = nil
        Task { @MainActor in
            self.lastError = message
            self.isRecording = false
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    private static func bitrate(width: Int, height: Int) -> Int {
        let pixels = width * height
        if pixels >= 1920 * 1080 { return 10_000_000 }
        if pixels >= 1280 * 720  { return 5_000_000 }
        return 3_000_000
    }

    static func recordingsDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("NDIStream", isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: recordingsDirectory(),
                                                withIntermediateDirectories: true)
    }

    static func makeURL(prefix: String) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "\(prefix)-\(df.string(from: Date())).mov"
        return recordingsDirectory().appendingPathComponent(name)
    }

    static func revealRecordingsFolder() {
        try? ensureDirectory()
        NSWorkspace.shared.open(recordingsDirectory())
    }
}
