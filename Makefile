# The POSIX-shell recipes below (setup-quic-ios/-windows) need bash, but on
# Windows `make` defaults to cmd.exe unless told otherwise — even when `make`
# itself is invoked from PowerShell/cmd rather than Git Bash. Point it at Git
# for Windows' bash so `make setup-quic-windows` works from any shell. Only
# do this if that bash.exe actually exists, so machines without Git for
# Windows at the default path still get plain targets (install/lint/format)
# working via cmd.exe instead of every target breaking outright.
ifeq ($(OS),Windows_NT)
GIT_BASH := C:/Program Files/Git/bin/bash.exe
ifneq ($(wildcard $(GIT_BASH)),)
SHELL := $(GIT_BASH)
.SHELLFLAGS := -ec
endif
endif

install:
	flutter pub get

lint:
	dart analyze --fatal-infos

lint-fix:
	dart fix --apply

.PHONY: test
test:
	flutter test

check-format:
	dart format --output=none --set-exit-if-changed --line-length 120 .

format:
	dart format --line-length 120 .

snap:
	flutter build linux --release
	snapcraft --destructive-mode

snap-upload:
	snapcraft upload --release=stable deskconn_*_amd64.snap

setup-quic:
	mkdir -p android/app/src/main/jniLibs/arm64-v8a
	curl -L https://github.com/xconnio/xconn-dart/releases/latest/download/libdart_quic_ffi-android-arm64.so \
		-o android/app/src/main/jniLibs/arm64-v8a/libdart_quic_ffi.so

# Builds the iOS static libraries for the QUIC FFI (device + simulator) from the
# dart-quic Rust crate, then copies them where the Xcode project expects them.
# Requires: Rust toolchain (rustup) with aarch64-apple-ios and
# aarch64-apple-ios-sim targets. The deskconn server expects the wamp.2.quic
# ALPN, so the crate default (h3/hq-29) is patched before building.
setup-quic-ios:
	@set -e; \
	if [ ! -d /tmp/dart-quic ]; then \
		git clone --depth 1 https://github.com/arcticfox1919/dart-quic.git /tmp/dart-quic; \
	fi; \
	rustup target add aarch64-apple-ios aarch64-apple-ios-sim; \
	cd /tmp/dart-quic/dart-quic-ffi && \
		sed -i '' 's/crate-type = \[.*\]/crate-type = ["staticlib"]/' Cargo.toml; \
		sed -i '' 's/vec!\[b"h3".to_vec(), b"hq-29".to_vec()\]/vec![b"wamp.2.quic".to_vec()]/g' src/quic/quic_config.rs; \
	cargo build --release --target aarch64-apple-ios; \
	cargo build --release --target aarch64-apple-ios-sim; \
	mkdir -p ios/Runner/QuicFFI; \
	cp target/aarch64-apple-ios/release/libdart_quic_ffi.a \
		ios/Runner/QuicFFI/libdart_quic_ffi-device.a; \
	cp target/aarch64-apple-ios-sim/release/libdart_quic_ffi.a \
		ios/Runner/QuicFFI/libdart_quic_ffi-sim.a

# Builds the QUIC FFI DLL for Windows from the same dart-quic Rust crate and
# drops it where lib/core/wamp/quic_library_path.dart looks for it (next to the
# executable). Requires: Rust toolchain (rustup), run from Git Bash or MSYS2 so
# git/sed/cp/mkdir are available. Without it the app falls back to the router's
# WebSocket endpoint instead of QUIC.
setup-quic-windows:
	@set -e; \
	if [ ! -d /tmp/dart-quic ]; then \
		git clone --depth 1 https://github.com/arcticfox1919/dart-quic.git /tmp/dart-quic; \
	fi; \
	cd /tmp/dart-quic/dart-quic-ffi && \
		sed -i 's/vec!\[b"h3".to_vec(), b"hq-29".to_vec()\]/vec![b"wamp.2.quic".to_vec()]/g' src/quic/quic_config.rs; \
	cargo build --release; \
	mkdir -p "$(CURDIR)/windows/native"; \
	cp target/release/dart_quic_ffi.dll "$(CURDIR)/windows/native/dart_quic_ffi.dll"

# Builds the QUIC FFI dylib for macOS from the same dart-quic Rust crate, into
# macos/Runner/QuicFFI. Add that dylib to the Runner target's "Copy Files" phase
# (Destination: Executables) in Xcode so it ships next to the app binary, where
# lib/core/wamp/quic_library_path.dart looks for it. Without it the app falls
# back to the router's WebSocket endpoint instead of QUIC.
setup-quic-macos:
	@set -e; \
	if [ ! -d /tmp/dart-quic ]; then \
		git clone --depth 1 https://github.com/arcticfox1919/dart-quic.git /tmp/dart-quic; \
	fi; \
	cd /tmp/dart-quic/dart-quic-ffi && \
		sed -i '' 's/vec!\[b"h3".to_vec(), b"hq-29".to_vec()\]/vec![b"wamp.2.quic".to_vec()]/g' src/quic/quic_config.rs; \
	cargo build --release; \
	mkdir -p "$(CURDIR)/macos/Runner/QuicFFI"; \
	cp target/release/libdart_quic_ffi.dylib "$(CURDIR)/macos/Runner/QuicFFI/libdart_quic_ffi.dylib"

build-apk:
	flutter build apk --no-tree-shake-icons
