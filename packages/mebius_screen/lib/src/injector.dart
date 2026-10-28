// Internal: not exported.
// ignore_for_file: public_member_api_docs, avoid_positional_boolean_parameters

import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart' show calloc;
import 'package:mebius_screen/src/input_event.dart';
import 'package:win32/win32.dart' as w;

/// Turns remote input into local OS input. The agent only calls it while a
/// `control` session is active.
// ignore: one_member_abstracts
abstract interface class InputInjector {
  void inject(MebiusInputEvent event);
}

/// The injector for this OS: CoreGraphics on macOS, SendInput on Windows,
/// nothing elsewhere.
InputInjector platformInjector() {
  if (Platform.isMacOS) {
    return MacInjector();
  }
  if (Platform.isWindows) {
    return WindowsInjector();
  }
  return const NoopInjector();
}

class NoopInjector implements InputInjector {
  const NoopInjector();

  @override
  void inject(MebiusInputEvent event) {}
}

/// Maps a 0..1 position onto [bounds], clamping what falls outside.
Point<double> toDisplayPoint(double x, double y, Rectangle<double> bounds) =>
    Point(
      bounds.left + x.clamp(0, 1) * bounds.width,
      bounds.top + y.clamp(0, 1) * bounds.height,
    );

/// Maps 0..1 onto SendInput's absolute range, 0..65535 across the primary
/// monitor. Windows does the pixel and DPI arithmetic itself.
int toWindowsAbsolute(double v) => (v.clamp(0, 1) * 65535).round();

/// `KeyboardEvent.code` → macOS virtual keycode (`kVK_*`).
const Map<String, int> macKeyCodes = {
  'KeyA': 0x00, 'KeyS': 0x01, 'KeyD': 0x02, 'KeyF': 0x03, 'KeyH': 0x04,
  'KeyG': 0x05, 'KeyZ': 0x06, 'KeyX': 0x07, 'KeyC': 0x08, 'KeyV': 0x09,
  'KeyB': 0x0B, 'KeyQ': 0x0C, 'KeyW': 0x0D, 'KeyE': 0x0E, 'KeyR': 0x0F,
  'KeyY': 0x10, 'KeyT': 0x11, 'KeyO': 0x1F, 'KeyU': 0x20, 'KeyI': 0x22,
  'KeyP': 0x23, 'KeyL': 0x25, 'KeyJ': 0x26, 'KeyK': 0x28, 'KeyN': 0x2D,
  'KeyM': 0x2E,
  'Digit1': 0x12, 'Digit2': 0x13, 'Digit3': 0x14, 'Digit4': 0x15,
  'Digit6': 0x16, 'Digit5': 0x17, 'Digit9': 0x19, 'Digit7': 0x1A,
  'Digit8': 0x1C, 'Digit0': 0x1D,
  'Enter': 0x24, 'Tab': 0x30, 'Space': 0x31, 'Backspace': 0x33,
  'Escape': 0x35,
  'MetaLeft': 0x37, 'ShiftLeft': 0x38, 'AltLeft': 0x3A, 'ControlLeft': 0x3B,
  'MetaRight': 0x36, 'ShiftRight': 0x3C, 'AltRight': 0x3D,
  'ControlRight': 0x3E,
  'F1': 0x7A, 'F2': 0x78, 'F3': 0x63, 'F4': 0x76, 'F5': 0x60, 'F6': 0x61,
  'F7': 0x62, 'F8': 0x64, 'F9': 0x65, 'F10': 0x6D, 'F11': 0x67, 'F12': 0x6F,
  'ArrowLeft': 0x7B, 'ArrowRight': 0x7C, 'ArrowDown': 0x7D, 'ArrowUp': 0x7E,
};

/// `KeyboardEvent.code` → Windows virtual-key code (`VK_*`).
final Map<String, int> windowsKeyCodes = {
  for (var i = 0; i < 26; i++) 'Key${String.fromCharCode(65 + i)}': 0x41 + i,
  for (var i = 0; i < 10; i++) 'Digit$i': 0x30 + i,
  for (var i = 1; i <= 12; i++) 'F$i': 0x6F + i,
  'Enter': 0x0D, 'Escape': 0x1B, 'Backspace': 0x08, 'Tab': 0x09,
  'Space': 0x20,
  'ArrowLeft': 0x25, 'ArrowUp': 0x26, 'ArrowRight': 0x27, 'ArrowDown': 0x28,
  'ShiftLeft': 0xA0, 'ShiftRight': 0xA1, 'ControlLeft': 0xA2,
  'ControlRight': 0xA3, 'AltLeft': 0xA4, 'AltRight': 0xA5,
  'MetaLeft': 0x5B, 'MetaRight': 0x5C,
};

