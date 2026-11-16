import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mebius_screen/mebius_screen.dart';
import 'package:mebius_screen/src/injector.dart';
import 'package:mebius_screen/src/view.dart';

void main() {
  group('agent coordinates', () {
    test('0..1 spans the display bounds, offset included', () {
      const b = Rectangle<double>(100, 50, 1440, 900);
      expect(toDisplayPoint(0, 0, b), const Point(100, 50));
      expect(toDisplayPoint(1, 1, b), const Point(1540, 950));
      expect(toDisplayPoint(0.5, 0.25, b), const Point(820, 275));
    });

    test('out-of-range input is clamped to the display', () {
      const b = Rectangle<double>(0, 0, 100, 100);
      expect(toDisplayPoint(-1, 2, b), const Point(0, 100));
      expect(toWindowsAbsolute(-0.1), 0);
      expect(toWindowsAbsolute(1.5), 65535);
      expect(toWindowsAbsolute(0.5), 32768);
    });
  });

  group('viewer coordinates', () {
    test('a wide picture in a tall box is letterboxed', () {
      final r = containRect(const Size(400, 400), const Size(1600, 900));
      expect(r, const Rect.fromLTWH(0, 87.5, 400, 225));
      expect(normalize(const Offset(200, 50), r), isNull, reason: 'on the bar');
      expect(normalize(const Offset(200, 200), r), const Offset(0.5, 0.5));
      expect(normalize(const Offset(0, 87.5), r), Offset.zero);
    });

    test('a tall picture in a wide box is pillarboxed', () {
      final r = containRect(const Size(1000, 500), const Size(500, 500));
      expect(r, const Rect.fromLTWH(250, 0, 500, 500));
      expect(normalize(const Offset(375, 125), r), const Offset(0.25, 0.25));
      expect(normalize(const Offset(100, 125), r), isNull);
    });

    test('an unknown video size uses the whole box', () {
      expect(
        containRect(const Size(300, 200), Size.zero),
        const Rect.fromLTWH(0, 0, 300, 200),
      );
    });
  });

  group('key tables', () {
    final required = [
      for (var i = 0; i < 26; i++) 'Key${String.fromCharCode(65 + i)}',
      for (var i = 0; i < 10; i++) 'Digit$i',
      for (var i = 1; i <= 12; i++) 'F$i',
      'Enter',
      'Escape',
      'Backspace',
      'Tab',
      'Space',
      'ArrowLeft',
      'ArrowRight',
      'ArrowUp',
      'ArrowDown',
      'ShiftLeft',
      'ShiftRight',
      'ControlLeft',
      'ControlRight',
      'AltLeft',
      'AltRight',
      'MetaLeft',
      'MetaRight',
      'Minus',
      'Equal',
      'BracketLeft',
      'BracketRight',
      'Backslash',
      'Semicolon',
      'Quote',
      'Backquote',
      'Comma',
      'Period',
      'Slash',
      'IntlBackslash',
      'Delete',
      'Home',
      'End',
      'PageUp',
      'PageDown',
      'Insert',
      'CapsLock',
      for (var i = 0; i < 10; i++) 'Numpad$i',
      'NumpadAdd',
      'NumpadSubtract',
      'NumpadMultiply',
      'NumpadDivide',
      'NumpadDecimal',
      'NumpadEnter',
      'ContextMenu',
      'PrintScreen',
    ];

    test('both agents map every required key, and only those', () {
      expect(macKeyCodes.keys.toSet(), required.toSet());
      expect(windowsKeyCodes.keys.toSet(), required.toSet());
    });

    test('no two keys share a code', () {
      expect(macKeyCodes.values.toSet(), hasLength(macKeyCodes.length));
      // NumpadEnter is VK_RETURN plus the extended flag.
      String winId(String k) =>
          '${windowsKeyCodes[k]}${windowsExtendedKeys.contains(k)}';
      expect(
        windowsKeyCodes.keys.map(winId).toSet(),
        hasLength(windowsKeyCodes.length),
      );
    });

    test('Windows marks the keys that need the extended flag', () {
      expect(
        windowsExtendedKeys,
        containsAll([
          'Delete',
          'Home',
          'End',
          'PageUp',
          'PageDown',
          'Insert',
          'ArrowLeft',
          'ArrowRight',
          'ArrowUp',
          'ArrowDown',
          'NumpadEnter',
          'NumpadDivide',
          'ControlRight',
          'AltRight',
          'MetaLeft',
          'MetaRight',
        ]),
      );
      for (final k in ['ShiftLeft', 'ShiftRight', 'Enter', 'Numpad5', 'KeyA']) {
        expect(windowsExtendedKeys, isNot(contains(k)), reason: k);
      }
      expect(
        windowsExtendedKeys.difference(windowsKeyCodes.keys.toSet()),
        isEmpty,
      );
    });

    test('spot checks against the platform headers', () {
      expect(macKeyCodes['KeyA'], 0x00);
      expect(macKeyCodes['Enter'], 0x24);
      expect(macKeyCodes['MetaLeft'], 0x37);
      expect(macKeyCodes['F12'], 0x6F);
      expect(macKeyCodes['ArrowUp'], 0x7E);
      expect(windowsKeyCodes['KeyZ'], 0x5A);
      expect(windowsKeyCodes['Digit0'], 0x30);
      expect(windowsKeyCodes['F1'], 0x70);
      expect(windowsKeyCodes['F12'], 0x7B);
      expect(windowsKeyCodes['MetaLeft'], 0x5B);
      expect(macKeyCodes['Delete'], 0x75); // forward delete
      expect(macKeyCodes['Backquote'], 0x32);
      expect(macKeyCodes['Numpad8'], 0x5B);
      expect(macKeyCodes['IntlBackslash'], 0x0A);
      expect(windowsKeyCodes['Minus'], 0xBD);
      expect(windowsKeyCodes['Numpad9'], 0x69);
      expect(windowsKeyCodes['NumpadEnter'], 0x0D);
      expect(windowsKeyCodes['IntlBackslash'], 0xE2);
      expect(windowsKeyCodes['ContextMenu'], 0x5D);
      expect(windowsExtendedKeys, contains('ArrowLeft'));
      expect(windowsExtendedKeys, isNot(contains('ShiftLeft')));
    });

    test('the viewer sends exactly the codes the agents know', () {
      // Every keyboard-page usage: what it yields is exactly the set the
      // agents map, nothing they would drop.
      final codes = {
        for (var u = 0; u <= 0xFF; u++) domCode(0x00070000 | u),
      }..remove(null);
      expect(codes, required.toSet());
      expect(domCode(PhysicalKeyboardKey.keyQ.usbHidUsage), 'KeyQ');
      expect(domCode(PhysicalKeyboardKey.digit5.usbHidUsage), 'Digit5');
      expect(domCode(PhysicalKeyboardKey.metaRight.usbHidUsage), 'MetaRight');
      expect(domCode(PhysicalKeyboardKey.arrowDown.usbHidUsage), 'ArrowDown');
      expect(domCode(PhysicalKeyboardKey.f11.usbHidUsage), 'F11');
      expect(domCode(PhysicalKeyboardKey.capsLock.usbHidUsage), 'CapsLock');
      expect(
        domCode(PhysicalKeyboardKey.numpadEnter.usbHidUsage),
        'NumpadEnter',
      );
      expect(domCode(PhysicalKeyboardKey.numpad7.usbHidUsage), 'Numpad7');
      expect(domCode(PhysicalKeyboardKey.delete.usbHidUsage), 'Delete');
      expect(
        domCode(PhysicalKeyboardKey.intlBackslash.usbHidUsage),
        'IntlBackslash',
      );
      expect(
        domCode(PhysicalKeyboardKey.contextMenu.usbHidUsage),
        'ContextMenu',
      );
      expect(domCode(PhysicalKeyboardKey.numLock.usbHidUsage), isNull);
    });
  });

  test(
    'macOS: every CoreGraphics symbol the injector uses resolves',
    // Construction looks each one up; nothing is posted.
    () => expect(MacInjector.new, returnsNormally),
    skip: !Platform.isMacOS,
  );

  group('held input', () {
    test('releaseAll lets go of buttons, then keys in reverse order', () {
      final inj = _Recorder()
        ..inject(const MebiusInputEvent('keydown', key: 'ControlLeft'))
        ..inject(const MebiusInputEvent('keydown', key: 'KeyC'))
        ..inject(const MebiusInputEvent('down', x: 0.3, y: 0.4, button: 'left'))
        ..inject(
          const MebiusInputEvent('down', x: 0.3, y: 0.4, button: 'right'),
        )
        ..inject(const MebiusInputEvent('up', x: 0.3, y: 0.4, button: 'right'))
        ..inject(const MebiusInputEvent('move', x: 0.5, y: 0.6));
      inj.applied.clear();
      inj.releaseAll();
      expect(inj.applied.map((e) => e.toJson()).toList(), [
        {'type': 'up', 'x': 0.5, 'y': 0.6, 'button': 'left'},
        {'type': 'keyup', 'key': 'KeyC'},
        {'type': 'keyup', 'key': 'ControlLeft'},
      ]);
      inj
        ..applied.clear()
        ..releaseAll();
      expect(inj.applied, isEmpty, reason: 'nothing held twice');
    });

    test('a release that throws does not stop the others', () {
      final inj = _Recorder()
        ..inject(const MebiusInputEvent('keydown', key: 'KeyA'))
        ..inject(const MebiusInputEvent('keydown', key: 'KeyB'))
        ..failOn = 'KeyB';
      inj.applied.clear();
      expect(inj.releaseAll, returnsNormally);
      expect(inj.applied.single.key, 'KeyA');
    });
  });

  test('button masks become downs and ups', () {
    expect(buttonChanges(0, kPrimaryMouseButton), [('left', true)]);
    expect(
      buttonChanges(
        kPrimaryMouseButton,
        kPrimaryMouseButton | kSecondaryMouseButton,
      ),
      [('right', true)],
    );
    expect(
      buttonChanges(kPrimaryMouseButton | kMiddleMouseButton, 0),
      [('left', false), ('middle', false)],
    );
    expect(buttonChanges(kPrimaryMouseButton, kPrimaryMouseButton), isEmpty);
  });

  test('capture picks the primary display, else the first', () {
    String id(String s) => s;
    expect(pickPrimary(['0', '1', '2'], id, '1'), '1');
    expect(pickPrimary(['5', '9'], id, '7'), '5');
    expect(pickPrimary(['5', '9'], id, null), '5');
  });

  test('wheel pixels scale to Windows wheel units', () {
    expect(toWindowsWheel(100), 120);
    expect(toWindowsWheel(-100), -120);
    expect(toWindowsWheel(100000), 32767);
  });

  test(
    'macOS: the primary display id is readable',
    () => expect(primaryScreenSourceId(), matches(RegExp(r'^\d+$'))),
    skip: !Platform.isMacOS,
  );
}

class _Recorder extends HoldingInjector {
  final List<MebiusInputEvent> applied = [];
  String? failOn;
  @override
  void apply(MebiusInputEvent event) {
    if (event.key != null && event.key == failOn) {
      throw StateError('fail');
    }
    applied.add(event);
  }
}
