import XCTest
import CoreMedia
@testable import NDIStream

final class FrameProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        let payload = Data([0x00, 0x00, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        let packet = VideoPacket(codec: .hevc, isKeyframe: true, ptsNanos: 1_234_567_890,
                                 width: 1920, height: 1080, parameterSets: [], payload: payload)
        let wire = packet.serialize()
        let parsed = try XCTUnwrap(VideoPacket.parse(wire))
        XCTAssertEqual(parsed.codec, .hevc)
        XCTAssertTrue(parsed.isKeyframe)
        XCTAssertEqual(parsed.ptsNanos, 1_234_567_890)
        XCTAssertEqual(parsed.width, 1920)
        XCTAssertEqual(parsed.height, 1080)
        XCTAssertEqual(parsed.payload, payload)
    }

    func testRejectsBadMagic() {
        let bad = Data(repeating: 0xFF, count: 30)
        XCTAssertNil(VideoPacket.parse(bad))
    }

    func testRejectsTruncatedPayload() {
        let packet = VideoPacket(codec: .h264, isKeyframe: false, ptsNanos: 0,
                                 width: 2, height: 2, parameterSets: [], payload: Data([1,2,3,4]))
        var wire = packet.serialize()
        wire.removeLast(2)
        XCTAssertNil(VideoPacket.parse(wire))
    }
}
