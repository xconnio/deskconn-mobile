import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const colorTargets = ['lib/screens', 'lib/widgets', 'lib/main.dart', 'lib/core/wamp/machine_switcher.dart'];
const fontSizeTargets = ['lib/widgets'];

const colorAllowlist = {'lib/widgets/terminal_tile_icon.dart'};
const fontSizeAllowlist = {'lib/widgets/ring_gauge.dart', 'lib/widgets/terminal_tile_icon.dart'};

final rawColor = RegExp(r'Color\(0x');
final namedColor = RegExp(r'Colors\.(white|black)');
final rawFontSize = RegExp(r'fontSize:');

Iterable<String> dartFiles(String target) {
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.file) return [target];
  return Directory(
    target,
  ).listSync(recursive: true).whereType<File>().map((file) => file.path).where((path) => path.endsWith('.dart'));
}

List<String> violations(List<String> targets, bool Function(String line) match, Set<String> allowlist) {
  final offenders = <String>[];
  for (final target in targets) {
    for (final path in dartFiles(target)) {
      if (allowlist.contains(path)) continue;
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (match(lines[i])) offenders.add('$path:${i + 1}: ${lines[i].trim()}');
      }
    }
  }
  return offenders;
}

void main() {
  test('UI layers use tokens instead of raw colours', () {
    final offenders = violations(
      colorTargets,
      (line) => rawColor.hasMatch(line) || namedColor.hasMatch(line),
      colorAllowlist,
    );
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('widgets use the type scale instead of raw font sizes', () {
    final offenders = violations(fontSizeTargets, rawFontSize.hasMatch, fontSizeAllowlist);
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
