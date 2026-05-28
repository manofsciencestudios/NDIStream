import XCTest
import CoreMedia
@testable import NDIStream

final class FrameProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        let payload = Data([0x00, 0x00, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        let header = VideoFrameHeader(
            codec: .hevc,
            isKeyframe: true,
            ptsNanos: 1_234_567_890,
            width: 1920,
            height: 1080,
            payloadLength: UInt32(payload.count)
        )
        let wire = VideoFrameHeader.serialize(header: header, payload: payload)
        let parsed = try XCTUnwrap(VideoFrameHeader.parse(wire))
        XCTAssertEqual(parsed.header.codec, .hevc)
        XCTAssertTrue(parsed.header.isKeyframe)
        XCTAssertEqual(parsed.header.ptsNanos, 1_234_567_890)
        XCTAssertEqual(parsed.header.width, 1920)
        XCTAssertEqual(parsed.header.height, 1080)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testRejectsBadMagic() {
        let bad = Data(repeating: 0xFF, count: 24)
        XCTAssertNil(VideoFrameHeader.parse(bad))
    }

    func testRejectsTruncatedPayload() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let header = VideoFrameHeader(codec: .h264, isKeyframe: false,
                                      ptsNanos: 0, width: 2, height: 2,
                                      payloadLength: UInt32(payload.count))
        var wire = VideoFrameHeader.serialize(header: header, payload: payload)
        wire.removeLast(2) // truncate
        XCTAssertNil(VideoFrameHeader.parse(wire))
    }
}
