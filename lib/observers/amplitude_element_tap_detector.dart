import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../amplitude.dart';
import '../events/base_event.dart';
import 'amplitude_navigator_observer.dart'
    show AmplitudeNavigatorObserver, screenNameProperty;

/// Event type for autocaptured element interactions. Matches the native
/// iOS/Android SDK element interaction event so events unify in the
/// Amplitude UI.
const String elementInteractedEventType = '[Amplitude] Element Interacted';

/// Event property key for the interaction kind (always `touch`).
const String elementActionProperty = '[Amplitude] Action';

/// Event property key for the tapped widget's type.
///
/// Carries the runtime type when the build keeps class names, and a stable
/// role (see [_stableTargetClass]) when the build renames them. The property
/// is omitted when neither name is usable, so it never reports a symbol that
/// changes on the next release.
const String elementTargetClassProperty = '[Amplitude] Target Class';

/// Event property key for the human-readable label of the tapped widget.
const String elementTargetTextProperty = '[Amplitude] Target Text';

/// Event property key for the developer-assigned [ValueKey] of the tapped
/// widget, when present.
const String elementTargetResourceProperty = '[Amplitude] Target Resource';

/// Event property key identifying the UI framework that produced the event.
const String elementTargetSourceProperty = '[Amplitude] Target Source';

/// Event property key for the widget-type hierarchy above the tapped widget.
const String elementHierarchyProperty = '[Amplitude] Hierarchy';

/// Maximum length of the reported target text.
const int _maxTargetTextLength = 128;

/// Maximum number of widget types reported in the hierarchy.
const int _maxHierarchyDepth = 10;

/// Maximum number of elements visited when deriving a target label.
const int _maxLabelSearchNodes = 256;

/// Probe type used to detect renamed class names. It is private to this
/// library and never referenced elsewhere, so a build that keeps class names
/// spells it out in full.
class _MinificationProbe {}

/// Whether this build renames Dart class names.
///
/// `dart2js` renames classes in every Flutter web profile and release build,
/// and `flutter build --obfuscate` does the same on mobile. `runtimeType`
/// then returns a short symbol such as `iKa` or `minified:tp`, and the symbol
/// changes on each compile. A property built from it is unreadable, and it
/// churns on every release, which silently breaks each saved chart, cohort or
/// labeled event that filters on it.
///
/// Type checks (`is`) survive the rename, so [_stableTargetClass] reports a
/// role derived from them instead.
final bool _classNamesAreRenamed =
    _MinificationProbe().runtimeType.toString() != '_MinificationProbe';

/// A stable, human-readable class name for [w], derived from type checks.
///
/// Returns `null` for a widget type the detector does not know. Every widget
/// [_findTarget] reports ranks above zero in [_targetRank], so a reported
/// target always resolves here. The order matches [_targetRank], so the two
/// always agree on what a widget is.
String? _stableTargetClass(Widget w) {
  if (w is ButtonStyleButton) return 'ButtonStyleButton';
  if (w is MaterialButton) return 'MaterialButton';
  if (w is IconButton) return 'IconButton';
  if (w is FloatingActionButton) return 'FloatingActionButton';
  if (w is CupertinoButton) return 'CupertinoButton';
  if (w is CheckboxListTile) return 'CheckboxListTile';
  if (w is SwitchListTile) return 'SwitchListTile';
  if (w is ListTile) return 'ListTile';
  if (w is Checkbox) return 'Checkbox';
  if (w is Switch) return 'Switch';
  if (w is PopupMenuButton) return 'PopupMenuButton';
  if (w is DropdownButton) return 'DropdownButton';
  if (w is TextField) return 'TextField';
  if (w is InkWell) return 'InkWell';
  if (w is InkResponse) return 'InkResponse';
  if (w is GestureDetector) return 'GestureDetector';
  return null;
}

/// The reported class name for [w].
///
/// Prefers the real runtime type, which is the most precise name available.
/// Falls back to the stable role when this build renames class names, because
/// the renamed symbol identifies nothing and does not survive the next
/// release. Returns `null` when neither name is usable, so the caller omits
/// the property rather than reporting a symbol that churns.
String? _describeTargetClass(Widget w) {
  if (!_classNamesAreRenamed) return w.runtimeType.toString();
  return _stableTargetClass(w);
}

/// Whether this build renames Dart class names. Test-only view of
/// [_classNamesAreRenamed].
@visibleForTesting
bool get debugClassNamesAreRenamed => _classNamesAreRenamed;

/// The stable role reported for [w] on a build that renames class names.
/// Test-only view of [_stableTargetClass].
@visibleForTesting
String? debugStableTargetClass(Widget w) => _stableTargetClass(w);

