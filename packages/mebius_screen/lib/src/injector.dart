// Internal: not exported.
// ignore_for_file: public_member_api_docs, avoid_positional_boolean_parameters

import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart' show calloc;
import 'package:mebius_screen/src/input_event.dart';
import 'package:meta/meta.dart';
import 'package:win32/win32.dart' as w;

/// Turns remote input into local OS input. The agent only calls it while a
/// `control` session is active.
abstract interface class InputInjector {
  /// Applies [event]. Throws [StateError] when the OS refuses input (no
  /// Accessibility permission, input blocked).
  void inject(MebiusInputEvent event);

  /// Lets go of every key and button still held down, so nothing stays
  /// pressed after the admin's session ends. Never throws.
  void releaseAll();
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
  return NoopInjector();
}

/// Remembers what is held (see [HeldInput]) so [releaseAll] can let go of
/// it. Subclasses only [apply].
abstract class HoldingInjector implements InputInjector {
  /// What the injected input has pressed and not released.
  final HeldInput held = HeldInput();

  /// Sends one event to the OS.
  @protected
  void apply(MebiusInputEvent event);

  @override
  void inject(MebiusInputEvent event) {
    held.track(event);
    apply(event);
  }

  @override
  void releaseAll() {
    for (final e in held.release()) {
      try {
        apply(e);
      } on Object {
        // Best-effort: a release that fails cannot be helped by the caller.
      }
    }
  }
}

class NoopInjector extends HoldingInjector {
  @override
  void apply(MebiusInputEvent event) {}
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

/// A DOM wheel delta (pixels; a mouse notch is ~100) as SendInput mouseData
/// (WHEEL_DELTA = 120 per notch), clamped to what one event may carry.
int toWindowsWheel(int domPixels) =>
    (domPixels * 1.2).round().clamp(-32768, 32767);

/// The capture source for the display the injectors drive: the one whose id
/// is [primaryId], else the first listed.
T pickPrimary<T>(List<T> sources, String Function(T) idOf, String? primaryId) =>
    sources.firstWhere(
      (s) => idOf(s) == primaryId,
      orElse: () => sources.first,
    );

/// The capture source id (libwebrtc's) of the primary display: its
/// CGDirectDisplayID on macOS, its `EnumDisplayDevices` index on Windows.
/// Null elsewhere or when it cannot be read.
String? primaryScreenSourceId() {
  try {
    if (Platform.isMacOS) {
      return '${_CoreGraphics.instance.mainDisplay()}';
    }
    if (Platform.isWindows) {
      return _windowsPrimaryIndex();
    }
  } on Object {
    // Fall back to the first source.
  }
  return null;
}

String? _windowsPrimaryIndex() {
  final dd = calloc<w.DISPLAY_DEVICE>();
  try {
    for (var i = 0; i < 32; i++) {
      dd.ref.cb = sizeOf<w.DISPLAY_DEVICE>();
      if (!w.EnumDisplayDevices(null, i, dd, 0)) {
        return null;
      }
      if (dd.ref.StateFlags.has(w.DISPLAY_DEVICE_PRIMARY_DEVICE)) {
        return '$i';
      }
    }
    return null;
  } finally {
    calloc.free(dd);
  }
}

/// `KeyboardEvent.code` → macOS virtual keycode (`kVK_*`, Carbon Events.h).
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
  'Equal': 0x18, 'Minus': 0x1B, 'BracketRight': 0x1E, 'BracketLeft': 0x21,
  'Quote': 0x27, 'Semicolon': 0x29, 'Backslash': 0x2A, 'Comma': 0x2B,
  'Slash': 0x2C, 'Period': 0x2F, 'Backquote': 0x32, 'IntlBackslash': 0x0A,
  'Enter': 0x24, 'Tab': 0x30, 'Space': 0x31, 'Backspace': 0x33,
  'Escape': 0x35, 'CapsLock': 0x39,
  'MetaLeft': 0x37, 'ShiftLeft': 0x38, 'AltLeft': 0x3A, 'ControlLeft': 0x3B,
  'MetaRight': 0x36, 'ShiftRight': 0x3C, 'AltRight': 0x3D,
  'ControlRight': 0x3E,
  'F1': 0x7A, 'F2': 0x78, 'F3': 0x63, 'F4': 0x76, 'F5': 0x60, 'F6': 0x61,
  'F7': 0x62, 'F8': 0x64, 'F9': 0x65, 'F10': 0x6D, 'F11': 0x67, 'F12': 0x6F,
  // Apple keyboards have no Insert or PrintScreen; Help and F13 sit where
  // those keys are on a PC layout.
  'Insert': 0x72, 'Home': 0x73, 'PageUp': 0x74, 'Delete': 0x75, 'End': 0x77,
  'PageDown': 0x79, 'PrintScreen': 0x69, 'ContextMenu': 0x6E,
  'ArrowLeft': 0x7B, 'ArrowRight': 0x7C, 'ArrowDown': 0x7D, 'ArrowUp': 0x7E,
  'Numpad0': 0x52, 'Numpad1': 0x53, 'Numpad2': 0x54, 'Numpad3': 0x55,
  'Numpad4': 0x56, 'Numpad5': 0x57, 'Numpad6': 0x58, 'Numpad7': 0x59,
  'Numpad8': 0x5B, 'Numpad9': 0x5C, 'NumpadDecimal': 0x41,
  'NumpadMultiply': 0x43, 'NumpadAdd': 0x45, 'NumpadDivide': 0x4B,
  'NumpadEnter': 0x4C, 'NumpadSubtract': 0x4E,
};

