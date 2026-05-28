import Foundation

enum QLCodec: UInt8 {
    case h264 = 0
    case hevc = 1
}

/// One QuicLink video frame on the wire: a header, the codec parameter sets
/// (carried on every all-intra frame so any frame is independently decodable),
/// then the AVCC payload. All multi-byte fields are big-endian.
///
/// Header layout (fixed 26 bytes):
///   magic(2)=0x514C, version(1), codec(1), flags(1: bit0 keyframe), reserved(1),
///   ptsNanos(8), width(2), height(2), parameterSetsLength(4), payloadLength(4)
/// Then `parameterSetsLength` bytes of parameter-set blob:
///   count(1), then for each set: length(4) + bytes
/// Then `payloadLength` bytes of AVCC payload.
struct VideoPacket: Equatable {
    static let magic: UInt16 = 0x514C
    static let version: UInt8 = 2
    static let headerByteCount = 26
    private static let keyframeFlag: UInt8 = 0x01

    var codec: QLCodec
    var isKeyframe: Bool
    var ptsNanos: Int64
    var width: UInt16
    var height: UInt16
    var parameterSets: [Data]
    var payload: Data

    func serialize() -> Data {
        let psBlob = Self.encodeParameterSets(parameterSets)
        var d = Data(capacity: Self.headerByteCount + psBlob.count + payload.count)
        d.appendBE(Self.magic)
        d.append(Self.version)
        d.append(codec.rawValue)
        d.append(isKeyframe ? Self.keyframeFlag : 0)
        d.append(0) // reserved
        d.appendBE(UInt64(bitPattern: ptsNanos))
        d.appendBE(width)
        d.appendBE(height)
        d.appendBE(UInt32(psBlob.count))
        d.appendBE(UInt32(payload.count))
        d.append(psBlob)
        d.append(payload)
        return d
    }

    static func parse(_ data: Data) -> VideoPacket? {
        guard data.count >= headerByteCount else { return nil }
        var c = ByteCursor(data)
        guard c.readBE() as UInt16 == magic else { return nil }
        guard c.readByte() == version else { return nil }
        guard let codec = QLCodec(rawValue: c.readByte()) else { return nil }
        let flags = c.readByte()
        _ = c.readByte()
        let pts = Int64(bitPattern: c.readBE() as UInt64)
        let width: UInt16 = c.readBE()
        let height: UInt16 = c.readBE()
        let psLen = Int(c.readBE() as UInt32)
        let payLen = Int(c.readBE() as UInt32)
        guard data.count >= headerByteCount + psLen + payLen else { return nil }
        let psStart = data.startIndex + headerByteCount
        let psBlob = data.subdata(in: psStart ..< psStart + psLen)
        guard let sets = decodeParameterSets(psBlob) else { return nil }
        let payStart = psStart + psLen
        let payload = data.subdata(in: payStart ..< payStart + payLen)
        return VideoPacket(codec: codec, isKeyframe: (flags & keyframeFlag) != 0,
                           ptsNanos: pts, width: width, height: height,
                           parameterSets: sets, payload: payload)
    }

    private static func encodeParameterSets(_ sets: [Data]) -> Data {
        var d = Data()
        d.append(UInt8(sets.count))
        for s in sets { d.appendBE(UInt32(s.count)); d.append(s) }
        return d
    }

    private static func decodeParameterSets(_ blob: Data) -> [Data]? {
        guard !blob.isEmpty else { return [] }
        var c = ByteCursor(blob)
        let count = Int(c.readByte())
        var sets: [Data] = []
        for _ in 0..<count {
            guard c.remaining >= 4 else { return nil }
            let len = Int(c.readBE() as UInt32)
            guard c.remaining >= len else { return nil }
            sets.append(c.readBytes(len))
        }
        return sets
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

struct ByteCursor {
    let data: Data
    var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }
    mutating func readByte() -> UInt8 { defer { offset += 1 }; return data[offset] }
    mutating func readBytes(_ n: Int) -> Data { defer { offset += n }; return data.subdata(in: offset ..< offset + n) }
    mutating func readBE() -> UInt16 { defer { offset += 2 }; return (UInt16(data[offset]) << 8) | UInt16(data[offset+1]) }
    mutating func readBE() -> UInt32 { defer { offset += 4 }; var v: UInt32 = 0; for i in 0..<4 { v = (v << 8) | UInt32(data[offset+i]) }; return v }
    mutating func readBE() -> UInt64 { defer { offset += 8 }; var v: UInt64 = 0; for i in 0..<8 { v = (v << 8) | UInt64(data[offset+i]) }; return v }
}
