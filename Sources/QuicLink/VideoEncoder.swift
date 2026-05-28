import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoEncoder {
    struct EncodedFrame {
        let data: Data
        let isKeyframe: Bool
        let pts: CMTime
        let formatDescription: CMFormatDescription
    }

    /// Invoked synchronously on the thread that calls `encode(_:pts:)` (the encoder
    /// drains via `CompleteFrames` before `encode` returns). A future streaming path
    /// that removes that drain will change this contract to a VideoToolbox queue.
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?

    init?(width: Int, height: Int, codec: QLCodec, fps: Int, bitrate: Int) {
        let codecType: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC
                                                           : kCMVideoCodecType_H264
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,   // using the block-based encode call
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        self.session = session

        let profile: CFString = (codec == .hevc) ? kVTProfileLevel_HEVC_Main_AutoLevel
                                                 : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber) // all-intra
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, sampleBuffer in
                guard let self, status == noErr, let sampleBuffer,
                      let frame = Self.makeFrame(from: sampleBuffer) else { return }
                self.onEncodedFrame?(frame)
            })
        // Flush pending frames immediately so the output handler fires before encode() returns.
        // This makes frame delivery synchronous and reliable in both realtime and test contexts.
        // All-intra semantics are preserved: MaxKeyFrameInterval=1 is set on the session;
        // CompleteFrames only drains already-submitted frames, it does not change encode settings.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private static func makeFrame(from sb: CMSampleBuffer) -> EncodedFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sb),
              let formatDescription = CMSampleBufferGetFormatDescription(sb) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let data = Data(bytes: pointer, count: length)

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        return EncodedFrame(data: data, isKeyframe: isKeyframe, pts: pts,
                            formatDescription: formatDescription)
    }
}
