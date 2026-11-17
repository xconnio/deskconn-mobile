import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('breakpointForWidth classifies widths', () {
    expect(breakpointForWidth(320), DeskconnBreakpoint.compact);
    expect(breakpointForWidth(599), DeskconnBreakpoint.compact);
    expect(breakpointForWidth(600), DeskconnBreakpoint.medium);
    expect(breakpointForWidth(899), DeskconnBreakpoint.medium);
    expect(breakpointForWidth(900), DeskconnBreakpoint.expanded);
    expect(breakpointForWidth(1440), DeskconnBreakpoint.expanded);
  });
}