/// Keys Windows needs KEYEVENTF_EXTENDEDKEY for; without it an arrow arrives
/// as its numpad twin.
const Set<String> windowsExtendedKeys = {
  'ArrowLeft', 'ArrowUp', 'ArrowRight', 'ArrowDown', 'ControlRight',
  'AltRight', 'MetaLeft', 'MetaRight',
};

// --- macOS: CoreGraphics -----------------------------------------------------

final class _CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class _CGRect extends Struct {
  external _CGPoint origin;
  external _CGPoint size; // CGSize has the same layout: two doubles.
}

class MacInjector implements InputInjector {
  MacInjector() {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    final cf = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
    );
    _mouse = cg.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, _CGPoint, Uint32),
        Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)>(
      'CGEventCreateMouseEvent',
    );
    _key = cg.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
        Pointer<Void> Function(Pointer<Void>, int, bool)>(
      'CGEventCreateKeyboardEvent',
    );
    // The non-variadic form (macOS 13+); the original is variadic.
    _scroll = cg.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, Uint32, Int32, Int32, Int32),
        Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)>(
      'CGEventCreateScrollWheelEvent2',
    );
    _setField = cg.lookupFunction<Void Function(Pointer<Void>, Uint32, Int64),
        void Function(Pointer<Void>, int, int)>('CGEventSetIntegerValueField');
    _post = cg.lookupFunction<Void Function(Uint32, Pointer<Void>),
        void Function(int, Pointer<Void>)>('CGEventPost');
    _mainDisplay =
        cg.lookupFunction<Uint32 Function(), int Function()>('CGMainDisplayID');
    _bounds = cg.lookupFunction<_CGRect Function(Uint32), _CGRect Function(int)>(
      'CGDisplayBounds',
    );
    _release = cf.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('CFRelease');
  }

  late final Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int) _mouse;
  late final Pointer<Void> Function(Pointer<Void>, int, bool) _key;
  late final Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
      _scroll;
  late final void Function(Pointer<Void>, int, int) _setField;
  late final void Function(int, Pointer<Void>) _post;
  late final int Function() _mainDisplay;
  late final _CGRect Function(int) _bounds;
  late final void Function(Pointer<Void>) _release;

  // CGEventType / CGMouseButton values, per button: down, up, dragged, button.
  static const _buttons = {
    'left': (1, 2, 6, 0),
    'right': (3, 4, 7, 1),
    'middle': (25, 26, 27, 2),
  };
  static const _mouseMoved = 5;
  static const _hidTap = 0;
  static const _clickStateField = 1; // kCGMouseEventClickState

  final Set<String> _held = {};
  Point<double> _at = const Point(0, 0);
  DateTime _lastDown = DateTime(0);
  String? _lastButton;
  int _clicks = 0;

  @override
  void inject(MebiusInputEvent e) {
    final x = e.x;
    final y = e.y;
    if (x != null && y != null) {
      // Points, the global display space CGEvent works in; Retina scale is
      // already out of it. Read per event so a resolution change applies.
      final r = _bounds(_mainDisplay());
      _at = toDisplayPoint(
        x,
        y,
        Rectangle(r.origin.x, r.origin.y, r.size.x, r.size.y),
      );
    }
    switch (e.type) {
      case 'move':
        // A move with a button held is a drag, or apps never see one.
        final held = _held.isEmpty ? null : _buttons[_held.first];
        _postMouse(held?.$3 ?? _mouseMoved, held?.$4 ?? 0);
      case 'down' || 'up':
        final b = _buttons[e.button ?? 'left'];
        if (b == null) {
          return;
        }
        final down = e.type == 'down';
        if (down) {
          final now = DateTime.now();
          // macOS reads double-clicks from this count, not from timing.
          _clicks = _lastButton == e.button &&
                  now.difference(_lastDown) < const Duration(milliseconds: 500)
              ? _clicks + 1
              : 1;
          _lastDown = now;
          _lastButton = e.button;
          _held.add(e.button ?? 'left');
        } else {
          _held.remove(e.button ?? 'left');
        }
        _postMouse(down ? b.$1 : b.$2, b.$4, clicks: _clicks);
      case 'wheel':
        // DOM: positive dy scrolls down. CoreGraphics: positive scrolls up.
        _postAndRelease(
          _scroll(nullptr, 0, 2, -(e.dy ?? 0), -(e.dx ?? 0), 0),
        );
      case 'keydown' || 'keyup':
        final code = macKeyCodes[e.key];
        if (code != null) {
          _postAndRelease(_key(nullptr, code, e.type == 'keydown'));
        }
    }
  }

  void _postMouse(int type, int button, {int? clicks}) {
    final p = Struct.create<_CGPoint>()
      ..x = _at.x
      ..y = _at.y;
    final ev = _mouse(nullptr, type, p, button);
    if (clicks != null && ev != nullptr) {
      _setField(ev, _clickStateField, clicks);
    }
    _postAndRelease(ev);
  }

  void _postAndRelease(Pointer<Void> ev) {
    if (ev == nullptr) {
      return;
    }
    _post(_hidTap, ev);
    _release(ev);
  }
}

