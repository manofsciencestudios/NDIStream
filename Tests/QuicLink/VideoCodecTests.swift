import XCTest
import CoreMedia
import VideoToolbox
@testable import NDIStream

final class VideoCodecTests: XCTestCase {
    func testEncoderEmitsKeyframe() throws {
        let enc = try XCTUnwrap(VideoEncoder(width: 320, height: 240, codec: .hevc,
                                             fps: 30, bitrate: 2_000_000))
        let exp = expectation(description: "encoded frame")
        var got: VideoEncoder.EncodedFrame?
        enc.onEncodedFrame = { frame in
            if got == nil { got = frame; exp.fulfill() }
        }
        let pb = PixelBufferFactory.solid(width: 320, height: 240)
        enc.encode(pb, pts: CMTime(value: 0, timescale: 30))
        wait(for: [exp], timeout: 5.0)
        let frame = try XCTUnwrap(got)
        XCTAssertTrue(frame.isKeyframe, "all-intra: every frame is a keyframe")
        XCTAssertGreaterThan(frame.data.count, 0)
        XCTAssertNotNil(frame.formatDescription)
        enc.invalidate()
    }

    func testEncodeDecodeRoundTrip() throws {
        let enc = try XCTUnwrap(VideoEncoder(width: 320, height: 240, codec: .hevc,
                                             fps: 30, bitrate: 2_000_000))
        let encoded = expectation(description: "encoded")
        var frame: VideoEncoder.EncodedFrame?
        enc.onEncodedFrame = { if frame == nil { frame = $0; encoded.fulfill() } }
        enc.encode(PixelBufferFactory.solid(width: 320, height: 240),
                   pts: CMTime(value: 0, timescale: 30))
        wait(for: [encoded], timeout: 5.0)
        let f = try XCTUnwrap(frame)

        // Prove the encoded payload survives the QuicLink wire framing intact.
        let header = VideoFrameHeader(codec: .hevc, isKeyframe: f.isKeyframe,
                                      ptsNanos: 0, width: 320, height: 240,
                                      payloadLength: UInt32(f.data.count))
        let wire = VideoFrameHeader.serialize(header: header, payload: f.data)
        let parsed = try XCTUnwrap(VideoFrameHeader.parse(wire))
        XCTAssertEqual(parsed.payload, f.data)
        XCTAssertEqual(parsed.header.codec, .hevc)
        XCTAssertTrue(parsed.header.isKeyframe)

        let dec = try XCTUnwrap(VideoDecoder(formatDescription: f.formatDescription))
        let decoded = expectation(description: "decoded")
        var outPB: CVPixelBuffer?
        dec.onDecodedFrame = { pb, _ in if outPB == nil { outPB = pb; decoded.fulfill() } }
        dec.decode(parsed.payload, pts: f.pts, isKeyframe: parsed.header.isKeyframe)
        wait(for: [decoded], timeout: 5.0)

        let pb = try XCTUnwrap(outPB)
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(pb), 240)
        enc.invalidate()
        dec.invalidate()
    }
}
