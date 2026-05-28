import CoreVideo
import Foundation

enum PixelBufferFactory {
    /// Creates a BGRA pixel buffer filled with one opaque color.
    static func solid(width: Int, height: Int,
                      b: UInt8 = 40, g: UInt8 = 120, r: UInt8 = 200) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base + y * rowBytes
            for x in 0..<width {
                let px = row + x * 4
                px[0] = b; px[1] = g; px[2] = r; px[3] = 255
            }
        }
        return buffer
    }
}
