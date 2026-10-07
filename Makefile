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

# XConn Core's Dart build hook downloads and bundles the native library.

snap:
	flutter build linux --release
	snapcraft --destructive-mode

snap-upload:
	snapcraft upload --release=stable deskconn_*_amd64.snap

build-apk:
	flutter build apk --no-tree-shake-icons --target-platform android-arm64
