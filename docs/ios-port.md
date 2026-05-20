# NDIStream for iPad — Spec

**Status:** future work. Not started.

**Why:** On a film set, the off-camera scene partner needs to see the on-camera actor (for fake-Zoom gags, video village, eyelines, playback proxies). Today that's a second MacBook. An iPad on a c-stand or magic-arm replaces the laptop — smaller, lighter, silent, ~10hr battery, easier to mount.

**Scope:** **Receiver-only first.** Sender is deprioritized — the Mac has a better webcam, better networking, and no backgrounding restrictions. Maybe add sender later if we find a use case.

## Functional spec

Single-screen iPad app, landscape-first.

- **Top bar (compact, ~44 pt):**
  - Source picker — dropdown of discovered NDI sources
  - Connect / Disconnect button
  - Status text — "1920×1080 @ 30 • UYVY" or "Source offline"
  - Record button + timer + share-sheet trigger (replaces the macOS "Reveal in Finder" affordance — iOS has no concept of revealing in Finder)
- **Video area:** fills the rest of the screen. `AVSampleBufferDisplayLayer`. Black background. Letterboxed `.resizeAspect`.
- **Lock-screen behavior:** keep screen awake while connected (`UIApplication.shared.isIdleTimerDisabled = true`). Release when disconnected.

## Reused from macOS

Should port largely as-is:
- `NDIFinder.h/.mm`, `NDIReceiver.h/.mm`, `NDIRuntime.h/.mm` — Obj-C++ wrappers, no UIKit/AppKit deps
- `Recorder.swift` — AVAssetWriter is identical between platforms; only `recordingsDirectory()` changes (use `.documentDirectory` instead of `.moviesDirectory`)
- `ReceiverModel.swift` — minor tweaks (no AVSampleBufferDisplayLayer differences worth noting)

Replacements:
- `DisplayLayerHostView` — `NSViewRepresentable` → `UIViewRepresentable`
- `ReceiverView` — drop the resizable-window machinery, target single-screen iPad layout
- No `NDIStreamApp` Window scenes — just a `WindowGroup { ReceiverView() }`

## iOS-specific work

- **Local network permission.** `NSLocalNetworkUsageDescription` in Info.plist explaining what NDI does. Plus `NSBonjourServices` listing NDI's service types: `_ndi._tcp`, `_ndi-discovery._tcp` (verify against current NDI SDK docs at build time). Without these, discovery returns nothing silently.
- **NDI iOS SDK.** Static framework at `/Library/NDI SDK for Apple/lib/iOS/` — link statically, not dylib like macOS. No bundling/rpath dance needed but the build settings differ.
- **No backgrounding.** App goes to background → network drops. Acceptable for the use case (it stays foreground on a stand) but document it. Don't fight it with audio-mode tricks; Apple review will reject.
- **Files access for recordings.** Write to `.documentDirectory`, expose via `UIDocumentPickerViewController` or share sheet. Optionally enable `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so recordings show up in the Files app under "NDIStream."
- **Orientation.** Landscape-only on iPad. Portrait makes no sense for a 16:9 video display.
- **Stage Manager / Split View.** Allow but don't optimize for it. Single full-screen view is the use case.

## Distribution

Three options, in order of friction:

1. **TestFlight** — best for "tools we use on set, share with crew." Up to 100 internal testers, 90-day install lifetime per build. No App Store review for internal testing. **Default choice.**
2. **App Store** — public-facing, requires review. Probably approvable (Vizrt's NDI HX Camera ships on the Store) but adds review friction and ongoing maintenance.
3. **Ad-hoc / dev-team install** — sideload via Xcode for specific devices. Fine for prototyping, painful for distribution.

## Open questions

- Does NDI's iOS SDK still ship as a static lib, or has it gone XCFramework? (Check SDK version at build time.)
- Multi-source view — would a 2×2 grid of small previews be useful (multi-cam village)? Probably yes, but separate spec.
- Audio receive — current macOS app skips audio entirely. For an iPad on set, getting audio out of a wired headphone jack (via USB-C adapter) for the off-camera actor would be a real win. Separate small task.

## Estimated effort

~Half a day of focused work for a first runnable build, plus another half for polish (recording UX, share sheet, edge cases). The Obj-C++ NDI wrappers should port without changes. The Swift code is mostly subtractive (remove macOS window machinery, replace AppKit with UIKit equivalents).

## Out of scope

- iPhone — screen is too small to be useful as a scene-partner display
- Sender on iOS — Mac does it better; revisit only if a specific use case appears
- PTZ controls, audio mixing, multi-source compositing, recording-to-Photos
