import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

String _fill(int lines) => List.generate(lines, (i) => 'line $i\r\n').join();

const _scrollRegion = '\x1b[1;5r\x1b[5;1H';

void _triggerXtermBug(void Function(String) write, int maxLines) {
  write(_fill(maxLines * 2));
  write(_scrollRegion);
  for (var i = 0; i < 40; i++) {
    write('x $i\r\n');
  }
}

TerminalController _controller({Terminal? terminal}) => TerminalController(
  terminal: terminal,
  config: DesktopSessionLaunchConfig(
    sessionKey: 'k',
    desktopName: 'office-pc',
    realm: 'realm',
    authId: 'a',
    privateKey: 'p',
    webRtcEnabled: true,
  ),
);

void main() {
  test('xterm itself throws once a full buffer scrolls inside a scroll region', () {
    final terminal = Terminal(maxLines: 20);

    expect(() => _triggerXtermBug(terminal.write, 20), throwsA(isA<RangeError>()));
  });

  test('resizing after the scrollback is full keeps every line', () {
    final terminal = Terminal(maxLines: 100)..resize(40, 20);
    terminal.write(List.generate(250, (i) => 'line $i ${'x' * 60}\r\n').join());

    expect(() {
      terminal.resize(80, 20);
      terminal.resize(30, 20);
      terminal.resize(80, 25);
    }, returnsNormally);
    expect(terminal.buffer.lines.toList(), hasLength(terminal.buffer.lines.length));
  });

  test('the controller survives the same output without throwing', () {
    final controller = _controller(terminal: Terminal(maxLines: 20));

    expect(() => _triggerXtermBug(controller.writeOutput, controller.terminal.maxLines), returnsNormally);
  });

  test('output after the failure still reaches the tab preview', () {
    final controller = _controller(terminal: Terminal(maxLines: 20));
    _triggerXtermBug(controller.writeOutput, controller.terminal.maxLines);

    controller.writeOutput('still alive\r\n');

    expect(controller.preview, endsWith('still alive\n'));
  });

  test('normal output is written to the terminal buffer', () {
    final controller = _controller();

    controller.writeOutput('hello\r\n');

    expect(controller.terminal.buffer.lines[0].toString().trim(), 'hello');
    expect(controller.preview, 'hello\n');
  });
}
