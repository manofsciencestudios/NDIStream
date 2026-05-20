import AppKit
import AVFoundation
import SwiftUI

struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.attach(session: session)
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.attach(session: session)
    }
}

final class PreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func attach(session: AVCaptureSession) {
        if let existing = previewLayer, existing.session === session { return }
        previewLayer?.removeFromSuperlayer()
        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspect
        pl.frame = bounds
        layer?.addSublayer(pl)
        previewLayer = pl
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