// --- Windows: SendInput ------------------------------------------------------

class WindowsInjector implements InputInjector {
  static final Map<String, (int, int)> _flags = {
    'left': (w.MOUSEEVENTF_LEFTDOWN, w.MOUSEEVENTF_LEFTUP),
    'right': (w.MOUSEEVENTF_RIGHTDOWN, w.MOUSEEVENTF_RIGHTUP),
    'middle': (w.MOUSEEVENTF_MIDDLEDOWN, w.MOUSEEVENTF_MIDDLEUP),
  };

  @override
  void inject(MebiusInputEvent e) {
    switch (e.type) {
      case 'move':
        _mouse(e, 0);
      case 'down' || 'up':
        final f = _flags[e.button ?? 'left'];
        if (f != null) {
          _mouse(e, e.type == 'down' ? f.$1 : f.$2);
        }
      case 'wheel':
        // DOM: positive dy scrolls down. Windows: positive scrolls up.
        if ((e.dy ?? 0) != 0) {
          _send((i) {
            i.type = w.INPUT_MOUSE;
            i.mi.mouseData = -e.dy! & 0xFFFFFFFF;
            i.mi.dwFlags = w.MOUSEEVENTF_WHEEL;
          });
        }
        if ((e.dx ?? 0) != 0) {
          _send((i) {
            i.type = w.INPUT_MOUSE;
            i.mi.mouseData = e.dx! & 0xFFFFFFFF;
            i.mi.dwFlags = w.MOUSEEVENTF_HWHEEL;
          });
        }
      case 'keydown' || 'keyup':
        final vk = windowsKeyCodes[e.key];
        if (vk == null) {
          return;
        }
        var flags = 0;
        if (e.type == 'keyup') {
          flags |= w.KEYEVENTF_KEYUP;
        }
        if (windowsExtendedKeys.contains(e.key)) {
          flags |= w.KEYEVENTF_EXTENDEDKEY;
        }
        _send((i) {
          i.type = w.INPUT_KEYBOARD;
          i.ki.wVk = w.VIRTUAL_KEY(vk);
          i.ki.dwFlags = w.KEYBD_EVENT_FLAGS(flags);
        });
    }
  }

  void _mouse(MebiusInputEvent e, int buttonFlag) {
    _send((i) {
      i.type = w.INPUT_MOUSE;
      i.mi.dx = toWindowsAbsolute(e.x ?? 0);
      i.mi.dy = toWindowsAbsolute(e.y ?? 0);
      i.mi.dwFlags = w.MOUSE_EVENT_FLAGS(
        w.MOUSEEVENTF_MOVE | w.MOUSEEVENTF_ABSOLUTE | buttonFlag,
      );
    });
  }

  void _send(void Function(w.INPUT input) fill) {
    final p = calloc<w.INPUT>();
    try {
      fill(p.ref);
      w.SendInput(1, p, sizeOf<w.INPUT>());
    } finally {
      calloc.free(p);
    }
  }
}
