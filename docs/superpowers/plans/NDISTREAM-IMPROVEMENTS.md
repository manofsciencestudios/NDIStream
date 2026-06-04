# NDIStream Improvements — Backlog

Running list of improvements identified during use. Each entry is a candidate for its own plan when picked up.

---

## 1. Refine the Slate section

**What:** Make the Slate UI more user-friendly with structured fields instead of a single free-text string.

**Fields to add:**
- Season
- Scene
- Take
- Roll #

**Why:** The current single `slate` text field forces operators to encode all metadata into one string (e.g. `S14T3`). Production workflows track these as separate dimensions and want them separately filterable in the recorded filename + downstream tools.

**Touches:** Sender + Receiver windows (both have a slate field), `Recorder.swift` (filename construction), `BroadcastController` + `ReceiverModel` persistence (`receiverSlate` / sender slate UserDefaults keys).

**Open questions:**
- Filename format when fields are combined? (e.g. `S14_SC03_T2_R001-…`)
- Are all four fields required, or some optional?
- Should the existing single `slate` field be migrated, or replaced?

---

## 2. Rename "NDI source name" → "Stream Source Name"

**What:** Update the Sender window label from `"NDI source name"` to `"Stream Source Name"` — transport-agnostic since the app now carries NDI, QuicLink, and WarpStream.

**Touches:** `Sources/App/NDIStreamApp.swift` (the `sectionLabel("NDI source name")` call in `buildSenderWindow`). Also audit for stale "NDI" wording elsewhere in operator-facing strings — placeholders, tooltips, status messages — and rename consistently.

**Why:** The same field is used to advertise the broadcast name regardless of selected transport. Continuing to call it "NDI source name" misleads operators who pick WarpStream or QuicLink.

---

## 3. Audit the Advanced section against all three transports

**What:** Verify each control in the Sender's Advanced disclosure section is meaningful (and applied) for NDI, QuicLink, AND WarpStream — hide / disable / re-label per transport as needed.

