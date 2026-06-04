import Foundation

/// Multi-component transport statistics for the NDI/QuicLink/WarpStream shootout.
///
/// Latency fields are milliseconds. `nil` means the transport can't measure that
/// component (e.g., NDI exposes only `endToEndLatencyMs`). `jitterBufferMs` is the
/// current jitter-buffer depth — a setting, not a latency — included separately so
/// it isn't summed by mistake.
struct TransportStats: Equatable {
    let bitrateKbps: Double
    let sendLatencyMs: Double?
    let wireLatencyMs: Double?
    let receiveLatencyMs: Double?
    let endToEndLatencyMs: Double?
    let jitterBufferMs: Double?
    let framesDropped: UInt64
    let cpuPercent: Double

    init(bitrateKbps: Double,
         sendLatencyMs: Double? = nil,
         wireLatencyMs: Double? = nil,
         receiveLatencyMs: Double? = nil,
         endToEndLatencyMs: Double? = nil,
         jitterBufferMs: Double? = nil,
         framesDropped: UInt64,
         cpuPercent: Double) {
        self.bitrateKbps = bitrateKbps
        self.sendLatencyMs = sendLatencyMs
        self.wireLatencyMs = wireLatencyMs
        self.receiveLatencyMs = receiveLatencyMs
        self.endToEndLatencyMs = endToEndLatencyMs
        self.jitterBufferMs = jitterBufferMs
        self.framesDropped = framesDropped
        self.cpuPercent = cpuPercent
    }
}
