import AppKit
import AVFoundation

final class DisplayLayerHostNSView: NSView {
    private var attachedLayer: AVSampleBufferDisplayLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        if attachedLayer === displayLayer { return }
        attachedLayer?.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        attachedLayer = displayLayer
    }

    override func layout() {
        super.layout()
        attachedLayer?.frame = bounds
    }
}
