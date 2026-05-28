import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder {
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var session: VTDecompressionSession?
    private let formatDescription: CMFormatDescription

    init?(formatDescription: CMFormatDescription) {
        self.formatDescription = formatDescription
        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,   // block-based decode
            decompressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        self.session = session
    }

    func decode(_ data: Data, pts: CMTime, isKeyframe: Bool) {
        guard let session,
              let sampleBuffer = Self.makeSampleBuffer(data: data, pts: pts,
                                                       formatDescription: formatDescription)
        else { return }
        // Use synchronous decode (no _EnableAsynchronousDecompression) so the NSMutableData
        // backing the CMBlockBuffer (allocated with kCFAllocatorNull, i.e. not copied by VT)
        // is guaranteed to remain live until VTDecompressionSessionDecodeFrame returns.
        // With async decode that data could be released before VideoToolbox finishes reading it,
        // causing intermittent garbage or silent failures. Correctness first.
        let flags: VTDecodeFrameFlags = []
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, imageBuffer, pts, _ in
                guard let self, status == noErr, let imageBuffer else { return }
                self.onDecodedFrame?(imageBuffer, pts)
            })
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private static func makeSampleBuffer(data: Data, pts: CMTime,
                                         formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let mutableData = NSMutableData(data: data)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mutableData.mutableBytes,
            blockLength: mutableData.length,
            blockAllocator: kCFAllocatorNull,   // we own `mutableData` for the call's duration
            customBlockSource: nil, offsetToData: 0, dataLength: mutableData.length,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleSize = mutableData.length
        let ss = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard ss == noErr else { return nil }
        return sampleBuffer
    }
}
