import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
      'Enter', 'Escape', 'Backspace', 'Tab', 'Space',
      'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
      'ShiftLeft', 'ShiftRight', 'ControlLeft', 'ControlRight',
      'AltLeft', 'AltRight', 'MetaLeft', 'MetaRight',
    ];

    test('both agents map every required key, and only those', () {
      expect(macKeyCodes.keys.toSet(), required.toSet());
      expect(windowsKeyCodes.keys.toSet(), required.toSet());
    });

    test('no two keys share a code', () {
      expect(macKeyCodes.values.toSet(), hasLength(macKeyCodes.length));
      expect(windowsKeyCodes.values.toSet(), hasLength(windowsKeyCodes.length));
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
      expect(windowsExtendedKeys, contains('ArrowLeft'));
      expect(windowsExtendedKeys, isNot(contains('ShiftLeft')));
    });

    test('the viewer sends exactly the codes the agents know', () {
      final keys = [
        ...List.generate(26, (i) => 0x00070004 + i),
        ...List.generate(10, (i) => 0x0007001E + i),
        ...List.generate(12, (i) => 0x0007003A + i),
        ...List.generate(8, (i) => 0x000700E0 + i),
        for (final k in [0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x4F, 0x50, 0x51, 0x52])
          0x00070000 | k,
      ];
      expect(keys.map(domCode).toSet(), required.toSet());
      expect(domCode(PhysicalKeyboardKey.keyQ.usbHidUsage), 'KeyQ');
      expect(domCode(PhysicalKeyboardKey.digit5.usbHidUsage), 'Digit5');
      expect(domCode(PhysicalKeyboardKey.metaRight.usbHidUsage), 'MetaRight');
      expect(domCode(PhysicalKeyboardKey.arrowDown.usbHidUsage), 'ArrowDown');
      expect(domCode(PhysicalKeyboardKey.f11.usbHidUsage), 'F11');
      expect(domCode(PhysicalKeyboardKey.capsLock.usbHidUsage), isNull);
    });
  });

  test(
    'macOS: every CoreGraphics symbol the injector uses resolves',
    // Construction looks each one up; nothing is posted.
    () => expect(MacInjector.new, returnsNormally),
    skip: !Platform.isMacOS,
  );
}
