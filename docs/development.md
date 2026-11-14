# Development and platform setup

Use Flutter 3.41 or newer with Dart satisfying `pubspec.yaml` (currently
`^3.10.7`). CI pins Flutter 3.47.7. Install dependencies with:

```sh
flutter pub get
```

## Native runtime

The app installs `xconn` from pub.dev. Its Dart build hook downloads, verifies,
and bundles the native runtime, so normal supported-platform builds need
neither Rust nor an XConn source checkout. The first build needs access to
GitHub Releases; subsequent builds can reuse the verified cache.

The documented downloadable targets are Android ARM64 (API 24+), Linux
x86-64/ARM64, and macOS ARM64. Other native targets require a matching library
configured with XConn's `native_library` build-hook override; see the
[package documentation](https://pub.dev/packages/xconn).

The Flutter Web project directory does not imply browser support for this
native binding. Use [DeskConn Web](https://github.com/xconnio/deskconn-web) for
the browser client.

## Android

Install the Android SDK and a Gradle-compatible JDK; CI uses Java 17. The app
build targets ARM64 only, matching the bundled native runtime.

```sh
flutter run -d DEVICE_ID
flutter build apk --release --no-tree-shake-icons --target-platform android-arm64
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.
When `android/key.properties` is absent, release builds use the debug signing
configuration. Distribution builds require your release keystore and its
`storeFile`, `storePassword`, `keyAlias`, and `keyPassword` settings in that file.
The Android release workflow obtains these values from repository secrets.

The project includes Firebase configuration for its existing application ID.
A separately branded deployment needs matching Firebase configuration and
platform application identifiers.

## Backend configuration

The app defaults to the hosted DeskConn deployment. Connection endpoints, realms,
and registration identity are defined in `lib/core/constants.dart`; they are
compiled into the app, rather than loaded from a `.env` file.

For self-hosting, update those values to match your Hub and management deployment
before building. The registration identity is shipped to clients and must have
only the permissions intended for registration. QUIC verifies the server
certificate against the platform's trusted roots.

## Windows

A matching native library must be supplied through the `native_library` override.
An SDK archive for another Windows toolchain is not automatically compatible
with that build-hook target. Flutter also requires Visual Studio with the
Desktop development with C++ workload.

### Known build issues with newer CMake / Visual Studio

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