/// Decides whether a tapped widget should be reported. Return `false` to
/// exclude [widget] and everything inside it from reporting; an interactive
/// ancestor outside the excluded widget is still reported, if any.
typedef ElementTargetFilter = bool Function(Widget widget);

/// Supplies the screen name attached to element interaction events.
typedef ScreenNameProvider = String? Function();

/// Supplies extra event properties merged into every element interaction
/// event (e.g. organization/tenant context).
typedef ElementPropertiesProvider = Map<String, Object?> Function();

/// Default [ScreenNameProvider]: the most recent screen tracked by an
/// [AmplitudeNavigatorObserver].
String? defaultScreenNameProvider() =>
    AmplitudeNavigatorObserver.currentScreenName;

/// Autocaptures taps on interactive Flutter widgets as
/// `[Amplitude] Element Interacted` events.
///
/// A Flutter app renders every widget itself — natively it is a single view
/// (one `FlutterActivity`/`FlutterViewController`, or a canvas on web), so
/// neither the native SDKs' element interaction autocapture nor the Browser
/// SDK's DOM click capture can see individual widgets. This widget closes
/// that gap in Dart: wrap your app with it and taps on buttons, list tiles,
/// toggles, `InkWell`s, and `GestureDetector`s are captured on every
/// platform, including web.
///
/// ```dart
/// runApp(AmplitudeElementTapDetector(
///   amplitude: amplitude,
///   child: const MyApp(),
/// ));
/// ```
///
/// On each qualifying tap (a primary-button pointer that goes down and up
/// within the touch slop) the widget walks its element tree along the tap
/// position and reports the deepest interactive widget hit. Concrete
/// controls (buttons, tiles, toggles) take precedence over the generic
/// gesture handlers they are built from, so an `ElevatedButton` is reported
/// as `ElevatedButton`, not as its internal `InkWell`. Mounted-but-hidden
/// subtrees (`Offstage`, invisible `Visibility`, and therefore the inactive
/// children of a keep-alive `IndexedStack`) are never reported.
///
/// Reported properties:
/// * `[Amplitude] Action` — always `touch`.
/// * `[Amplitude] Target Class` — the widget's runtime type, or a stable
///   role such as `ButtonStyleButton` when the build renames class names
///   (`dart2js`, or `--obfuscate`). Omitted when neither name is usable.
/// * `[Amplitude] Target Text` — the widget's `Semantics` label, `Tooltip`
///   message, or descendant `Text` content (first available, in that order).
/// * `[Amplitude] Target Resource` — the widget's [ValueKey] value, if any.
/// * `[Amplitude] Hierarchy` — up to 10 non-private ancestor widget types.
///   A build that renames class names contributes only the recognized
///   types; the property is omitted when none remain.
/// * `[Amplitude] Screen Name` — from [screenNameProvider]; by default the
///   last screen tracked by an [AmplitudeNavigatorObserver].
/// * `[Amplitude] Target Source` — always `Flutter`.
///
/// Capture is controlled by constructing this widget (plus [enabled]) and is
/// deliberately independent of the `elementInteractions` autocapture option:
/// that option configures the Browser SDK's DOM capture, which on Flutter
/// web only ever sees the framework's canvas host elements. Typical Flutter
/// web setups disable the DOM capture and use this widget instead. If both
/// are enabled on web, taps may be reported twice (once per mechanism).
///
/// Analytics must never interfere with the app: all capture work runs after
/// the tap is released, never blocks gesture handling, and any internal
/// failure is swallowed (surfaced as a debug-mode log only).
///
/// Widgets without discoverable text (e.g. a custom-painted icon inside a
/// `GestureDetector`) report only their type. Give key interactive widgets a
/// `Semantics` label, `Tooltip`, or [ValueKey] to make their events
/// identifiable — this also improves accessibility.
class AmplitudeElementTapDetector extends StatefulWidget {
  const AmplitudeElementTapDetector({
    super.key,
    required this.amplitude,
    required this.child,
    this.enabled = true,
    this.targetFilter,
    this.screenNameProvider = defaultScreenNameProvider,
    this.propertiesProvider,
  });

  /// The Amplitude instance element interaction events are tracked with.
  final Amplitude amplitude;

  /// The subtree (typically the whole app) whose taps are captured.
  final Widget child;

  /// Whether capture is active. When `false` the widget only passes events
  /// through to [child].
  final bool enabled;

  /// Optional veto over which widgets are reported.
  final ElementTargetFilter? targetFilter;

  /// Supplies the `[Amplitude] Screen Name` property.
  final ScreenNameProvider? screenNameProvider;

