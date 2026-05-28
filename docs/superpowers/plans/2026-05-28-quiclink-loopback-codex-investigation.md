# Codex investigation brief: QuicLink in-process loopback QUIC handshake never completes

Paste the prompt below into Codex (run it from the repo root). It is self-contained.

---

You are debugging a macOS Swift app, **NDIStream**, that uses Network.framework QUIC. We built a custom video transport called **QuicLink**. An in-process loopback integration test should start a QUIC sender (server), connect a QUIC receiver (client) to it on `127.0.0.1` with certificate pinning, and stream HEVC video frames. **The receiver's `NWConnectionGroup` never reaches `.ready`, so no frames flow.** Find out why and make the test pass reliably.

## Build / repro

- This is an **XcodeGen** project: `project.yml` is the source of truth; `NDIStream.xcodeproj` is gitignored and regenerated with `xcodegen generate`. Do NOT commit `NDIStream.xcodeproj`.
- The repo directory path **ends with a trailing space** — always quote paths.
- Apple Silicon, macOS 13+, hardware HEVC available.
- The repro test is currently skipped. Un-skip it by deleting the `throw XCTSkip(...)` line near the top of `testLoopbackVideoEndToEnd` in `Tests/QuicLink/QuicLinkLoopbackTests.swift`, then:
  ```bash
  xcodegen generate
  xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -only-testing:NDIStreamTests/QuicLinkLoopbackTests
  ```

## The single most important clue

`Tests/Spikes/QuicLoopbackSpikeTests.swift::testPinnedHandshakeAndTwoConcurrentStreams` **passes reliably**. It does essentially the same thing the broken code does: an `NWListener` QUIC server with a self-signed identity, an `NWConnectionGroup` client over `NWMultiplexGroup(to: 127.0.0.1:port)` with a pinning `sec_protocol_options_set_verify_block`, then opens streams via `NWConnection(from: group)`. **The bug is almost certainly a subtle difference between that working spike and the QuicLink classes.** Diff them line-by-line; consider making the receiver's client `NWParameters` byte-identical to the spike's `clientQUICOptions`, confirm it connects, then re-introduce QuicLink's differences one at a time until it breaks.

## Files

- `Sources/QuicLink/QuicLinkReceiver.swift` — the broken client (NWConnectionGroup, request/reply "pull pool", JitterBuffer, decode).
- `Sources/QuicLink/QuicLinkSender.swift` — the server. NOTE the documented finding: a QUIC **server cannot open streams to the client** in Network.framework (`NWConnection(from:)` on the listener side fails), so QuicLink uses a client-pull / server-reply model. Keep that model.
- `Sources/QuicLink/QuicTLS.swift` — `clientOptions(alpn:pinSHA256:)` (verify block) and `loadOrCreate()` (a self-signed identity persisted to Application Support, shared by sender and receiver).
- `Tests/Spikes/QuicLoopbackSpikeTests.swift` — the WORKING reference handshake.
- `Tests/QuicLink/QuicLinkLoopbackTests.swift` — the skipped integration test (the repro / the gate).

## Observed symptom (precise)

- The receiver's `group.stateUpdateHandler` only ever fires once, with `.cancelled` (at teardown). It never logs `.preparing` / `.waiting` / `.ready`.
- Console shows a loopback socket-flow being attempted and failing:
  `nw_endpoint_flow_failed_with_error [C1 127.0.0.1:0 in_progress socket-flow (satisfied (Path is satisfied), interface: lo0)] already failing, returning`

## Already tried — do NOT just repeat these

1. **Endpoint host (a real bug, already fixed):** the receiver built `NWEndpoint.Host(<String variable>)`, which produces a DNS `.name` endpoint even for `"127.0.0.1"` and never connected (no socket-flow at all). It now parses an `IPv4Address`/`IPv6Address` literal explicitly. After this fix it DOES attempt the lo0 socket-flow (above) — but the flow still fails. Keep this fix.
2. **`requiredInterfaceType = .loopback`:** an earlier version set this; it was removed. With it (and before the host fix) the group reached `.ready` ~1/3 of runs after a transient `waiting(Network is down)`. The combination of `.loopback` **together with** the IP-literal endpoint is UNTESTED — try it.
3. **Bonjour:** disabling the listener's Bonjour `service` advertisement (env `QUICLINK_NO_BONJOUR=1`, already set in the test) made no difference.
4. **Verify block:** `QuicTLS.clientOptions`' verify block is correct (calls `complete(...)` on every path; matches the spike).

## Hypotheses worth checking

- Does `NWConnectionGroup` need the first `NWConnection(from: group)` opened to drive the QUIC handshake to `.ready`? (The receiver waits for `.ready` before opening streams; the spike also waits for `.ready` first and reaches it — so probably not, but confirm by opening a stream immediately.)
- **Queue differences:** the spike runs listener + client on one `DispatchQueue`; the receiver uses separate `netQueue`/`decodeQueue`. Could starting the group on a queue that's busy/blocked stall its state callbacks? Try starting the group on a fresh dedicated queue or `.main`.
- **Shared persisted identity:** sender and receiver both call `QuicTLS.loadOrCreate()` → the SAME self-signed cert/key. The spike uses a fresh per-run identity. Unlikely to matter (client doesn't present a cert), but rule it out.
- **Server/listener parity:** compare `QuicLinkSender`'s `NWListener` parameters to the spike's `serverQUICOptions` exactly.
- **Fallback experiment:** try a plain `NWConnection` (single bidirectional stream) to the listener instead of `NWConnectionGroup`, to isolate whether the connection *group* is the problem.

## Goal / done criteria

- `testLoopbackVideoEndToEnd` passes **reliably** (run it ~5× — it must not be flaky), receiver decodes ≥3 frames at 320×240.
- Keep the client-pull / server-reply architecture and the drop-don't-stall `JitterBuffer`.
- Remove the `throw XCTSkip(...)` line when it passes.
- Do not break the other ~18 tests in the suite (`xcodebuild test ... -scheme NDIStream`).
- Report the actual root cause (the specific difference from the spike) in your summary.
