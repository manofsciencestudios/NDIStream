import CoreMedia
import CoreVideo
import Foundation

/// Which transport carries video/audio. Persisted as a raw string in UserDefaults.
enum VideoTransportKind: String, CaseIterable {
    case ndi
    case quicLink
}

/// A discovered source the receiver can connect to, tagged by transport.
struct FoundSource: Equatable {
    let name: String
    let address: String
    let transport: VideoTransportKind
}

/// Sends camera frames + audio over some transport. Mirrors the NDISender surface.
protocol VideoSender: AnyObject {
    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32)
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32)
    func sendAudio(_ sampleBuffer: CMSampleBuffer)
    func stop()
}

/// Receives decoded frames + audio. Callbacks fire on a non-main (transport) thread;
/// the implementer is responsible for hopping to the main actor as needed.
protocol VideoReceiverDelegate: AnyObject {
    func videoReceiverDidReceive(sampleBuffer: CMSampleBuffer, width: Int32, height: Int32,
                                 frameRateN: Int32, frameRateD: Int32, fourCC: UInt32)
    func videoReceiverDidDisconnect()
    func videoReceiverDidStall(forSeconds seconds: Int)
    func videoReceiverDidResume()
    func videoReceiverDidReceiveAudio(samples: UnsafePointer<Float>, sampleRate: Int32,
                                      channels: Int32, samplesPerChannel: Int32,
                                      channelStrideBytes: Int32)
}

protocol VideoReceiver: AnyObject {
    var delegate: VideoReceiverDelegate? { get set }
    func stop()
}

/// Discovers sources on the network for one transport.
protocol SourceFinder: AnyObject {
    var onSourcesChanged: (([FoundSource]) -> Void)? { get set }
    func currentSources() -> [FoundSource]
    func stop()
}
