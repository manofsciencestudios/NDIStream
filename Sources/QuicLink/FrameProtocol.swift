import Foundation

enum QLCodec: UInt8 {
    case h264 = 0
    case hevc = 1
}

/// Fixed 22-byte big-endian header that precedes every QuicLink video frame.
/// Layout: magic(2) version(1) codec(1) flags(1) reserved(1) pts(8) width(2) height(2) payloadLength(4) = 22 bytes
struct VideoFrameHeader {
    static let magic: UInt16 = 0x514C            // "QL"
    static let version: UInt8 = 1
    static let byteCount = 22
    private static let keyframeFlag: UInt8 = 0x01

    var codec: QLCodec
    var isKeyframe: Bool
    var ptsNanos: Int64
    var width: UInt16
    var height: UInt16
    var payloadLength: UInt32

    static func serialize(header: VideoFrameHeader, payload: Data) -> Data {
        var d = Data(capacity: byteCount + payload.count)
        d.appendBE(magic)
        d.append(version)
        d.append(header.codec.rawValue)
        d.append(header.isKeyframe ? keyframeFlag : 0)
        d.append(0) // reserved
        d.appendBE(UInt64(bitPattern: header.ptsNanos))
        d.appendBE(header.width)
        d.appendBE(header.height)
        d.appendBE(header.payloadLength)
        d.append(payload)
        return d
    }

    static func parse(_ data: Data) -> (header: VideoFrameHeader, payload: Data)? {
        guard data.count >= byteCount else { return nil }
        var c = ByteCursor(data)
        guard c.readBE() as UInt16 == magic else { return nil }
        guard c.readByte() == version else { return nil }
        guard let codec = QLCodec(rawValue: c.readByte()) else { return nil }
        let flags = c.readByte()
        _ = c.readByte() // reserved
        let pts = Int64(bitPattern: c.readBE())
        let width: UInt16 = c.readBE()
        let height: UInt16 = c.readBE()
        let payloadLength: UInt32 = c.readBE()
        guard data.count >= byteCount + Int(payloadLength) else { return nil }
        let payload = data.subdata(in: (data.startIndex + byteCount)..<(data.startIndex + byteCount + Int(payloadLength)))
        let header = VideoFrameHeader(codec: codec,
                                      isKeyframe: (flags & keyframeFlag) != 0,
                                      ptsNanos: pts, width: width, height: height,
                                      payloadLength: payloadLength)
        return (header, payload)
    }
}

private extension Data {
    mutating func appendBE(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

private struct ByteCursor {
    let data: Data
    var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    mutating func readByte() -> UInt8 { defer { offset += 1 }; return data[offset] }
    mutating func readBE() -> UInt16 {
        defer { offset += 2 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
    mutating func readBE() -> UInt32 {
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[offset + i]) }
        return v
    }
    mutating func readBE() -> UInt64 {
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[offset + i]) }
        return v
    }
}
