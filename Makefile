install:
	flutter pub get
	flutter gen-l10n
	@if [ -d lib/l10n/generated ]; then dart format --line-length 120 lib/l10n/generated > /dev/null; fi

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
build-apk:
	flutter build apk --no-tree-shake-icons --target-platform android-arm64
