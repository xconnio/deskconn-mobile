# Deskconn Mobile App

Connect to your desk and control it remotely.

## Features


- **Terminal** — open a shell session on your desktop from your phone
- **File explorer** — browse, share, and download files from your desktop
-  **Remote control** — lock/unlock the screen, adjust brightness, control
    media playback (MPRIS) with track artwork, mute/unmute audio, take
    screenshots
- **Share to desktop** — send files/photos from your phone to your desktop
- **Port forwarding** — reach a port on your desktop from this device, or
  expose a port of this device on the desktop
- **VPN** (Android) — route this phone's traffic through the desktop's
  connection (start it on the desktop with `deskconn vpn start`)
- **Account & device management** — sign up/sign in, manage your account,
  and manage the devices paired to it

## Connection modes

Every platform, desktop included, connects peer-to-peer (WebRTC) first
(`defaultWebRtcEnabled` in `lib/core/constants.dart`). After two failed P2P
attempts in a row, `DesktopConnectionManager` falls back to a connection
routed through the server.

- The status chip shows which mode is in use (`p2p` / `routed`).
- On the Machines screen, tapping a machine's status dot switches between
  them ("Retry P2P" / "Use Routed").
- Settings has a toggle to turn P2P off.

### Streams on either connection

The WebRTC offer and ICE candidates go over the routed WAMP session. XConn
Core owns ICE, DTLS, SCTP, WAMP framing and transport lifecycle in Rust.

Files, shells, and forward/reverse TCP tunnels use RPC-associated byte streams
on the desktop's WAMP session. Each operation calls its authorized procedure
and opens the stream at argument/result index 1. XConn carries those bytes over
WebRTC when direct or QUIC when routed, including the hub-to-backend bridge.
There is no separate routing header or named feature data channel.

DeskConn retains per-stream X25519 key exchange, encrypted records and feature
messages. Terminal tabs share the session while owning independent streams.
VPN retains its separate WebRTC datagram channel and requires P2P.

## Setup

The app uses `xconn` from pub.dev. A Core source checkout and Rust toolchain
are not required. Use Flutter 3.41 or newer (CI uses 3.47.7). Android builds also
need a Gradle-compatible JDK (17 or 21) and the Android SDK.

```sh
flutter pub get
flutter test
flutter build apk --no-tree-shake-icons --target-platform android-arm64
```

XConn's Dart build hook downloads, verifies, and bundles native SDK 0.6.0.
The first build needs access to GitHub Releases; later builds can reuse the
verified cache. The library includes WAMP, QUIC, WebTransport and WebRTC.
Downloaded SDKs support Android ARM64 (API 24+), Linux x86-64/ARM64, and macOS
ARM64. iOS, Windows, and Intel macOS require a separately built native library
configured through Core's `native_library` build-hook override. See the
[Core package documentation](https://pub.dev/packages/xconn).

QUIC uses certificate verification against the platform's trusted roots.
File, shell and TCP forwarding streams work through the cloud router or over
WebRTC. Only VPN requires a direct peer connection.

### Windows

A matching Core DLL must be supplied through the `native_library` override;
there is no downloadable Windows SDK yet. Flutter also requires Visual Studio
with the Desktop development with C++ workload.

#### Known build issues with newer CMake / Visual Studio

If your CMake is 4.0+ (bundled with recent Visual Studio installs — check
with `cmake --version`), `flutter run -d windows` / `flutter build windows`
can fail for reasons unrelated to this app's own code, since several
dependencies (Firebase, pdfx's bundled `pdfium` downloader) still declare
very old `cmake_minimum_required` versions that CMake 4.x refuses outright:

1. **`CMake Error ... Compatibility with CMake < 3.5 has been removed`**
   for `firebase_cpp_sdk_windows` or similar — set an environment variable
   (persists across terminals) and restart your terminal:
   ```
   setx CMAKE_POLICY_VERSION_MINIMUM 3.5
   ```

2. **Same error but for `pdfium` / `DownloadProject.cmake` failing** — the
   env var above doesn't reach this one (it configures `pdfium` as a
   separate nested `cmake` invocation at configure time). Patch the
   template directly in your pub cache:
   ```
   sed -i "s/VERSION 2.8.12/VERSION 3.5/" "$(dirname "$(find "$LOCALAPPDATA/Pub/Cache" -path '*pdfx-*/windows/DownloadProject.CMakeLists.cmake.in' 2>/dev/null | head -1)")/DownloadProject.CMakeLists.cmake.in"
   ```
   (Run from Git Bash. This needs re-applying if you ever wipe/reinstall
   your pub cache or bump the `pdfx` package version — it isn't something
   this repo can fix, since the file lives in the package's own source.)

3. **`error C2338: ... /await compiler option ... deprecated'** while
   building `audioplayers_windows` — a very recent MSVC toolset turns this
   from a warning into a hard error. Silence it via the `_CL_` env var
   (also read automatically by `cl.exe`; persists across terminals):
   ```
   setx _CL_ "/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
   ```

Both `setx` commands only affect *new* terminal sessions — open a fresh one
(or restart your IDE) before retrying the build.

### Feature interoperability tests

Build `tests/client-peer` in the migrated DeskConn checkout with its native SDK
installed, then run:

```sh
DESKCONN_STREAM_PEER=/path/to/deskconn-client-peer flutter test
```

This runs real encrypted file transfers, concurrent shells, and both TCP
forwarding directions through QUIC/WebRTC and the backend's yamux bridge.
