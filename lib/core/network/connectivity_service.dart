import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService extends ChangeNotifier {
  static final ConnectivityService _instance = ConnectivityService._();
  factory ConnectivityService() => _instance;
  ConnectivityService._() {
    _init();
  }

  bool hasConnection = true;

  bool backendReachable = true;

  bool get isOnline => hasConnection && backendReachable;

  final _networkChangedController = StreamController<void>.broadcast();
  Stream<void> get onNetworkChanged => _networkChangedController.stream;

  final _connectivityProbeController = StreamController<void>.broadcast();
  Stream<void> get onConnectivityProbe => _connectivityProbeController.stream;

  Set<ConnectivityResult> _lastResults = {};
  Timer? _debounce;
  static const _debounceDelay = Duration(milliseconds: 400);

  void reportBackendReachable() {
    if (backendReachable) return;
    backendReachable = true;
    notifyListeners();
  }

  void reportBackendUnreachable() {
    if (!backendReachable) return;
    backendReachable = false;
    notifyListeners();
  }

  Future<void> _init() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _lastResults = results.toSet();
      hasConnection = _hasAny(results);
    } catch (_) {}
    Connectivity().onConnectivityChanged.listen((results) {
      if (_hasAny(results)) _connectivityProbeController.add(null);
      _debounce?.cancel();
      _debounce = Timer(_debounceDelay, () => _applyResults(results));
    });
  }

  Future<void> refresh() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _debounce?.cancel();
      _applyResults(results);
    } catch (_) {}
  }

  void _applyResults(List<ConnectivityResult> results) {
    final resultSet = results.toSet();
    final pathChanged = !setEquals(resultSet, _lastResults);
    _lastResults = resultSet;

    final next = _hasAny(results);
    final statusChanged = next != hasConnection;
    if (statusChanged) {
      hasConnection = next;
    }

    if (statusChanged || pathChanged) {
      notifyListeners();
    }

    if (pathChanged && next) {
      _networkChangedController.add(null);
    }
  }

  bool _hasAny(List<ConnectivityResult> results) =>
      results.isNotEmpty && results.any((r) => r != ConnectivityResult.none);
}
