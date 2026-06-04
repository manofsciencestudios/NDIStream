import XCTest
import AVFoundation
import CoreMedia
@testable import NDIStream

@MainActor
final class RecordingSmokeTests: XCTestCase {

    /// Confirms the receiver-side recording pipeline produces a readable .mov
    /// when fed synthetic CMSampleBuffers. Transport-agnostic — pins the
    /// pipeline so when QuicLink and WarpStream adapters land they slot in
    /// without breaking the recorder.
    func testReceiverRecorderProducesReadableMov() async throws {
        let recorder = Recorder(filenamePrefix: "SmokeTest")
        recorder.start(slate: "SMOKE", includeAudio: false)

        for i in 0..<30 {
            let pb = try makeBlackPixelBuffer(width: 320, height: 240)
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            recorder.append(pixelBuffer: pb, pts: pts)
        }
        // Brief grace period for the writer queue to receive all 30 frames
        // before stop() starts the finalization sequence.
        try await Task.sleep(nanoseconds: 200_000_000)
        recorder.stop()

        // Poll for the file to appear and for the moov atom to be readable.
        // AVAssetWriter.finishWriting runs asynchronously; without polling
        // the test races on completion (see plan code review I4).
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NDIStream")
        let deadline = Date().addingTimeInterval(5)
        var latest: URL?
        var tracks: [AVAssetTrack] = []
        while Date() < deadline {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                          includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let smokeFiles = contents.filter { $0.lastPathComponent.hasPrefix("SmokeTest") }
            if let file = smokeFiles.max(by: { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }) {
                let asset = AVURLAsset(url: file)
                let loaded = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                if !loaded.isEmpty {
                    latest = file
                    tracks = loaded
                    break
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let smokeFile = latest else {
            XCTFail("No SmokeTest .mov with readable video tracks appeared in \(dir.path) within 5s")
            return
        }
        defer { try? FileManager.default.removeItem(at: smokeFile) }

        XCTAssertFalse(tracks.isEmpty, "Recorded .mov should have at least one video track")
    }

    private func makeBlackPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
