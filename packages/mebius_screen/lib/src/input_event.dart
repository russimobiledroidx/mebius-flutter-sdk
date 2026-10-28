/// One remote-control input, in the wire shape the engine relays:
/// `move`/`down`/`up` carry `x`,`y` (0..1 of the shared screen), `down`/`up`
/// a `button` (`left`, `right`, `middle`), `wheel` carries `dx`/`dy`, and
/// `keydown`/`keyup` a `KeyboardEvent.code` such as `KeyA` or `ShiftLeft`.
class MebiusInputEvent {
  /// Creates an input event. Which fields apply depends on [type].
  const MebiusInputEvent(
    this.type, {
    this.x,
    this.y,
    this.button,
    this.dx,
    this.dy,
    this.key,
  });

  /// Reads one event from the engine's JSON. Unknown fields are ignored.
  factory MebiusInputEvent.fromJson(Map<String, dynamic> json) =>
      MebiusInputEvent(
        json['type'] as String? ?? '',
        x: (json['x'] as num?)?.toDouble(),
        y: (json['y'] as num?)?.toDouble(),
        button: json['button'] as String?,
        dx: (json['dx'] as num?)?.toInt(),
        dy: (json['dy'] as num?)?.toInt(),
        key: json['key'] as String?,
      );

  /// `move`, `down`, `up`, `wheel`, `keydown` or `keyup`.
  final String type;

  /// Horizontal position, 0 (left) to 1 (right) of the shared screen.
  final double? x;

  /// Vertical position, 0 (top) to 1 (bottom) of the shared screen.
  final double? y;

  /// `left`, `right` or `middle`, for `down`/`up`.
  final String? button;

  /// Horizontal wheel delta, DOM convention (positive scrolls right).
  final int? dx;

  /// Vertical wheel delta, DOM convention (positive scrolls down).
  final int? dy;

  /// The physical key, as `KeyboardEvent.code`.
  final String? key;

  /// The JSON the input endpoint takes, without absent fields.
  Map<String, dynamic> toJson() => {
        'type': type,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (button != null) 'button': button,
        if (dx != null) 'dx': dx,
        if (dy != null) 'dy': dy,
        if (key != null) 'key': key,
      };

  @override
  String toString() => 'MebiusInputEvent(${toJson()})';
}
