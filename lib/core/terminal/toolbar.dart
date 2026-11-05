import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Toolbar extends StatefulWidget {
  final dynamic controller;

  const Toolbar({super.key, required this.controller});

  @override
  State<Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<Toolbar> {
  @override
  void initState() {
    super.initState();
    widget.controller.onModifierChanged = () => setState(() {});
  }

  void send(String key) {
    widget.controller.sendSpecialKey(key);
    setState(() {});
  }

  Widget key(String label, VoidCallback onTap, {bool active = false}) {
    return Expanded(
      child: _KeyButton(label: label, onTap: onTap, active: active),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    key("ESC", () => send("\x1b")),
                    key("/", () => send("/")),
                    key("DEL", () => widget.controller.sendDel()),
                    key("HOME", () => widget.controller.sendHome()),
                    key("↑", () => widget.controller.sendArrowUp()),
                    key("END", () => widget.controller.sendEnd()),
                    key("PGUP", () => send("\x1b[5~")),
                  ],
                ),
                Row(
                  children: [
                    key("TAB", () => widget.controller.sendTab()),
                    key(
                      "CTRL",
                      () => setState(() => widget.controller.ctrl = !widget.controller.ctrl),
                      active: widget.controller.ctrl,
                    ),
                    key(
                      "ALT",
                      () => setState(() => widget.controller.alt = !widget.controller.alt),
                      active: widget.controller.alt,
                    ),
                    key("←", () => widget.controller.sendArrowLeft()),
                    key("↓", () => widget.controller.sendArrowDown()),
                    key("→", () => widget.controller.sendArrowRight()),
                    key("PGDN", () => send("\x1b[6~")),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;

  const _KeyButton({required this.label, required this.onTap, this.active = false});

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  bool _pressed = false;

  Color get _bgColor {
    if (widget.active) return _pressed ? const Color(0xFFCCCCCC) : Colors.white;
    return _pressed ? const Color(0xFFBABABA) : Colors.black87;
  }

  Color get _textColor => widget.active ? Colors.black : Colors.white;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.selectionClick();
        setState(() => _pressed = true);
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: _bgColor, borderRadius: BorderRadius.circular(6)),
        child: Center(
          child: Text(widget.label, style: DeskconnText.label.copyWith(color: _textColor)),
        ),
      ),
    );
  }
}