**Controls to audit:**
- **Quality** preset — should map to bitrate/encoder settings on every transport. Confirm QuicLink and WarpStream actually consume `senderController.quality`.
- **Frame rate** (30/60) — capture-side, transport-agnostic — should already work, verify.
- **Format** (pixel format) — capture-side, transport-agnostic — verify.
- **Smooth pacing (+1 frame latency)** — transport-agnostic frame pacing, verify it applies to QuicLink/WarpStream sender paths.
- **Lowest latency (unicast UDP, no RUDP; relaunch to apply)** — *NDI-specific wording* ("RUDP" is NDI's Reliable UDP). For QuicLink it makes no sense (always QUIC over UDP); for WarpStream it depends on the SDK. Should be hidden or relabeled when transport ≠ `.ndi`.

**Why:** Adding `.quicLink` and `.warpStream` to the transport picker exposes operators to controls that may silently no-op (or carry misleading NDI-specific copy) on the new transports.

**Suggested approach:** Each advanced control gets a "supports transport X" check; `updateSenderUI()` toggles `isHidden` per the active transport. Use the same pattern already in place for the WarpStream room-code container.

---

## 4. Add a Record hotkey

**What:** Bind a keyboard shortcut to the Record button. Verified there is no existing `keyEquivalent` on `senderRecordButton` / `receiverRecordButton` and no menu item invokes `toggleSenderRecording` / `toggleReceiverRecording`.

**Touches:** `Sources/App/NDIStreamApp.swift` — `installMenu()` (likely add to the View menu next to the stats toggles, or a new Record menu) plus the existing `toggleSenderRecording` / `toggleReceiverRecording` actions.

**Suggested shape:** Mirror the stats overlay pattern — ⌘R toggles the focused window's recorder, OR explicit ⌘R for sender + ⇧⌘R for receiver. The latter is more discoverable but consumes more shortcuts; the former is cleaner if "focused window" semantics are reliable.

**Open question:** ⌘R is also macOS's standard "Reload" — possibly fine in this app (no reloadable views), but worth confirming no conflict before claiming it. Alternative: ⌘. or function keys (F8, common in DAWs/NLEs for "punch in").

---

## 5. Missing Edit menu — ⌘V (and ⌘C, ⌘X) don't work in any text field

**What:** No Edit menu exists in `installMenu()` (verified — only App, Window, View menus). On macOS, the standard text-editing shortcuts (⌘C / ⌘V / ⌘X / ⌘A) only route to the first-responder text field when there's a menu item with the corresponding `paste:` / `copy:` / `cut:` / `selectAll:` selector. Without that menu, the shortcuts silently no-op.

**Symptom user hit:** ⌘V doesn't paste a room code into the Receiver's "Or join by code" field. The same bug affects every text field in the app — sender source name, slates, etc.

**Touches:** `Sources/App/NDIStreamApp.swift` — `installMenu()`. Add a standard Edit menu between Window and View.

**Suggested structure:**
```
Edit
  Undo                ⌘Z
  Redo            ⇧⌘Z
  ---
  Cut                  ⌘X      (action: cut:)
  Copy                ⌘C      (action: copy:)
  Paste                ⌘V      (action: paste:)
  Select All       ⌘A      (action: selectAll:)
```

Use `nil` target so AppKit's responder chain delivers to the first-responder text field automatically.

---

## 6. Room codes need to vary or be user-adjustable

**What:** The WarpStream sender currently hardcodes `roomCode = "WS-STUB"` (in `WarpStreamVideoSender.init`). Two senders broadcasting in the same room would collide. Either each sender generates a unique code, or the operator picks one up front.

**Why:** Even ignoring the stub-vs-real-SDK question, a code is the identifier a receiver types in to find this specific sender. A fixed string is fine for stub smoke testing but defeats the entire room-code mechanism in production.

**Two design directions (pick one):**

1. **Auto-generated:** Sender picks a short random code (e.g. 6-char alphanum) at broadcast start, displays it in the Sender Room Code panel for the operator to read out to the receiver side. Each new broadcast = new code.
2. **Operator-entered:** Add a text field on the Sender window where the operator types the code they want before clicking Start Broadcasting (with auto-generated default if left blank). Lets sender + receiver agree on a code ahead of time over a side channel.

**Recommendation:** Option 1 with a "Regenerate" button — auto-generated by default, but the operator can roll a new one if needed. The Copy button is already there for sharing.

**Touches:** `Sources/Transport/WarpStreamTransport.swift` (stub init), `Sources/Model/BroadcastController.swift` (room code lifecycle when broadcast starts/stops), `Sources/App/NDIStreamApp.swift` (regenerate button if going that route). Also: when the real WarpStream SDK lands, the code may come from the SDK rather than client-side — design the seam so either source works.

---

## 7. Upstream / downstream key overlays (Zoom / Discord / FaceTime simulation)

**What:** Composite user-supplied image/video overlays onto the outgoing stream so the broadcast looks like it's coming from a consumer app (Zoom call chrome, Discord/Streamlabs frame, FaceTime UI, etc.). Production use: deliver a "looks-like-Zoom" feed without actually running Zoom — common when a script calls for a video-call moment.

**Broadcast model:**
- **Upstream Key (USK):** Composited before downstream effects — sits inside the "scene." E.g., a fake Discord chat panel as part of the framed image.
- **Downstream Key (DSK):** Composited last, on top of everything, including recordings and any other DSK. E.g., the Zoom toolbar/banner that should always be on top.

Both should be user-definable.

**Requirements:**
- Multiple slots per type (e.g. USK 1–4, DSK 1–4) so a single broadcast can stack a fake call window + name tag + watermark.
- Each slot accepts: image (PNG with alpha) at minimum; video with alpha (ProRes 4444 / HEVC alpha) ideally for animated chrome.
- Per-slot: position, scale, opacity, enable/disable, fit mode (stretch / contain / cover).
- A "preset" concept so operators save the "Zoom" preset, the "Discord" preset, etc., and switch between them per broadcast.
- Live preview in the Sender window — the operator must see what the receiver will see.

**Pipeline placement:**
- Composite happens AFTER camera capture, BEFORE per-transport encode + send.
- Recording captures the composited frame (operator sees keys on the recording too).
- All three transports send the composited frame — keys are transport-agnostic.

**Touches:** `Sources/Capture/` (insert a compositor stage), new `Sources/Compositor/` module (CoreImage or Metal — Metal preferred for 4K60), `Sources/App/NDIStreamApp.swift` (Keys panel UI on Sender window), new persistence for preset library, asset file storage.

**Open questions:**
- Performance target: 4K60 with N overlays — GPU-only or fallback to CoreImage?
- Where do preset assets live? `~/Library/Application Support/NDIStream/Keys/` plus optional shared library on a network drive?
- Should DSK render on the LOCAL preview only, on the broadcast, or both? (Probably both — match what the receiver gets.)
- Chroma key support too, or strictly alpha-channel-based for now?

**Scope note:** This is a large feature — probably its own multi-phase plan. Worth a brainstorm before writing.

---

## 8. Receiver borderless fullscreen mode

**What:** A receiver mode that takes up the entire screen with the incoming video and ZERO chrome — no title bar, no traffic lights, no bars. Distinct from macOS's standard green-button fullscreen (which creates a new Space, animates the transition, and keeps a hidden title bar).

**Why:** Production setups (video village, multiview monitors, on-set client monitors) want the receiver as a pure picture-output surface that can be driven onto a display without operator UI bleeding through. The current `receiverDidEnterFullScreen` handler hides the bars but still uses Spaces-based fullscreen — wrong shape for a fixed monitor wall.

**Behavior:**
- Window becomes borderless (`.borderless` style mask), covers the entire screen of the chosen display, level above normal windows.
- Video image stretches to fill the display (respect aspect via letterbox/pillarbox; configurable scale mode: fit / fill / stretch).
- Black background.
- Hotkey to enter/exit (suggest F11 or ⌘⇧F to avoid collision with macOS's ⌘^F native fullscreen). Esc exits.
- Multi-display: operator picks WHICH display — pulldown or follow-cursor at entry time.
- Stays on top of normal Spaces (no transition animation, no separate Space).

**Touches:** `Sources/App/NDIStreamApp.swift` — new `enterBorderlessFullscreen()` / `exitBorderlessFullscreen()` methods, separate from the existing standard-fullscreen handlers. Add View menu entries. Possibly a small `ReceiverFullscreenWindow` subclass of NSWindow so the window-level state is encapsulated.

**Open questions:**
- Keep the existing macOS-native fullscreen too, or replace it? (Suggest: keep both — different operators want different things.)
- Should the receiver continue ticking the recorder + audio in borderless mode? (Yes — same as native fullscreen.)
- How to handle the mouse cursor — auto-hide after N seconds of no movement?
- When in borderless on Display 2, can the operator still interact with the Sender window on Display 1? (Should be yes — borderless ≠ exclusive.)

---

## 9. Camera input transform — resize, translate, crop

**What:** Per-camera-source transform controls on the Sender side. Operator can scale, position, and crop the incoming camera image before it's encoded and sent. Standard "Edit Transform" controls like OBS / vMix / Wirecast.

**Why:** Common production needs the current Sender can't address:
- Crop out a light stand, tripod, or off-frame element.
- Reframe a wide-angle camera (e.g. iPhone Continuity Camera shows too much room).
- Pan-and-scan to track a presenter without moving the physical camera.
- Fit a 16:9 camera into a 4:3 (or 9:16 vertical) output by cropping rather than stretching.

**Controls:**
- **Scale** (X/Y, link aspect by default): 0.1× → 4× of the source.
- **Translate** (X/Y in pixels or % of frame).
- **Crop** (top / bottom / left / right insets) — applied BEFORE scale + translate so cropped pixels are gone.
- **Rotation** (0° / 90° / 180° / 270°; arbitrary angle nice-to-have for tilted Continuity Camera shots).
- **Reset** button.
- **Output aspect** lock — when output is forced 16:9 / 9:16 / 1:1, crop affordances snap to the locked aspect so the operator can't accidentally produce off-spec frames.

**UI:**
- Live preview shows the transformed result (what the receiver will see), with a ghosted overlay of the cropped-out region so the operator understands what they're losing.
- Drag-to-position and drag-handles on the preview for direct manipulation, with numeric fields for precision.
- Persist per-camera so switching cameras restores the per-camera transform.

**Pipeline placement:**
- Apply AFTER camera capture, BEFORE the upstream/downstream key compositor (item #7), BEFORE encode + send. Recording captures the transformed frame.
- All three transports send the transformed frame — transform is transport-agnostic.

**Touches:** `Sources/Capture/` (insert a transform stage in front of the encoder), `Sources/App/NDIStreamApp.swift` (Transform panel UI, probably alongside Advanced — could be a new disclosure section), new persistence for per-camera transforms.

**Open questions:**
- Performance: do transform + keys (item #7) combine into a single Metal pass, or two? (One pass preferred for 4K60.)
- Save transforms per-camera-by-identifier (so plugging back in restores) — what's the identifier? AVCaptureDevice.uniqueID is stable, use that.
- Snap presets (e.g. "9:16 vertical center crop") — surface as a quick-pick menu?
- Should the transform also apply to the LOCAL preview thumbnail, or stay full-camera in preview? (Probably: preview shows the OUTPUT framing so the operator sees what's broadcast.)

**Scope note:** Naturally pairs with #7 — both want a Metal compositing stage. If #7 lands first, this slots into the same pipeline. Worth brainstorming the two together.

---

## 10. Faulty-connection effects + dual clean/effected recording

**What:** A creative effects stage that simulates a degraded or failing network connection on the outgoing video — and the ability to record BOTH the clean source and the effected output at the same time.

**Why:** Production use — music videos, found-footage horror, "hacker movie" aesthetics, the "Zoom call that's clearly buffering" comedic beat. Lets the director get the look without actually crippling the network. Recording both means the colorist/editor has a clean plate to fall back on if the effect needs to be re-timed or replaced later.

**Effect library (mix-and-match, each with an intensity slider):**
- **Frame freeze/stutter** — random N-frame holds, pattern-able.
- **Pixelation/blocking** — simulate aggressive H.264 compression chunks (per-block-of-pixels mosaic).
- **Tearing** — horizontal frame-half offsets (looks like NDI under packet loss).
- **Datamosh** — bleed previous-frame pixels through I-frame boundaries (the classic "transit through walls" look).
- **Chroma bleed / NTSC** — separate luma/chroma channels, smear chroma horizontally.
- **Scan lines / CRT** — alternating dark rows, optional barrel curvature for full CRT.
- **VHS** — chroma noise, head-switching noise band at bottom, vertical jitter, slight desaturation.
- **Bandwidth starve** — automatic "low quality call" preset combining heavy blocking + low fps stutter.
- **Random glitch** — meta-effect: randomly toggle other effects on for 0.1–1.0s bursts at operator-set frequency.

**Audio companion (optional second pass):**
- Cracks, clicks, dropouts, codec-artifact (heavily compressed AAC-style), low-pass-then-restore. Operator can drive audio glitches in sync with video glitches or independently.

**Dual recording:**
- Sender records to TWO files simultaneously:
  - `Clean-<slate>.mov` — capture output BEFORE the effects stage.
  - `Effected-<slate>.mov` — the post-effect output that's actually sent.
- One or the other can be disabled if disk pressure matters.
- Receiver records whatever it receives (already does this) — that's the effected stream a third time, on the receive side, which is useful for proving "this is what arrived."

**Pipeline placement:**
- Effects stage sits AFTER camera + transform (#9), AFTER USK keys (#7), BEFORE encode + send. The pipeline order, top-to-bottom, becomes:
  1. Camera capture
  2. Transform (resize / translate / crop) — #9
  3. Upstream keys — #7
  4. Faulty-connection effects — this item
  5. Encode + send (per transport)
  6. Downstream keys overlaid on outgoing stream — #7
- Clean recording branches off between step 3 and step 4 (so it includes transform + USK but NOT the effects).

**Touches:** New `Sources/Effects/` module (Metal shaders for the heavy ones), `Sources/Recording/Recorder.swift` (dual-writer support — currently single-writer), `Sources/App/NDIStreamApp.swift` (Effects panel UI, recording mode selector).

**UI shape:**
- Dedicated "Effects" disclosure panel on the Sender window.
- Each effect: enable checkbox + intensity slider + preset thumbnails.
- "Effect preset" save/load (e.g. "VHS heavy," "Zoom died," "Found footage").
- A big "BYPASS" button that disables ALL effects without losing their settings — for quick A/B comparisons.

**Open questions:**
- Audio glitches: same panel or separate? (Probably same — they pair for the look.)
- Operator vs scripted: should effects also accept a timeline / cue list ("kick in 5 seconds after the slate")? (Probably no for v1 — fader-style live control is the production reality.)
- GPU cost — same Metal pass as #7 and #9, or its own pass? (Combined preferred if shader complexity allows.)

**Scope note:** This is its own multi-phase plan. Effects library + dual recording are two separable phases — recording can land first (it has standalone value: record clean source while sending out a key-composited frame).

---

## 11. Unified send + receive window — video-call mode

**What:** A single-window UI that shows the outgoing camera preview AND the incoming receiver feed at the same time, like Zoom / FaceTime / Discord. Currently the app is two separate windows (`senderWindow` + `receiverWindow`); add a third "Call" window mode that combines them.

**Why:** The app is being used to simulate video calls. The two-window split is correct for **one-sided** workflows — sending to a remote receiver you can't see, OR receiving from a remote sender you don't talk back to — those should stay as-is. The new mode is for the **two-sided** workflow where you simulate both ends of a call locally and need to glance between own-image and remote-image. Currently that two-sided workflow forces the operator to manage two windows, which is clunky and uses more screen real estate.

**Layouts (operator picks one):**
- **Picture-in-picture (default):** Big receiver image fills the window; small sender preview tile in a corner (Zoom-style). Operator can drag the PIP tile between corners.
- **Side-by-side:** Sender preview left, receiver right (or top/bottom), 50/50. Good for performance review or off-set monitor wall.
- **Speaker-active:** Big preview is whichever side has detected audio (sender mic vs received audio), with the other as PIP. Mirrors FaceTime "speaker view."
- **Grid:** 2-up equal tiles — same as side-by-side but the framing rule is symmetrical (useful when both sides are reading lines).

**Controls:**
- Single consolidated control strip — broadcast on/off, connect/disconnect, transport pickers for both, record (independent toggles for sender + receiver recording), audio mute, slate.
- Layout switcher in a corner (segmented control: PIP / Side-by-side / Speaker / Grid).
- The two existing windows remain available — operator picks "Call window" from the Window menu OR uses the existing pair. Don't force one over the other.

**Window menu becomes:**
```
Window
  Sender              ⌘1
  Receiver           ⌘2
  Call                  ⌘3       ← new
```

**Touches:**
- New `Sources/App/CallWindowController.swift` (or extend the AppDelegate) — builds the unified layout reusing existing `PreviewNSView` + `DisplayLayerHostNSView`.
- `Sources/App/NDIStreamApp.swift` — add the menu item + window state, ensure `senderController` and `receiverModel` can drive both their dedicated windows AND the unified one simultaneously (Combine subscriptions to support multiple observers).
- Reuse existing `updateSenderUI` / `updateReceiverUI` — they need to also update the call-window controls when active.

**Open questions:**
- Audio: do BOTH the receiver's incoming audio AND the local mic-monitoring play, or does the call window mute one to avoid feedback? (Default: receiver audio plays, local mic does NOT route to speakers — same as current receiver-window behavior.)
- Mirror the local PIP horizontally (selfie-style) so the operator sees their movement correctly? Configurable per layout.
- Multi-display: when call window is on one display, can the dedicated sender/receiver windows still be open on others? (Yes — they're independent.)
- Recording the call window itself (screen capture of both feeds composited) — out of scope here; covered by NDIStream's existing per-side recording.

**Scope note:** Pure UI/composition work — no transport changes. Could be a single-phase plan once the layout decisions are settled (brainstorm first to pick a default layout + nail the audio rule).

---

## 12. Replace ‹ › arrows with dropdowns for camera + microphone selection

**What:** Replace the current prev/next arrow buttons for camera and microphone selection with an `NSPopUpButton` (dropdown) showing all available devices at once.

**Why:** Arrows force the operator to cycle through devices one-by-one to find the one they want. With 3+ cameras or mics (common on a Mac with built-in + external + iPhone Continuity Camera + capture card), arrows are slow and the operator has to mentally track "did I pass it?" A dropdown shows all options at once, makes the active selection visible at a glance, and is the standard macOS affordance for this pattern.

**Touches:** `Sources/App/NDIStreamApp.swift`:
- Replace `senderCameraPrevButton` / `senderCameraNextButton` + `cameraLabel` with a single `senderCameraDropdown: NSPopUpButton`.
- Replace `senderAudioPrevButton` / `senderAudioNextButton` + `senderAudioLabel` with a single `senderAudioDropdown: NSPopUpButton`.
- Update `updateSenderUI()` to rebuild the popup's items when `senderController.availableCameras` / `availableAudioDevices` changes, and select the current device.
- Wire up `previousCamera`/`nextCamera`/`previousAudioDevice`/`nextAudioDevice` actions to new dropdown-change actions (or keep the cycle actions accessible via menu items / hotkeys for fast-switching).

**Worth considering at the same time:**
- The Receiver window's source selection uses the same arrow pattern (`receiverSourcePrevButton` / `receiverSourceNextButton` + `receiverSourceLabel`). Same arguments apply when there are multiple sources on the LAN. Probably should be migrated to a dropdown in the same change for UI consistency — but call it out in the plan so it's a deliberate choice, not a stealth scope expansion.

**Open questions:**
- Keep the existing prev/next hotkeys (if any) for fast cycling? Useful when the operator's hands are on the keyboard mid-broadcast.
- When the active device disappears (camera unplugged), what does the dropdown show? Probably the device name + "(unavailable)" until it's re-selected.
- Dropdown sort order — alphabetical, or "built-in first, then external"? Match macOS System Settings convention (built-in first, external grouped).

---
