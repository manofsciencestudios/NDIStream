import XCTest
import CoreMedia
import VideoToolbox
@testable import NDIStream

final class CodecParameterSetsTests: XCTestCase {
    func testExtractAndRebuildHEVC() throws {
        let enc = try XCTUnwrap(VideoEncoder(width: 320, height: 240, codec: .hevc, fps: 30, bitrate: 2_000_000))
        let exp = expectation(description: "encoded"); var frame: VideoEncoder.EncodedFrame?
        enc.onEncodedFrame = { if frame == nil { frame = $0; exp.fulfill() } }
        enc.encode(PixelBufferFactory.solid(width: 320, height: 240), pts: CMTime(value: 0, timescale: 30))
        wait(for: [exp], timeout: 5.0); let f = try XCTUnwrap(frame)

        let sets = try XCTUnwrap(CodecParameterSets.extract(from: f.formatDescription, codec: .hevc))
        XCTAssertEqual(sets.count, 3) // VPS, SPS, PPS

        let rebuilt = try XCTUnwrap(CodecParameterSets.makeFormatDescription(codec: .hevc, parameterSets: sets))
        let dec = try XCTUnwrap(VideoDecoder(formatDescription: rebuilt))
        let decoded = expectation(description: "decoded"); var pb: CVPixelBuffer?
        dec.onDecodedFrame = { b, _ in if pb == nil { pb = b; decoded.fulfill() } }
        dec.decode(f.data, pts: f.pts, isKeyframe: true)
        wait(for: [decoded], timeout: 5.0)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(pb)), 320)
        enc.invalidate(); dec.invalidate()
    }
}
