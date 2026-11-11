import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('type scale exposes the expected sizes', () {
    expect(DeskconnText.display.fontSize, 32);
    expect(DeskconnText.headline.fontSize, 24);
    expect(DeskconnText.title.fontSize, 20);
    expect(DeskconnText.body.fontSize, 14);
    expect(DeskconnText.caption.fontSize, 12);
    expect(DeskconnText.mono.fontFamily, 'monospace');
  });

  test('palette has distinct light and dark tokens', () {
    expect(DeskconnPalette.light.surface, isNot(DeskconnPalette.dark.surface));
    expect(DeskconnPalette.light.statusOnline, isNot(DeskconnPalette.dark.statusOnline));
  });

  test('palette lerp lands between the two themes', () {
    final mid = DeskconnPalette.light.lerp(DeskconnPalette.dark, 0.5);
    expect(mid.background, isNot(DeskconnPalette.light.background));
    expect(mid.background, isNot(DeskconnPalette.dark.background));
  });
}
