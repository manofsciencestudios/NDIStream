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
        defer { recorder.stop() }

        for i in 0..<30 {
            let pb = try makeBlackPixelBuffer(width: 320, height: 240)
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            recorder.append(pixelBuffer: pb, pts: pts)
        }
        // Give the writer queue a moment to flush.
        Thread.sleep(forTimeInterval: 0.5)
        recorder.stop()
        Thread.sleep(forTimeInterval: 0.5)

        // Find the most recent .mov in ~/Movies/NDIStream/ matching the prefix.
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NDIStream")
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let smokeFiles = contents.filter { $0.lastPathComponent.hasPrefix("SmokeTest") }
        guard let latest = smokeFiles.max(by: { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }) else {
            XCTFail("No SmokeTest .mov produced in \(dir.path)")
            return
        }
        defer { try? FileManager.default.removeItem(at: latest) }

        let asset = AVAsset(url: latest)
        let tracks = try await asset.loadTracks(withMediaType: .video)
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
