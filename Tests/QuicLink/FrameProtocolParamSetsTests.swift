import XCTest
@testable import NDIStream

final class FrameProtocolParamSetsTests: XCTestCase {
    func testVideoPacketRoundTripWithParameterSets() throws {
        let vps = Data([0x40, 0x01, 0x0c]); let sps = Data([0x42, 0x01]); let pps = Data([0x44, 0x01])
        let payload = Data([0xAA, 0xBB, 0xCC])
        let packet = VideoPacket(codec: .hevc, isKeyframe: true, ptsNanos: 99,
                                 width: 1920, height: 1080,
                                 parameterSets: [vps, sps, pps], payload: payload)
        let wire = packet.serialize()
        let parsed = try XCTUnwrap(VideoPacket.parse(wire))
        XCTAssertEqual(parsed.codec, .hevc)
        XCTAssertEqual(parsed.parameterSets, [vps, sps, pps])
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertEqual(parsed.width, 1920)
        XCTAssertEqual(parsed.ptsNanos, 99)
    }

    func testParseRejectsTruncated() {
        let packet = VideoPacket(codec: .h264, isKeyframe: true, ptsNanos: 0, width: 2, height: 2,
                                 parameterSets: [Data([1, 2])], payload: Data([9]))
        var wire = packet.serialize()
        wire.removeLast(3)
        XCTAssertNil(VideoPacket.parse(wire))
    }
}