  /// Supplies extra properties merged into every captured event.
  final ElementPropertiesProvider? propertiesProvider;

  @override
  State<AmplitudeElementTapDetector> createState() =>
      _AmplitudeElementTapDetectorState();
}

class _AmplitudeElementTapDetectorState
    extends State<AmplitudeElementTapDetector> {
  /// Pointer-down positions by pointer id, to distinguish taps from drags.
  final Map<int, Offset> _downPositions = {};

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled) {
      return;
    }
    if (event.buttons & kPrimaryButton == 0) {
      return;
    }
    // Defensive bound: up/cancel normally clears entries, but never let a
    // platform quirk grow this map without limit.
    if (_downPositions.length > 20) {
      _downPositions.clear();
    }
    _downPositions[event.pointer] = event.position;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _downPositions.remove(event.pointer);
  }

  void _onPointerUp(PointerUpEvent event) {
    final downPosition = _downPositions.remove(event.pointer);
    if (!widget.enabled || downPosition == null) {
      return;
    }
    if ((event.position - downPosition).distance > kTouchSlop) {
      return; // A drag or scroll, not a tap.
    }
    // Analytics must never interfere with the app, so any failure while
    // resolving or tracking the target is swallowed and surfaced only in
    // debug builds.
    try {
      final target = _findTarget(event.position);
      if (target == null) {
        return;
      }
      _trackTap(target);
    } catch (error, stackTrace) {
      _onTrackError(error, stackTrace);
    }
  }

  /// Walks the element tree along [position] and returns the deepest
  /// interactive element hit, preferring concrete controls over the generic
  /// gesture handlers they are built from.
  Element? _findTarget(Offset position) {
    Element? best;
    var bestRank = 0;

    void visit(Element element) {
      // Mounted-but-hidden subtrees keep real geometry but are not painted,
      // so they must never claim a tap over the visible widget the user
      // actually saw. This covers keep-alive tab bodies — IndexedStack wraps
      // inactive children in Visibility.maintain(visible: false) and its
      // render object hit-tests only the active child — and Offstage widgets
      // (which keep their incoming size under tight constraints).
      final w = element.widget;
      if (w is Visibility && !w.visible) {
        return;
      }
      if (w is Offstage && w.offstage) {
        return;
      }
      final renderObject = element.renderObject;
      if (renderObject is RenderBox) {
        if (!renderObject.attached || !renderObject.hasSize) {
          return;
        }
        if (!renderObject.size.contains(renderObject.globalToLocal(position))) {
          return;
        }
      }
      // Non-box render objects (slivers) and elements with no render object
      // are descended into without pruning.
      final rank = _targetRank(w);
      if (rank > 0) {
        if (!(widget.targetFilter?.call(w) ?? true)) {
          return; // Vetoed: exclude this widget and its internals entirely.
        }
        if (rank >= bestRank) {
          best = element;
          bestRank = rank;
        }
      }
      element.visitChildElements(visit);
    }

    (context as Element).visitChildElements(visit);
    return best;
  }

  /// Ranks how specifically [w] identifies an interaction target.
  ///
  /// Returns 0 for non-interactive widgets. Concrete controls rank above the
  /// generic handlers (`InkResponse`, `GestureDetector`) they are built
  /// from, so during the deepest-wins descent a control is not displaced by
  /// its own internals, while a deeper control nested inside another (e.g.
  /// an `IconButton` inside a `ListTile`) still wins.
  int _targetRank(Widget w) {
    // Private widgets are framework/library internals (e.g. Material 3's
    // IconButton builds a private ButtonStyleButton subclass). Reporting
    // them would displace the public widget the developer actually wrote.
    if (w.runtimeType.toString().startsWith('_')) {
      return 0;
    }
    if (w is ButtonStyleButton) {
      return (w.onPressed != null || w.onLongPress != null) ? 2 : 0;
    }
    if (w is MaterialButton) {
      return (w.onPressed != null || w.onLongPress != null) ? 2 : 0;
    }
    if (w is IconButton) {
      return w.onPressed != null ? 2 : 0;
    }
    if (w is FloatingActionButton) {
      return w.onPressed != null ? 2 : 0;
    }
    if (w is CupertinoButton) {
      return w.onPressed != null ? 2 : 0;
    }
    if (w is ListTile) {
      return (w.onTap != null || w.onLongPress != null) ? 2 : 0;
    }
    if (w is CheckboxListTile) {
      return w.onChanged != null ? 2 : 0;
    }
    if (w is SwitchListTile) {
      return w.onChanged != null ? 2 : 0;
    }
    if (w is Checkbox) {
      return w.onChanged != null ? 2 : 0;
    }
    if (w is Switch) {
      return w.onChanged != null ? 2 : 0;
    }
    if (w is PopupMenuButton) {
      return w.enabled ? 2 : 0;
    }
    if (w is DropdownButton) {
      return w.onChanged != null ? 2 : 0;
    }
    if (w is TextField) {
      return (w.enabled ?? true) ? 2 : 0;
    }
    if (w is InkResponse) {
      // Includes InkWell.
      return (w.onTap != null || w.onLongPress != null || w.onDoubleTap != null)
          ? 1
          : 0;
    }
    if (w is GestureDetector) {
      return (w.onTap != null ||
              w.onTapUp != null ||
              w.onTapDown != null ||
              w.onLongPress != null ||
              w.onDoubleTap != null)
          ? 1
          : 0;
    }
    return 0;
  }

  /// Derives a human-readable label for [target]: its `Semantics` label,
  /// `Tooltip` message, or descendant `Text` content, in that order.
  String? _describeTarget(Element target) {
    String? semanticsLabel;
    String? tooltip;
    String? text;
    var visited = 0;

    void visit(Element element) {
      if (semanticsLabel != null || visited >= _maxLabelSearchNodes) {
        return;
      }
      visited++;
      final w = element.widget;
      if (w is Semantics) {
        final label = w.properties.label;
        if (label != null && label.isNotEmpty) {
          semanticsLabel = label;
          return;
        }
      } else if (w is Tooltip) {
        final message = w.message;
        if (message != null && message.isNotEmpty) {
          tooltip ??= message;
        }
      } else if (w is Text) {
        final data = w.data ?? w.textSpan?.toPlainText();
        if (data != null && data.isNotEmpty) {
          text ??= data;
        }
      } else if (w is RichText) {
        final data = w.text.toPlainText();
        if (data.isNotEmpty) {
          text ??= data;
        }
      } else if (w is Icon) {
        final label = w.semanticLabel;
        if (label != null && label.isNotEmpty) {
          tooltip ??= label;
        }
      }
      element.visitChildElements(visit);
    }

    visit(target);
    final label = semanticsLabel ?? tooltip ?? text;
    if (label == null) {
      return null;
    }
    final normalized = label.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized.length > _maxTargetTextLength
        ? normalized.substring(0, _maxTargetTextLength)
        : normalized;
  }

  /// Collects up to [_maxHierarchyDepth] non-private widget types from
  /// [target] upward, target first.
  ///
  /// A build that renames class names contributes only the types
  /// [_stableTargetClass] knows. The renamed symbol of an app widget names
  /// nothing and changes on the next release, and the private-name filter
  /// below cannot see it either, because a renamed private class no longer
  /// starts with an underscore.
  List<String> _hierarchy(Element target) {
    final names = <String>[];
    void add(Widget w) {
      if (_classNamesAreRenamed) {
        final role = _stableTargetClass(w);
        if (role != null) {
          names.add(role);
        }
        return;
      }
      final name = w.runtimeType.toString();
      if (!name.startsWith('_')) {
        names.add(name);
      }
    }

    add(target.widget);
    target.visitAncestorElements((element) {
      if (names.length >= _maxHierarchyDepth) {
        return false;
      }
      add(element.widget);
      return true;
    });
    return names;
  }

  void _trackTap(Element target) {
    final targetWidget = target.widget;
    final targetText = _describeTarget(target);
    final key = targetWidget.key;
    final resource = key is ValueKey ? key.value?.toString() : null;
    final screenName = widget.screenNameProvider?.call();
    final targetClass = _describeTargetClass(targetWidget);
    final hierarchy = _hierarchy(target);

    final properties = <String, Object?>{
      elementActionProperty: 'touch',
      if (targetClass != null) elementTargetClassProperty: targetClass,
      if (targetText != null) elementTargetTextProperty: targetText,
      if (resource != null && resource.isNotEmpty)
        elementTargetResourceProperty: resource,
      elementTargetSourceProperty: 'Flutter',
      if (hierarchy.isNotEmpty) elementHierarchyProperty: hierarchy,
      if (screenName != null && screenName.isNotEmpty)
        screenNameProperty: screenName,
      ...?widget.propertiesProvider?.call(),
    };

    unawaited(
      widget.amplitude
          .track(BaseEvent(
            elementInteractedEventType,
            eventProperties: properties,
          ))
          .catchError(_onTrackError),
    );
  }

  void _onTrackError(Object error, StackTrace stackTrace) {
    assert(() {
      debugPrint('AmplitudeElementTapDetector: failed to track '
          '$elementInteractedEventType: $error');
      return true;
    }());
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.child,
    );
  }
}
