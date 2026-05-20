import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

@MainActor
final class ReceiverModel: NSObject, ObservableObject {
    @Published var availableSources: [NDIFoundSource] = []
    @Published var selectedSourceName: String = ""
    @Published var isConnected: Bool = false
    @Published var statusLine: String = "No source selected"
    @Published var lastFormat: FrameFormat? = nil
    @Published var slate: String = "" {
        didSet { UserDefaults.standard.set(slate, forKey: "receiverSlate") }
    }
    @Published var autoRecord: Bool = false {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "receiverAutoRecord") }
    }
    @Published var isLocked: Bool = false

    struct FrameFormat: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let fourCC: String
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated let recorder = Recorder(filenamePrefix: "Receiver")

    private let finder: NDIFinder?
    private var receiver: NDIReceiver?
    private var receivedFrameCount = 0

    override init() {
        DebugLog.write("ReceiverModel.init")
        self.finder = NDIFinder.startNew()
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        if let saved = UserDefaults.standard.string(forKey: "lastReceiverSource") {
            selectedSourceName = saved
        }
        self.slate = UserDefaults.standard.string(forKey: "receiverSlate") ?? ""
        self.autoRecord = UserDefaults.standard.bool(forKey: "receiverAutoRecord")

        finder?.onSourcesChanged = { [weak self] sources in
            guard let self else { return }
            Task { @MainActor in
                self.availableSources = sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                DebugLog.write("receiver sources changed count=\(self.availableSources.count) names=\(self.availableSources.map { $0.name })")
                if self.selectedSourceName.isEmpty, let first = self.availableSources.first {
                    self.selectedSourceName = first.name
                    DebugLog.write("receiver selected first source=\(first.name)")
                }
            }
        }

        availableSources = (finder?.currentSources() ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func connect() {
        DebugLog.write("receiver connect requested selected=\(selectedSourceName) available=\(availableSources.map { $0.name })")
        guard !isConnected else { return }
        let name = selectedSourceName
        guard !name.isEmpty else {
            statusLine = "No source selected"
            return
        }
        guard let source = availableSources.first(where: { $0.name == name }) else {
            DebugLog.write("ERROR receiver source not online name=\(name)")
            statusLine = "Source '\(name)' not currently online"
            return
        }

        UserDefaults.standard.set(name, forKey: "lastReceiverSource")

        guard let r = NDIReceiver(sourceName: source.name, sourceAddress: source.address) else {
            DebugLog.write("ERROR receiver create failed name=\(source.name) address=\(source.address)")
            statusLine = "Failed to create receiver"
            return
        }
        r.delegate = self
        receiver = r
        isConnected = true
        ActivityKeeper.begin("receiver")
        statusLine = "Connecting to \(name)…"
        lastFormat = nil
        receivedFrameCount = 0
        DebugLog.write("receiver created name=\(source.name) address=\(source.address)")
        if autoRecord, !recorder.isRecording {
            DebugLog.write("auto-record start (receiver)")
            recorder.start(slate: slate)
        }
    }

    func disconnect() {
        DebugLog.write("receiver disconnect requested")
        guard isConnected || receiver != nil else { return }
        if recorder.isRecording { recorder.stop() }
        receiver?.delegate = nil
        receiver?.stop()
        receiver = nil
        isConnected = false
        ActivityKeeper.end("receiver")
        displayLayer.flushAndRemoveImage()
        statusLine = "Disconnected"
        lastFormat = nil
        DebugLog.write("receiver disconnected")
    }
}

extension ReceiverModel: NDIReceiverDelegate {
    nonisolated func receiverDidReceive(_ sampleBuffer: CMSampleBuffer,
                                        width: Int32,
                                        height: Int32,
                                        frameRateN: Int32,
                                        frameRateD: Int32,
                                        fourCC: UInt32) {
        let retained = sampleBuffer
        let w = Int(width)
        let h = Int(height)
        let frN = Int(frameRateN)
        let frD = Int(frameRateD)
        let cc = fourCC
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recorder.append(pixelBuffer: pb, pts: pts)
        }
        Task { @MainActor in
            self.enqueueSampleBuffer(retained, width: w, height: h, frameRateN: frN, frameRateD: frD, fourCC: cc)
        }
    }

    nonisolated func receiverDidDisconnect() {
        Task { @MainActor in
            self.handleRemoteDisconnect()
        }
    }

    nonisolated func receiverDidStall(forSeconds seconds: Int) {
        Task { @MainActor in
            guard self.isConnected else { return }
            self.statusLine = "Reconnecting (\(seconds)s)…"
        }
    }

    nonisolated func receiverDidResume() {
        Task { @MainActor in
            guard self.isConnected else { return }
            self.statusLine = "Reconnected"
        }
    }

    private func enqueueSampleBuffer(_ sb: CMSampleBuffer,
                                     width: Int,
                                     height: Int,
                                     frameRateN: Int,
                                     frameRateD: Int,
                                     fourCC: UInt32) {
        receivedFrameCount += 1
        if displayLayer.status == .failed {
            DebugLog.write("WARN receiver displayLayer failed; flushing error=\(String(describing: displayLayer.error))")
            displayLayer.flush()
        }
        if !displayLayer.isReadyForMoreMediaData {
            DebugLog.write("WARN receiver displayLayer backpressure; flushing queued frames")
            displayLayer.flush()
        }
        displayLayer.enqueue(sb)

        let fps: Int
        if frameRateD > 0 {
            fps = Int((Double(frameRateN) / Double(frameRateD)).rounded())
        } else {
            fps = 0
        }
        let fourCCStr = Self.fourCCString(fourCC)
        let fmt = FrameFormat(width: width, height: height, fps: fps, fourCC: fourCCStr)
        if receivedFrameCount == 1 || receivedFrameCount % 60 == 0 {
            DebugLog.write("receiver frame \(receivedFrameCount) \(width)x\(height) fps=\(fps) fourCC=\(fourCCStr) displayStatus=\(displayLayer.status.rawValue)")
        }
        if lastFormat != fmt {
            lastFormat = fmt
            statusLine = "\(width)×\(height) @ \(fps) • \(fourCCStr)"
            DebugLog.write("receiver format \(statusLine)")
        }
    }

    private func handleRemoteDisconnect() {
        DebugLog.write("WARN receiver remote disconnect")
        if recorder.isRecording { recorder.stop() }
        receiver?.delegate = nil
        receiver?.stop()
        receiver = nil
        isConnected = false
        ActivityKeeper.end("receiver")
        displayLayer.flushAndRemoveImage()
        statusLine = "Source offline"
        lastFormat = nil
    }

    private static func fourCCString(_ cc: UInt32) -> String {
        let b0 = UInt8((cc >> 0) & 0xff)
        let b1 = UInt8((cc >> 8) & 0xff)
        let b2 = UInt8((cc >> 16) & 0xff)
        let b3 = UInt8((cc >> 24) & 0xff)
        let bytes: [UInt8] = [b0, b1, b2, b3]
        let str = String(bytes: bytes, encoding: .ascii) ?? "????"
        return str
    }
}