/// `KeyboardEvent.code` → Windows virtual-key code (`VK_*`).
final Map<String, int> windowsKeyCodes = {
  for (var i = 0; i < 26; i++) 'Key${String.fromCharCode(65 + i)}': 0x41 + i,
  for (var i = 0; i < 10; i++) 'Digit$i': 0x30 + i,
  for (var i = 0; i < 10; i++) 'Numpad$i': 0x60 + i,
  for (var i = 1; i <= 12; i++) 'F$i': 0x6F + i,
  'Enter': 0x0D, 'Escape': 0x1B, 'Backspace': 0x08, 'Tab': 0x09,
  'Space': 0x20, 'CapsLock': 0x14,
  'Minus': 0xBD, 'Equal': 0xBB, 'BracketLeft': 0xDB, 'BracketRight': 0xDD,
  'Backslash': 0xDC, 'Semicolon': 0xBA, 'Quote': 0xDE, 'Backquote': 0xC0,
  'Comma': 0xBC, 'Period': 0xBE, 'Slash': 0xBF, 'IntlBackslash': 0xE2,
  'Insert': 0x2D, 'Delete': 0x2E, 'Home': 0x24, 'End': 0x23,
  'PageUp': 0x21, 'PageDown': 0x22, 'PrintScreen': 0x2C, 'ContextMenu': 0x5D,
  'ArrowLeft': 0x25, 'ArrowUp': 0x26, 'ArrowRight': 0x27, 'ArrowDown': 0x28,
  'NumpadMultiply': 0x6A, 'NumpadAdd': 0x6B, 'NumpadSubtract': 0x6D,
  'NumpadDecimal': 0x6E, 'NumpadDivide': 0x6F,
  // Same VK as Enter; the extended flag is what tells them apart.
  'NumpadEnter': 0x0D,
  'ShiftLeft': 0xA0, 'ShiftRight': 0xA1, 'ControlLeft': 0xA2,
  'ControlRight': 0xA3, 'AltLeft': 0xA4, 'AltRight': 0xA5,
  'MetaLeft': 0x5B, 'MetaRight': 0x5C,
};

