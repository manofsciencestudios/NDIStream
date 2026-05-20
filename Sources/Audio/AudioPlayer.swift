import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var currentFormat: AVAudioFormat?
    private var isStarted = false
    private var muted = true

    init() {
        engine.attach(player)
    }

    func setMuted(_ m: Bool) {
        lock.lock()
        let wasMuted = muted
        muted = m
        let started = isStarted
        lock.unlock()
        guard wasMuted != m else { return }
        if m {
            player.pause()
            DebugLog.write("audio player muted")
        } else if started {
            player.play()
            DebugLog.write("audio player unmuted (engine running)")
        }
    }

    func schedule(samples: UnsafePointer<Float>,
                  sampleRate: Int32,
                  channels: Int32,
                  samplesPerChannel: Int32,
                  channelStrideBytes: Int32) {
        guard channels > 0, samplesPerChannel > 0, sampleRate > 0 else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else { return }

        lock.lock()
        let formatChanged = currentFormat == nil
            || currentFormat?.sampleRate != format.sampleRate
            || currentFormat?.channelCount != format.channelCount
        let m = muted
        lock.unlock()

        if formatChanged {
            setupEngine(format: format)
        }

        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samplesPerChannel)) else { return }
        buf.frameLength = AVAudioFrameCount(samplesPerChannel)

        guard let chData = buf.floatChannelData else { return }
        let strideFloats = Int(channelStrideBytes) / MemoryLayout<Float>.stride
        let bytesPerChannel = Int(samplesPerChannel) * MemoryLayout<Float>.stride
        for ch in 0..<Int(channels) {
            let src = samples.advanced(by: ch * strideFloats)
            memcpy(chData[ch], src, bytesPerChannel)
        }

        if !m {
            player.scheduleBuffer(buf, completionHandler: nil)
            lock.lock()
            let started = isStarted
            lock.unlock()
            if started, !player.isPlaying {
                player.play()
            }
        }
    }

    func stop() {
        lock.lock()
        let started = isStarted
        isStarted = false
        currentFormat = nil
        lock.unlock()
        if started {
            player.stop()
            engine.stop()
            DebugLog.write("audio player stopped")
        }
    }

    private func setupEngine(format: AVAudioFormat) {
        lock.lock()
        let started = isStarted
        lock.unlock()
        if started {
            player.stop()
            engine.stop()
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            lock.lock()
            isStarted = true
            currentFormat = format
            let m = muted
            lock.unlock()
            if !m { player.play() }
            DebugLog.write("audio engine started sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
        } catch {
            DebugLog.write("ERROR audio engine start failed: \(error.localizedDescription)")
            lock.lock()
            isStarted = false
            currentFormat = nil
            lock.unlock()
        }
    }
}
