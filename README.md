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

### P2P

The WebRTC offer and ICE candidates go over the routed WAMP session. The
connection carries WAMP and opens shell, VPN and file channels on demand.
XConn Core owns ICE, DTLS, SCTP, WAMP framing and transport lifecycle in Rust.
DeskConn retains its encrypted shell/file/port/VPN record protocols.

### Routed

The WAMP session runs over Core's native QUIC transport.

The terminal can't use the WAMP session: the agent serves shells only over
streams. So the app opens a raw QUIC stream that the router relays to the
desktop (`openRoutedShell` in `lib/core/terminal/shell_stream.dart`). This is
the same protocol the `deskconn shell` CLI uses:

1. Dial a QUIC connection into the desktop's realm for that shell alone. The
   router only relays a stream to the realm its connection authenticated to,
   so the shared connection can't be used.
2. Send a routing frame (`{"realm": ..., "op": "shell"}`).
3. Exchange X25519 keys.
4. Send and receive length-prefixed, ChaCha20-Poly1305-encrypted envelopes:
   a kind byte (control or PTY data), then the nonce and ciphertext.

This needs the native QUIC library. If no shell path works, the terminal says
it isn't available over the connection instead of retrying forever. The
paths, tried in order, are:

1. the P2P `shell` channel
2. the routed QUIC stream
3. the legacy `io.xconn.deskconn.deskconnd.shell` procedure, for older agents

Port forwarding and the VPN need P2P. The VPN always opens its own P2P
connection, whichever mode the desktop's chip shows.

## Setup

The app uses `xconn_core` from pub.dev. A Core source checkout and Rust toolchain
are not required. Use Flutter 3.41 or newer (CI uses 3.47.7). Android builds also
need a Gradle-compatible JDK (17 or 21) and the Android SDK.

```sh
flutter pub get
flutter test
flutter build apk --no-tree-shake-icons --target-platform android-arm64
```

Core's Dart build hook downloads, verifies, and bundles native SDK 0.1.1.
The first build needs access to GitHub Releases; later builds can reuse the
verified cache. The library includes WAMP, QUIC, WebTransport and WebRTC.
Downloaded SDKs support Android ARM64 (API 24+), Linux x86-64/ARM64, and macOS
ARM64. iOS, Windows, and Intel macOS require a separately built native library
configured through Core's `native_library` build-hook override. See the
[Core package documentation](https://pub.dev/packages/xconn_core).

QUIC uses certificate verification against the platform's trusted roots.
Port forwarding and VPN require a direct peer connection; shell streams also
work through the cloud router's QUIC relay.

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
