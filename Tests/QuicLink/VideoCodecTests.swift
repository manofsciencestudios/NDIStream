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
}