/// Keys Windows needs KEYEVENTF_EXTENDEDKEY for: without it an arrow or
/// Delete arrives as its numpad twin, and NumpadEnter as Enter.
const Set<String> windowsExtendedKeys = {
  'ArrowLeft',
  'ArrowUp',
  'ArrowRight',
  'ArrowDown',
  'Insert',
  'Delete',
  'Home',
  'End',
  'PageUp',
  'PageDown',
  'NumpadEnter',
  'NumpadDivide',
  'PrintScreen',
  'ContextMenu',
  'ControlRight',
  'AltRight',
  'MetaLeft',
  'MetaRight',
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

class _CoreGraphics {
  _CoreGraphics() {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    final cf = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
    );
    final ax = DynamicLibrary.open(
      '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices',
    );
    mouse = cg
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Uint32, _CGPoint, Uint32),
          Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int)
        >(
          'CGEventCreateMouseEvent',
        );
    key = cg
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
          Pointer<Void> Function(Pointer<Void>, int, bool)
        >(
          'CGEventCreateKeyboardEvent',
        );
    // The non-variadic form; macOS 13+, the package's floor.
    scroll = cg
        .lookupFunction<
          Pointer<Void> Function(
            Pointer<Void>,
            Uint32,
            Uint32,
            Int32,
            Int32,
            Int32,
          ),
          Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
        >(
          'CGEventCreateScrollWheelEvent2',
        );
    setField = cg
        .lookupFunction<
          Void Function(Pointer<Void>, Uint32, Int64),
          void Function(Pointer<Void>, int, int)
        >('CGEventSetIntegerValueField');
    post = cg
        .lookupFunction<
          Void Function(Uint32, Pointer<Void>),
          void Function(int, Pointer<Void>)
        >('CGEventPost');
    mainDisplay = cg.lookupFunction<Uint32 Function(), int Function()>(
      'CGMainDisplayID',
    );
    bounds = cg.lookupFunction<_CGRect Function(Uint32), _CGRect Function(int)>(
      'CGDisplayBounds',
    );
    release = cf
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CFRelease');
    trusted = ax.lookupFunction<Uint8 Function(), int Function()>(
      'AXIsProcessTrusted',
    );
  }

  static final _CoreGraphics instance = _CoreGraphics();

  late final Pointer<Void> Function(Pointer<Void>, int, _CGPoint, int) mouse;
  late final Pointer<Void> Function(Pointer<Void>, int, bool) key;
  late final Pointer<Void> Function(Pointer<Void>, int, int, int, int, int)
  scroll;
  late final void Function(Pointer<Void>, int, int) setField;
  late final void Function(int, Pointer<Void>) post;
  late final int Function() mainDisplay;
  late final _CGRect Function(int) bounds;
  late final void Function(Pointer<Void>) release;
  late final int Function() trusted;
}

class MacInjector extends HoldingInjector {
  final _CoreGraphics _cg = _CoreGraphics.instance;

  // CGEventType / CGMouseButton values, per button: down, up, dragged, button.
  static const _buttons = {
    'left': (1, 2, 6, 0),
    'right': (3, 4, 7, 1),
    'middle': (25, 26, 27, 2),
  };
  static const _mouseMoved = 5;
  static const _hidTap = 0;
  static const _clickStateField = 1; // kCGMouseEventClickState

  bool _trusted = false;
  Point<double> _at = const Point(0, 0);
  DateTime _lastDown = DateTime(0);
  String? _lastButton;
  int _clicks = 0;

