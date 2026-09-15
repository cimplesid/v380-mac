# OpenV380 — a fast, native macOS app for V380 / V380 Pro cameras

OpenV380 is a lightweight macOS menu-bar app for **V380** and **V380 Pro** IP cameras
(Macrovideo / `*.nvdvr.net` devices). One click gives you the **live feed**; another
gives you the **SD-card recordings** — with a real timeline, playback, fast scan, PTZ,
and the camera's light. No ads, no account login, no slow splash screen.

It talks to the camera the same way the official app does — over V380's cloud relay —
so it works **from anywhere with an internet connection**, not just on your home Wi-Fi.

> Not affiliated with, endorsed by, or connected to V380, Macrovideo, or any camera
> manufacturer. "V380" is used only to describe the cameras this app interoperates with.

## Features

- **Live view** in a floating, always-on-top window — open it with a click on the menu
  bar icon or the global shortcut **⌃⌥V**.
- **SD-card recordings** — a 24-hour timeline (motion / alarm / normal colour-coded),
  clip list, seek, and **1×–32×** playback (16×/32× scan by keyframes).
- **Digital zoom & pan** on both live and recordings — pinch or scroll to zoom, drag to
  pan, double-click to reset.
- **PTZ** (pan/tilt) with a press-and-hold d-pad, for cameras that have motors.
- **Camera light** (white LED / floodlight) toggle.
- **Mute / unmute** live audio (off by default); detects and silences undecodable audio.
- **Credentials stored in the macOS Keychain** — nothing is written to disk in plaintext,
  and video is never saved to disk (it streams into memory only).

## Requirements

- macOS 13 or later
- Swift toolchain (Xcode command-line tools) to build
- Your camera's **Device ID** and **device password** (shown in the V380 Pro app under the
  camera's name — this is the camera's own password, **not** your V380 account password)

## Build & install

```sh
./build-app.sh
```

This builds a release binary, wraps it in `OpenV380.app`, ad-hoc code-signs it, and copies
it to `~/Applications/OpenV380.app`. Launch it from there (it lives in the menu bar).

On first launch, enter your **Device ID** and **device password**. They're saved to the
Keychain; you never enter them again.

> If macOS blocks the first launch because it isn't notarized, right-click the app →
> **Open**, or allow it under **System Settings → Privacy & Security**.

## How it works

OpenV380 is a clean-room Swift reimplementation of the V380 (Macrovideo) TCP protocol.
Highlights, in case they help the next person:

- **Cloud relay:** a small signed HTTP request to V380's dispatch server returns a relay
  IP; the app then logs in and streams through it (device ID + device password only — no
  account needed).
- **Login:** command `1167`; newer firmware needs the header version byte `31`, the device
  ID as the username, and a specific password encoding. The app auto-probes and remembers
  what works, which sidesteps the common "wrong username" wall on new firmware.
- **Live video:** H.264/H.265, decoded with VideoToolbox via `AVSampleBufferDisplayLayer`.
  Frames on newer devices are AES-encrypted with a per-session key.
- **Recordings:** the "segment" search/playback protocol (`361`/`363`), including the cloud
  (MR-server) command layouts and the relay's `2000` keep-alive frames.
- **Controls:** PTZ, light, etc. are 16-byte control packets on the live stream socket.

### A note on audio

On the camera tested, recorded audio is encrypted silence (the camera stores no sound on
the SD card), and live audio is encrypted with a key that isn't the video key. OpenV380
plays audio when it can decode it and stays silent (rather than blasting static) when it
can't. Cracking live-audio encryption is an open item.

## Credits

Built on the reverse-engineering work of others, with thanks:

- [PyanSofyan/V380Decoder](https://github.com/PyanSofyan/V380Decoder)
- [prsyahmi/v380](https://github.com/prsyahmi/v380)
- [felipemarques/camera-v380decoder](https://github.com/felipemarques/camera-v380decoder)

## License

[MIT](LICENSE). Use at your own risk. This project accesses only cameras you own and
control, using your own credentials.
