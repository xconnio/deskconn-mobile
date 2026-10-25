import 'dart:async';
import 'dart:io';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/device/cryptosign_keys.dart';
import 'package:deskconn_mobile_app/core/device/device_identity.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_mapper.dart';
import 'package:deskconn_mobile_app/core/operation_result.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/quic_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/wamp_client.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionProvider extends ChangeNotifier {
  final _client = WampClient();

  Session? session;
  Session? _signInSession;
  Map<String, dynamic>? account;
  String? error;

  Future<Session>? _reconnecting;

  Future<Session> _ensureSession() {
    final current = session;
    if (current != null && current.isConnected()) return Future.value(current);
    return _reconnecting ??= _reconnect().whenComplete(() => _reconnecting = null);
  }

  Future<Session> _reconnect() async {
    final privateKey = await DeviceIdentity.privateKey();
    final email = await DeviceIdentity.lastEmail();
    if (privateKey == null || email == null) {
      throw Exception('No stored credentials to reconnect with');
    }

    final newSession = await _client.connectCryptoSign(
      authId: email,
      privateKey: privateKey,
      realm: DeskconnConfig.realm,
    );
    session = newSession;
    notifyListeners();
    return newSession;
  }

  bool _isLoading = false;
  bool loggedIn = false;

  bool get isLoading => _isLoading;

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  void updateAccount(Map<String, dynamic> newAccountData) {
    account = newAccountData;
    notifyListeners();
  }

  List<Map<String, dynamic>> desktops = [];
  bool desktopsLoading = false;

  Future<void> _closeSignInSession() async {
    final current = _signInSession;
    _signInSession = null;

    try {
      await current?.close();
    } catch (_) {}
  }

  Future<void> _resetSignedInState({bool clearIdentity = false}) async {
    try {
      await session?.close();
    } catch (_) {}

    if (clearIdentity) {
      try {
        await DeviceIdentity.clear();
      } catch (_) {}
    }

    session = null;
    account = null;
    desktops.clear();
    loggedIn = false;
    notifyListeners();
  }

  Future<Session> _openSignInSession({required String email, required String password}) async {
    await _closeSignInSession();
    final nextSession = await _client.connectCra(email: email, password: password, realm: DeskconnConfig.realm);
    _signInSession = nextSession;
    return nextSession;
  }

  Future<OperationResult> requestSignInOtp(String email, String password) async {
    error = null;
    _setLoading(true);

    try {
      final authSession = await _openSignInSession(email: email, password: password);
      await authSession.call(DeskconnProcedures.accountLogin, args: [email]).timeout(DeskconnConfig.callTimeout);

      return const OperationResult.success();
    } catch (e, st) {
      debugPrint('requestSignInOtp failed: $e');
      debugPrint('$st');
      await _closeSignInSession();
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.signIn,
          fallback: DeskconnErrorMessages.signInFailed,
        ),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<OperationResult> resendSignInOtp(String email) async {
    error = null;
    _setLoading(true);

    try {
      final authSession = _signInSession;
      if (authSession == null || !authSession.isConnected()) {
        return const OperationResult.failure(DeskconnErrorMessages.signInSessionExpired);
      }

      await authSession.call(DeskconnProcedures.accountLogin, args: [email]).timeout(DeskconnConfig.callTimeout);

      return const OperationResult.success();
    } catch (e) {
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.signInOtp,
          fallback: DeskconnErrorMessages.resendVerificationCodeFailed,
        ),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<OperationResult> verifySignInOtp({required String email, required String otp}) async {
    error = null;
    _setLoading(true);

    try {
      final keys = await DeviceIdentity.ensureKeyPair();
      final authSession = _signInSession;
      if (authSession == null || !authSession.isConnected()) {
        throw Exception('Sign-in session expired. Please sign in again.');
      }

      final publicKey = keys['publicKey']!;

      final principalRes = await authSession
          .call(DeskconnProcedures.accountLoginVerify, args: [email, otp, publicKey])
          .timeout(DeskconnConfig.callTimeout);

      if (principalRes.args.isEmpty) {
        throw Exception("Empty login verification response");
      }

      final principal = Map<String, dynamic>.from(principalRes.args[0] as Map);

      await _closeSignInSession();

      await _completePrincipalSignIn(email: email, keys: keys, principal: principal);
      return const OperationResult.success();
    } catch (e) {
      await _resetSignedInState();
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.signInOtp,
          fallback: DeskconnErrorMessages.invalidSignInCode,
        ),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<OperationResult> completeRegistrationSignIn({
    required String email,
    required Map<String, String> keys,
    required Map<String, dynamic> principal,
  }) async {
    error = null;
    _setLoading(true);

    try {
      await _completePrincipalSignIn(email: email, keys: keys, principal: principal);
      return const OperationResult.success();
    } catch (e) {
      await _resetSignedInState(clearIdentity: true);
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.accountVerification,
          fallback: DeskconnErrorMessages.verificationSignInFailed,
        ),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _completePrincipalSignIn({
    required String email,
    required Map<String, String> keys,
    required Map<String, dynamic> principal,
  }) async {
    final principalId = principal['id']?.toString();
    if (principalId == null || principalId.isEmpty) {
      throw Exception("Principal ID not found in response");
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomSuffix = DateTime.now().microsecondsSinceEpoch;
    final deviceName = 'android-$timestamp-$randomSuffix';
    final deviceModel = await _getDeviceModel();
    var identitySaveStarted = false;

    try {
      final newSession = await _client.connectCryptoSign(
        authId: email,
        privateKey: keys['privateKey']!,
        realm: DeskconnConfig.realm,
      );

      final accountRes = await newSession.call(DeskconnProcedures.accountGet).timeout(DeskconnConfig.callTimeout);

      if (accountRes.args.isEmpty) {
        throw Exception("Empty account response");
      }

      session = newSession;
      account = Map<String, dynamic>.from(accountRes.args[0] as Map);

      identitySaveStarted = true;
      await DeviceIdentity.save(
        deviceId: principalId,
        privateKey: keys['privateKey']!,
        publicKey: keys['publicKey']!,
        email: email,
        deviceName: deviceName,
        deviceModel: deviceModel,
        expiresAt: principal['expires_at']?.toString(),
      );

      await loadDesktops();

      loggedIn = true;
      notifyListeners();
    } catch (_) {
      if (identitySaveStarted) {
        try {
          await DeviceIdentity.clear();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static const _principalRotateThreshold = Duration(days: 5);

  Future<void> _rotatePrincipalIfExpiringSoon(Session s) async {
    final expiresAt = await DeviceIdentity.principalExpiresAt();
    if (expiresAt == null) return;
    if (expiresAt.difference(DateTime.now()) > _principalRotateThreshold) return;

    try {
      final oldPublicKey = await DeviceIdentity.publicKey();
      if (oldPublicKey == null) return;

      final newPrivateKey = await CryptoSignKeys.generatePrivateKey();
      final newPublicKey = await CryptoSignKeys.derivePublicKey(newPrivateKey);

      final res = await s
          .call(DeskconnProcedures.accountPrincipalRotate, args: [oldPublicKey, newPublicKey])
          .timeout(DeskconnConfig.callTimeout);

      final newExpiresAt = res.args.isEmpty ? null : (res.args[0] as Map)['expires_at']?.toString();

      await DeviceIdentity.updateKeyPair(privateKey: newPrivateKey, publicKey: newPublicKey, expiresAt: newExpiresAt);
    } catch (e) {
      debugPrint('Principal rotation failed: $e');
    }
  }

  Future<void> initialize() async {
    _setLoading(true);

    try {
      await DeviceIdentity.ensureKeyPair();
      final hasIdentity = await DeviceIdentity.exists();

      if (!hasIdentity) {
        loggedIn = false;
      } else {
        final privateKey = await DeviceIdentity.privateKey();
        final email = await DeviceIdentity.lastEmail();

        if (privateKey != null && email != null) {
          session = await _client.connectCryptoSign(authId: email, privateKey: privateKey, realm: DeskconnConfig.realm);

          final res = await session!.call(DeskconnProcedures.accountGet).timeout(DeskconnConfig.callTimeout);
          if (res.args.isEmpty) throw Exception("Empty account");

          account = Map<String, dynamic>.from(res.args[0] as Map);

          await _rotatePrincipalIfExpiringSoon(session!);

          await loadDesktops();

          loggedIn = true;
        } else {
          loggedIn = false;
        }
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
      session = null;
      account = null;
      desktops.clear();
      loggedIn = false;
    }

    _setLoading(false);
  }

  Future<void> loadDesktops() async {
    if (session == null) return;

    desktopsLoading = true;
    notifyListeners();

    try {
      final s = await _ensureSession();
      final res = await s.call(DeskconnProcedures.desktopList).timeout(DeskconnConfig.callTimeout);
      desktops = res.args.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      error = "Failed to load desktops";
    } finally {
      desktopsLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    try {
      await DesktopConnectionManager().invalidateAll();
    } catch (_) {}

    try {
      final publicKey = await DeviceIdentity.publicKey();
      if (publicKey != null) {
        try {
          await session
              ?.call(DeskconnProcedures.accountPrincipalDelete, args: [publicKey])
              .timeout(DeskconnConfig.callTimeout);
        } catch (_) {}
      }
      await session?.close();
      await _closeSignInSession();
    } catch (_) {}

    try {
      await QUICConnectionManager().close();
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}

    try {
      await DeviceIdentity.clear();
    } catch (_) {}

    session = null;
    _signInSession = null;
    account = null;
    desktops.clear();

    loggedIn = false;
    _setLoading(false);

    notifyListeners();
  }

  Future<String> _getDeviceModel() async {
    final deviceInfoPlugin = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        return androidInfo.model;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        return iosInfo.model;
      }
    } catch (e) {
      error = "Error getting device model";
    }

    return Platform.operatingSystem;
  }
}
