# Jellyfin Desktop for iPadOS 15+ (Tuned for iPad Air 2 / iPadOS 15.8.8)

A native iOS/iPadOS port of the [`jellyfin/jellyfin-desktop`](https://github.com/jellyfin/jellyfin-desktop) dual-layer architecture, specifically tailored for **iPad Air 2 (Apple A8X, 2 GB RAM, iPadOS 15.8.8)** as well as newer iOS/iPadOS 15.0+ devices.

## Architecture

Upstream `jellyfin-desktop` relies on `Qt6 WebEngine` (Chromium), which is not available on iOS/iPadOS, paired with `QWebChannel` and `libmpv`. This port reproduces the same dual-layer design using native iOS 15 frameworks:

1. **Bottom Native Video Layer (`MobileVLCKit 3.6.0` / `libVLC`)**:
   - **Direct Play** without server transcoding for **MKV, MP4, WebM, and AVI** containers;
   - Hardware-accelerated **H.264 decoding via Apple VideoToolbox** on the A8X SoC alongside multi-threaded ARM64 NEON FFmpeg software decoding;
   - Full **ASS / SSA** styled subtitle rendering (via `libass` with embedded MKV fonts), **SRT, PGS, and VobSub** (both embedded and external streams) with subtitle delay control;
   - Direct audio decoding for **FLAC, AC3, E-AC3, DTS, Opus, Vorbis, AAC, and MP3**.
2. **Top Transparent Web UI Layer (`WKWebView` + `NativeShell` from `jellyfin-desktop`)**:
   - Injects `jellyfin-desktop` client extensions (`mpvVideoPlayer.js`, `mpvAudioPlayer.js`, `inputPlugin.js`, `nativeshell.js`) bridged through `WKScriptMessageHandler` (`iosWebChannelShim.js`, compatible with `QWebChannel`);
   - Includes **ES2023/ES2024 WebKit polyfills (`ios15Polyfills.js`)** so modern `jellyfin-web` releases (10.9 / 10.10 / 10.11+) run cleanly on iPadOS 15.8.8 WebKit;
   - Integrates with iPadOS **Lock Screen, Control Center, AirPods / Bluetooth media controls** (`MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`), and hardware iPad keyboard shortcuts.

---

## Building via GitHub Actions

Every push to `main` (or manual **Run workflow** dispatch) triggers `.github/workflows/build-ios.yml`, which generates the Xcode project with `XcodeGen`, installs `MobileVLCKit 3.6.0` via CocoaPods, compiles an `arm64` Release build targeting iOS 15.0, and uploads the **`JellyfinDesktop-iPadOS15-IPA`** artifact containing:

- `JellyfinDesktop-iOS15-unsigned.ipa` — for **Sideloadly / AltStore / SideStore / Feather**;
- `JellyfinDesktop-iOS15-TrollStore.tipa` — for **TrollStore**.

Pushing a version tag (`v*`, e.g. `v1.0.0`) automatically publishes a GitHub Release with both packages attached.

---

## Installing on iPad Air 2 (iPadOS 15.8.8)

### Option 1: Sideloadly or AltStore (No Jailbreak, Standard Apple ID)
1. Install [Sideloadly](https://sideloadly.io/) on your computer.
2. Connect your iPad Air 2 via USB, drag `JellyfinDesktop-iOS15-unsigned.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
3. On your iPad, open **Settings -> General -> VPN & Device Management** and trust your developer certificate.
4. Grant **Local Network** permission on first launch so the app can reach your local Jellyfin server (`192.168.x.x:8096`).

### Option 2: TrollStore (Permanent Install without 7-Day Re-signing)
iPadOS 15.8.8 on iPad Air 2 supports **TrollStore**:
1. AirDrop or copy `JellyfinDesktop-iOS15-TrollStore.tipa` (or `.ipa`) to your iPad.
2. Share the file to **TrollStore** and tap **Install**.

---

## Usage Tips for iPad Air 2 (Apple A8X)

- **Codec Profile Settings (`Client Settings`)**: Open your user menu in Jellyfin -> **Client Settings**. Defaults are pre-tuned for the Apple A8X:
  - **H.264 (up to 1080p) in MKV/MP4 + ASS/SRT + FLAC/AC3** plays via hardware **Direct Play** with minimal battery usage.
  - **Force Transcode HEVC / 4K / Hi10P / HDR / AV1** options are enabled by default so heavy 4K 10-bit HEVC files are transcoded to H.264 by your server. You can uncheck any of them in **Client Settings** if you want to software Direct Play lower-bitrate 720p/1080p 8-bit HEVC or 10-bit H.264 anime on the iPad CPU.
- **4:3 Screen Scaling (`Zoom` / `Normal`)**: During playback, tap the gear icon in the Jellyfin OSD -> **Aspect Ratio -> Zoom** to fill the 4:3 Retina display edge-to-edge without black bars.
- **Quick Service Menu Gesture**: Press and hold **3 fingers for 1 second** anywhere on screen to open the native iPadOS quick menu (Reload Page, Switch UI Layout `DESKTOP` / `MOBILE` / `TV`, Toggle Self-Signed SSL Trust, or Change Jellyfin Server).
