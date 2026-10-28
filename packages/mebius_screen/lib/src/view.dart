import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius_screen/src/input_event.dart';
import 'package:mebius_screen/src/viewer.dart';
import 'package:meta/meta.dart';

/// Where a [video]-sized picture sits inside [box] when fitted whole
/// (letterboxed or pillarboxed), centered. The whole box while the size is
/// unknown.
@internal
Rect containRect(Size box, Size video) {
  if (video.isEmpty || box.isEmpty) {
    return Offset.zero & box;
  }
  final scale = min(box.width / video.width, box.height / video.height);
  final w = video.width * scale;
  final h = video.height * scale;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// [local] as 0..1 of [content]; null when it falls on the black bars.
@internal
Offset? normalize(Offset local, Rect content) {
  if (content.isEmpty || !content.contains(local)) {
    return null;
  }
  return Offset(
    (local.dx - content.left) / content.width,
    (local.dy - content.top) / content.height,
  );
}

const Map<int, String> _hidNames = {
  0x27: 'Digit0',
  0x28: 'Enter',
  0x29: 'Escape',
  0x2A: 'Backspace',
  0x2B: 'Tab',
  0x2C: 'Space',
  0x2D: 'Minus',
  0x2E: 'Equal',
  0x2F: 'BracketLeft',
  0x30: 'BracketRight',
  0x31: 'Backslash',
  0x33: 'Semicolon',
  0x34: 'Quote',
  0x35: 'Backquote',
  0x36: 'Comma',
  0x37: 'Period',
  0x38: 'Slash',
  0x39: 'CapsLock',
  0x46: 'PrintScreen',
  0x49: 'Insert',
  0x4A: 'Home',
  0x4B: 'PageUp',
  0x4C: 'Delete',
  0x4D: 'End',
  0x4E: 'PageDown',
  0x4F: 'ArrowRight',
  0x50: 'ArrowLeft',
  0x51: 'ArrowDown',
  0x52: 'ArrowUp',
  0x54: 'NumpadDivide',
  0x55: 'NumpadMultiply',
  0x56: 'NumpadSubtract',
  0x57: 'NumpadAdd',
  0x58: 'NumpadEnter',
  0x62: 'Numpad0',
  0x63: 'NumpadDecimal',
  0x64: 'IntlBackslash',
  0x65: 'ContextMenu',
  0xE0: 'ControlLeft',
  0xE1: 'ShiftLeft',
  0xE2: 'AltLeft',
  0xE3: 'MetaLeft',
  0xE4: 'ControlRight',
  0xE5: 'ShiftRight',
  0xE6: 'AltRight',
  0xE7: 'MetaRight',
};

/// The `KeyboardEvent.code` of a USB HID usage (what
/// `PhysicalKeyboardKey.usbHidUsage` holds), for the keys the agents map;
/// null for the rest.
@internal
String? domCode(int usbHidUsage) {
  if (usbHidUsage >> 16 != 0x07) {
    return null;
  }
  final u = usbHidUsage & 0xFFFF;
  return switch (u) {
    >= 0x04 && <= 0x1D => 'Key${String.fromCharCode(0x41 + u - 0x04)}',
    >= 0x1E && <= 0x26 => 'Digit${u - 0x1D}',
    >= 0x3A && <= 0x45 => 'F${u - 0x39}',
    >= 0x59 && <= 0x61 => 'Numpad${u - 0x58}',
    _ => _hidNames[u],
  };
}

const List<(int, String)> _buttonBits = [
  (kPrimaryMouseButton, 'left'),
  (kSecondaryMouseButton, 'right'),
  (kMiddleMouseButton, 'middle'),
];

/// The presses (`true`) and releases (`false`) that turn the button mask
/// [before] into [after]. Flutter reports a second button pressed during a
/// drag as a move with more bits set, not as another down.
@internal
List<(String, bool)> buttonChanges(int before, int after) => [
  for (final (bit, name) in _buttonBits)
    if ((before & bit == 0) != (after & bit == 0)) (name, after & bit != 0),
];

/// Renders a [MebiusScreenViewer]'s screen, fitted whole, and — once the
/// viewer's control is enabled — turns pointer and keys over it into remote
/// input. Click it to give it keyboard focus.
class MebiusScreenView extends StatefulWidget {
  /// Creates a view of [viewer].
  const MebiusScreenView(this.viewer, {super.key});

  /// The viewer whose screen to show.
  final MebiusScreenViewer viewer;

  @override
  State<MebiusScreenView> createState() => _MebiusScreenViewState();
}

class _MebiusScreenViewState extends State<MebiusScreenView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final FocusNode _focus = FocusNode(debugLabel: 'MebiusScreenView');

  /// Buttons this view has sent a down for.
  int _pressed = 0;
  bool _ready = false;
  Rect _content = Rect.zero;

  @override
  void initState() {
    super.initState();
    unawaited(
      _renderer.initialize().then((_) {
        if (!mounted) {
          return;
        }
        _ready = true;
        _focus.addListener(_focusChanged);
        _renderer.addListener(_changed);
        widget.viewer.stream.addListener(_bind);
        _bind();
      }),
    );
  }

  @override
  void didUpdateWidget(MebiusScreenView old) {
    super.didUpdateWidget(old);
    if (_ready && old.viewer != widget.viewer) {
      old.viewer.stream.removeListener(_bind);
      widget.viewer.stream.addListener(_bind);
      _bind();
    }
  }

  // Keys released while another window has focus never reach this view.
  void _focusChanged() {
    if (!_focus.hasFocus) {
      _pressed = 0;
      widget.viewer.releaseHeld();
    }
  }

  void _bind() => _renderer.srcObject = widget.viewer.stream.value;

  void _changed() {
    if (mounted) {
      setState(() {}); // The video size, for the letterbox.
    }
  }

  @override
  void dispose() {
    widget.viewer.releaseHeld();
    _focus.removeListener(_focusChanged);
    widget.viewer.stream.removeListener(_bind);
    _renderer.removeListener(_changed);
    unawaited(_renderer.dispose());
    _focus.dispose();
    super.dispose();
  }

  void _send(MebiusInputEvent e) => widget.viewer.sendInput(e);

  void _buttons(PointerEvent e, int now) {
    for (final (name, down) in buttonChanges(_pressed, now)) {
      final bit = _buttonBits.firstWhere((b) => b.$2 == name).$1;
      if (down) {
        // A press only counts if it starts on the picture.
        if (normalize(e.localPosition, _content) == null) {
          continue;
        }
        _pressed |= bit;
      } else {
        _pressed &= ~bit;
      }
      _pointer(e, down ? 'down' : 'up', name);
    }
  }

  void _pointer(PointerEvent e, String type, [String? button]) {
    final p = normalize(e.localPosition, _content);
    if (p == null && type == 'move') {
      return;
    }
    // A press that started on the picture is released even off it, clamped,
    // or the remote button stays held.
    final x = (p?.dx ?? ((e.localPosition.dx - _content.left) / _content.width))
        .clamp(0.0, 1.0);
    final y = (p?.dy ?? ((e.localPosition.dy - _content.top) / _content.height))
        .clamp(0.0, 1.0);
    _send(MebiusInputEvent(type, x: x, y: y, button: button));
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final code = domCode(e.physicalKey.usbHidUsage);
    if (code == null || !widget.viewer.controlEnabled) {
      return KeyEventResult.ignored;
    }
    _send(MebiusInputEvent(e is KeyUpEvent ? 'keyup' : 'keydown', key: code));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        _content = containRect(
          box.biggest,
          Size(
            _renderer.videoWidth.toDouble(),
            _renderer.videoHeight.toDouble(),
          ),
        );
        return Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerHover: (e) => _pointer(e, 'move'),
            onPointerMove: (e) {
              _pointer(e, 'move');
              _buttons(e, e.buttons);
            },
            onPointerDown: (e) {
              _focus.requestFocus();
              _buttons(e, e.buttons);
            },
            onPointerUp: (e) => _buttons(e, 0),
            onPointerCancel: (e) => _buttons(e, 0),
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _send(
                  MebiusInputEvent(
                    'wheel',
                    dx: e.scrollDelta.dx.round().clamp(-10000, 10000),
                    dy: e.scrollDelta.dy.round().clamp(-10000, 10000),
                  ),
                );
              }
            },
            child: RTCVideoView(_renderer),
          ),
        );
      },
    );
  }
}
