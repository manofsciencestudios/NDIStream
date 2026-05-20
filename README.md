<p align="center">
  <img src="icon.png" width="160" alt="NDIStream icon" />
</p>

# NDIStream

Dead-simple macOS app for sending and receiving [NDI](https://ndi.video/) video on the local network.

## Download

Grab the latest universal `.app` from [Releases](https://github.com/mikecerisano/NDIStream/releases). Unzip and drag into Applications (or run from anywhere). First launch: right-click → Open to bypass the unidentified-developer warning.

Built because every other Mac NDI tool is either paid, part of NewTek's bloated NDI Tools suite, or both. This is one window for sending your camera, one window for receiving a source, and a record button on each. That's it.

## Features

- **Sender** — broadcast any built-in or USB camera as an NDI source.
  - Quality preset (Native / 720p / 540p), frame rate (30 / 60), smooth-pacing toggle.
  - UYVY pixel format end-to-end, async send — minimal CPU on Intel Macs.
- **Receiver** — discover any NDI source on the LAN and view it in a resizable, letterboxed window.
- **Recording** — independent H.264 .mov recording on each window. Files land in `~/Movies/NDIStream/` with timestamped names. No save dialogs, one tap to start, one to stop.
- **Window menu** — both windows are independently openable/closeable.

## Requirements

- macOS 13 or later
- [NDI SDK for Apple](https://ndi.video/) installed at `/Library/NDI SDK for Apple/`
- [XcodeGen](https://github.com/yonik107/XcodeGen) (`brew install xcodegen`) — for project generation
- Xcode 15+

## Build

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -configuration Release \
    -destination 'generic/platform=macOS' ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build
```

Or open `NDIStream.xcodeproj` in Xcode and hit Run.

The built `.app` is a universal binary (x86_64 + arm64), ad-hoc signed, ~30 MB. `libndi.dylib` is bundled into `Contents/Frameworks/` so the app runs on any Mac without the user installing the NDI SDK.

## Use

### Sender

1. Launch — Sender window opens by default.
2. Pick a camera, set NDI source name, hit **Start Broadcasting**.
3. Hit the red circle to start a recording; hit it again to stop. The folder icon opens `~/Movies/NDIStream/`.

### Receiver

1. **Window menu → NDIStream — Receiver** to open it.
2. Pick a discovered source from the dropdown, hit **Connect**.
3. Record button works the same way.

## Notes

- Not sandboxed (NDI uses mDNS/UDP multicast and needs raw network access).
- Hardened runtime + library validation disabled (so the bundled libndi.dylib loads under ad-hoc signing).
- No audio. Video only.

## License

MIT.
