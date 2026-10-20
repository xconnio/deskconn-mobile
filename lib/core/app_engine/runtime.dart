import 'package:flutter/foundation.dart';
import 'package:xconn/xconn.dart';

/// Calls [procedure] on the desktop with an optional [arg] and returns its decoded result.
typedef ManifestCaller = Future<dynamic> Function(String procedure, Object? arg);

/// A manifest app as deskconn-userd's manifest.get returns it: app.yaml with its screens
/// resolved to a map by id, and each include replaced by the included block under `block`.
class ManifestApp {
  ManifestApp(this.data);

  final Map<String, dynamic> data;

  Map<String, dynamic> get _app => (data['app'] as Map?)?.cast<String, dynamic>() ?? const {};

  String get id => _app['id']?.toString() ?? '';

  String get name => _app['name']?.toString() ?? id;

  String get keyExchange => (data['api'] as Map?)?['key_exchange']?.toString() ?? '';

  Set<String> get permissions => {for (final p in (data['permissions'] as List? ?? const [])) p.toString()};

  Map<String, dynamic>? screen(String id) => (data['screens'] as Map?)?[id] as Map<String, dynamic>?;

  Map<String, dynamic>? get entryScreen => screen(data['entry_screen']?.toString() ?? '');
}

/// Reads a dotted [path] such as `state.muted` from [scope]. Missing paths read null.
dynamic readPath(Map<String, dynamic> scope, String path) {
  dynamic node = scope;
  for (final part in path.split('.')) {
    if (node is! Map) return null;
    node = node[part];
  }
  return node;
}

/// Evaluates a manifest value: `{bind: path}` reads [scope], `{when, then, else}` picks a
/// branch (anything but true selects else), and anything else is a literal.
dynamic evaluate(dynamic value, Map<String, dynamic> scope) {
  if (value is Map) {
    if (value.containsKey('bind')) return readPath(scope, value['bind'].toString());
    if (value.containsKey('when')) {
      return evaluate(evaluate(value['when'], scope) == true ? value['then'] : value['else'], scope);
    }
  }
  return value;
}

/// Whether a child with [visible] shows, given the renderer's [context].
bool isVisible(dynamic visible, Map<String, dynamic> context) =>
    visible == null || evaluate(visible, {'context': context}) == true;

/// A mounted block: its state, and the actions of its `on_mount` and component.
class BlockController extends ChangeNotifier {
  BlockController({
    required Map<String, dynamic> block,
    required this.context,
    required this.caller,
    required this.permissions,
  }) : _block = block,
       state = Map<String, dynamic>.of((block['state'] as Map?)?.cast<String, dynamic>() ?? const {});

  final Map<String, dynamic> _block;
  final Map<String, dynamic> context;
  final ManifestCaller caller;
  final Set<String> permissions;
  final Map<String, dynamic> state;

  /// Whether a call is in flight. The renderer shows loading and disables the block.
  bool busy = false;

  /// The last failed call that had no on_error, shown by the renderer.
  Object? error;

  bool _disposed = false;

  Map<String, dynamic> get component => (_block['component'] as Map?)?.cast<String, dynamic>() ?? const {};

  Map<String, dynamic> get _scope => {'state': state, 'context': context};

  /// Evaluates [value] against the block's state and context.
  dynamic eval(dynamic value) => evaluate(value, _scope);

  /// Runs `on_mount`, if any.
  Future<void> mount() => _run(_block['on_mount'], _scope);

  /// Runs the component's `on_activate`, unless a call is already in flight.
  Future<void> activate() async {
    if (busy) return;
    await _run(component['on_activate'], _scope);
  }

  Future<void> _run(dynamic action, Map<String, dynamic> scope) async {
    if (action is! Map || _disposed) return;

    final set = action['set'];
    if (set is Map) {
      for (final entry in set.entries) {
        state[entry.key.toString()] = evaluate(entry.value, scope);
      }
      _notify();
    }

    final procedure = action['call'];
    if (procedure is! String) return;
    if (!permissions.contains(procedure)) {
      error = '$procedure is not in the app\'s permissions';
      _notify();
      return;
    }

    busy = true;
    error = null;
    _notify();
    try {
      final result = await caller(procedure, action.containsKey('arg') ? evaluate(action['arg'], scope) : null);
      if (_disposed) return;
      busy = false;
      await _run(action['on_result'], {...scope, 'result': result});
    } catch (e) {
      if (_disposed) return;
      busy = false;
      if (action['on_error'] is Map) {
        await _run(action['on_error'], {
          ...scope,
          'error': {'uri': e is ApplicationError ? e.message : e.toString()},
        });
      } else {
        error = e;
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
