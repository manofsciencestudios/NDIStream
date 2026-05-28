import CoreMedia
import Foundation

/// Extracts the codec parameter sets (HEVC: VPS/SPS/PPS, H.264: SPS/PPS) from a
/// `CMFormatDescription` and rebuilds an equivalent description from those sets.
///
/// The wire path carries the parameter sets alongside every all-intra frame
/// (see `VideoPacket`); the receiver rebuilds the format description so it can
/// construct a `VideoDecoder` without ever having seen the original encoder's
/// description.
enum CodecParameterSets {
    static func extract(from fmt: CMFormatDescription, codec: QLCodec) -> [Data]? {
        var count = 0
        let probe: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return sets
    }

    static func makeFormatDescription(codec: QLCodec, parameterSets: [Data]) -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let sizes = parameterSets.map { $0.count }
        // The C API takes two parallel C arrays: one of `UnsafePointer<UInt8>` (one per
        // parameter set) and one of sizes. Every pointer must be valid simultaneously at
        // the moment of the call. Building the pointer array by returning `baseAddress`
        // out of a `withUnsafeBytes` closure would dangle (the borrow ends when the
        // closure returns). Instead we recursively nest one `withUnsafeBytes` per Data,
        // accumulating the borrowed pointers, and make the C call at the innermost level
        // where all the borrows are still live on the stack.
        return withParameterSetPointers(parameterSets, []) { ptrs in
            create(codec: codec, pointers: ptrs, sizes: sizes)
        }
    }

    /// Recursively borrows each `Data` via `withUnsafeBytes`, accumulating the resulting
    /// `UnsafePointer<UInt8>` values. When every set has been borrowed, invokes `body`
    /// with the full pointer array while all the borrows are still on the stack, so every
    /// pointer is guaranteed valid for the duration of `body`.
    private static func withParameterSetPointers(
        _ datas: [Data],
        _ pointers: [UnsafePointer<UInt8>],
        _ body: ([UnsafePointer<UInt8>]) -> CMFormatDescription?
    ) -> CMFormatDescription? {
        if pointers.count == datas.count { return body(pointers) }
        return datas[pointers.count].withUnsafeBytes { raw -> CMFormatDescription? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return withParameterSetPointers(datas, pointers + [base], body)
        }
    }

    private static func create(codec: QLCodec,
                               pointers: [UnsafePointer<UInt8>],
                               sizes: [Int]) -> CMFormatDescription? {
        var fmt: CMFormatDescription?
        // nalUnitHeaderLength: 4 matches VideoToolbox's AVCC framing (4-byte length prefixes).
        let status: OSStatus = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                codec == .hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &fmt)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr else { return nil }
        return fmt
    }
}
