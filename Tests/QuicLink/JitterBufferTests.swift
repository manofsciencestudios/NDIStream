import XCTest
import Foundation
@testable import NDIStream

final class JitterBufferTests: XCTestCase {
    private func packet(_ pts: Int64) -> VideoPacket {
        VideoPacket(codec: .hevc, isKeyframe: true, ptsNanos: pts,
                    width: 2, height: 2, parameterSets: [], payload: Data([UInt8(pts & 0xff)]))
    }

    func testDrainReturnsPtsOrderSkippingGaps() {
        let jb = JitterBuffer(maxDepth: 8)
        jb.push(packet(1000))
        jb.push(packet(4000))   // arrives before 3000
        jb.push(packet(3000))   // out of order; pts 2000 is MISSING entirely
        let out = jb.drain().map { $0.ptsNanos }
        XCTAssertEqual(out, [1000, 3000, 4000], "ordered by pts; the missing 2000 never blocks the rest")
    }

    func testPopReleasesOldestOnlyAtMaxDepth() {
        let jb = JitterBuffer(maxDepth: 2)
        jb.push(packet(1000))
        XCTAssertNil(jb.pop(), "below maxDepth: buffer to absorb jitter")
        jb.push(packet(2000))                    // now at maxDepth (2)
        XCTAssertEqual(jb.pop()?.ptsNanos, 1000)  // releases oldest
        XCTAssertNil(jb.pop(), "back below maxDepth")
        jb.push(packet(5000))
        XCTAssertEqual(jb.pop()?.ptsNanos, 2000)  // oldest-first
    }

    func testIgnoresDuplicatePts() {
        let jb = JitterBuffer(maxDepth: 8)
        jb.push(packet(1000)); jb.push(packet(1000))
        XCTAssertEqual(jb.count, 1)
    }
}