  @override
  void apply(MebiusInputEvent e) {
    // Without Accessibility macOS drops posted events without a word; say so.
    // Re-asked until granted, since the user can grant it mid-session.
    if (!_trusted) {
      _trusted = _cg.trusted() != 0;
      if (!_trusted) {
        throw StateError(
          'Remote control needs the Accessibility permission '
          '(System Settings > Privacy & Security > Accessibility).',
        );
      }
    }
    final x = e.x;
    final y = e.y;
    if (x != null && y != null) {
      // Points, the global display space CGEvent works in; Retina scale is
      // already out of it. Read per event so a resolution change applies.
      final r = _cg.bounds(_cg.mainDisplay());
      _at = toDisplayPoint(
        x,
        y,
        Rectangle(r.origin.x, r.origin.y, r.size.x, r.size.y),
      );
    }
    switch (e.type) {
      case 'move':
        // A move with a button held is a drag, or apps never see one.
        final down = held.buttons.isEmpty ? null : _buttons[held.buttons.first];
        _postMouse(down?.$3 ?? _mouseMoved, down?.$4 ?? 0);
      case 'down' || 'up':
        final b = _buttons[e.button ?? 'left'];
        if (b == null) {
          return;
        }
        final down = e.type == 'down';
        if (down) {
          final now = DateTime.now();
          // macOS reads double-clicks from this count, not from timing.
          _clicks =
              _lastButton == e.button &&
                  now.difference(_lastDown) < const Duration(milliseconds: 500)
              ? _clicks + 1
              : 1;
          _lastDown = now;
          _lastButton = e.button;
        }
        _postMouse(down ? b.$1 : b.$2, b.$4, clicks: _clicks);
      case 'wheel':
        // DOM: positive dy scrolls down, in pixels. CoreGraphics: positive
        // scrolls up; pixel units (0) take the same magnitude.
        _postAndRelease(
          _cg.scroll(nullptr, 0, 2, -(e.dy ?? 0), -(e.dx ?? 0), 0),
        );
      case 'keydown' || 'keyup':
        final code = macKeyCodes[e.key];
        if (code != null) {
          _postAndRelease(_cg.key(nullptr, code, e.type == 'keydown'));
        }
    }
  }

  void _postMouse(int type, int button, {int? clicks}) {
    final p = Struct.create<_CGPoint>()
      ..x = _at.x
      ..y = _at.y;
    final ev = _cg.mouse(nullptr, type, p, button);
    if (clicks != null && ev != nullptr) {
      _cg.setField(ev, _clickStateField, clicks);
    }
    _postAndRelease(ev);
  }

  void _postAndRelease(Pointer<Void> ev) {
    if (ev == nullptr) {
      throw StateError('CoreGraphics could not create the input event.');
    }
    _cg
      ..post(_hidTap, ev)
      ..release(ev);
  }
}

// --- Windows: SendInput ------------------------------------------------------

class WindowsInjector extends HoldingInjector {
  static final Map<String, (int, int)> _flags = {
    'left': (w.MOUSEEVENTF_LEFTDOWN, w.MOUSEEVENTF_LEFTUP),
    'right': (w.MOUSEEVENTF_RIGHTDOWN, w.MOUSEEVENTF_RIGHTUP),
    'middle': (w.MOUSEEVENTF_MIDDLEDOWN, w.MOUSEEVENTF_MIDDLEUP),
  };

  @override
  void apply(MebiusInputEvent e) {
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
            i.mi.mouseData = toWindowsWheel(-e.dy!) & 0xFFFFFFFF;
            i.mi.dwFlags = w.MOUSEEVENTF_WHEEL;
          });
        }
        if ((e.dx ?? 0) != 0) {
          _send((i) {
            i.type = w.INPUT_MOUSE;
            i.mi.mouseData = toWindowsWheel(e.dx!) & 0xFFFFFFFF;
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
          // Apps that read scan codes (games, terminals, remote tools) see
          // nothing without it.
          i.ki.wScan = w.MapVirtualKey(vk, w.MAPVK_VK_TO_VSC);
          i.ki.dwFlags = w.KEYBD_EVENT_FLAGS(flags);
        });
    }
  }

  void _mouse(MebiusInputEvent e, int buttonFlag) {
    // Absolute without VIRTUALDESK is the primary monitor: the one captured.
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
      final r = w.SendInput(1, p, sizeOf<w.INPUT>());
      if (r.value == 0) {
        // UIPI (a window running as admin has focus), or the secure desktop.
        throw StateError('Windows blocked the input (error ${r.error}).');
      }
    } finally {
      calloc.free(p);
    }
  }
}
