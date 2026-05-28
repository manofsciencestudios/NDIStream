/// A small, pure jitter buffer that embodies the project's #1 principle:
/// **drop, never stall** — a missing or late frame must never block later frames.
///
/// Callers must serialize all access (e.g., drive from a single DispatchQueue).
/// Thread safety is intentionally NOT provided here; the receiver owns the queue.
final class JitterBuffer {
    private let maxDepth: Int
    /// Packets kept sorted ascending by ptsNanos at all times.
    private var heap: [VideoPacket] = []

    var count: Int { heap.count }

    init(maxDepth: Int) {
        self.maxDepth = maxDepth
    }

    /// Insert a packet in ptsNanos order. Duplicate pts values are silently ignored.
    func push(_ packet: VideoPacket) {
        // Ignore duplicate pts.
        if heap.contains(where: { $0.ptsNanos == packet.ptsNanos }) { return }

        // Binary search for insertion point to keep heap sorted.
        var lo = 0, hi = heap.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if heap[mid].ptsNanos < packet.ptsNanos {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        heap.insert(packet, at: lo)
    }

    /// Returns the smallest-pts packet only once the buffer has filled to maxDepth,
    /// else nil. Releasing the front regardless of gaps means a missing earlier
    /// frame can never stall later frames.
    func pop() -> VideoPacket? {
        guard heap.count >= maxDepth else { return nil }
        return heap.removeFirst()
    }

    /// Flush everything remaining in ptsNanos order (used on stop/flush).
    func drain() -> [VideoPacket] {
        defer { heap.removeAll() }
        return heap
    }
}
