import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_mapper.dart';
import 'package:deskconn_mobile_app/core/operation_result.dart';
import 'package:deskconn_mobile_app/core/wamp/quic_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

class AuthProvider extends ChangeNotifier {
  Session? _session;

  String? pendingEmail;
  String? _pendingPassword;
  String? get pendingPassword => _pendingPassword;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  Future<Session> _getSession() async {
    if (_session == null || !_session!.isConnected()) {
      _session = await QUICConnectionManager().openSession(
        DeskconnConfig.realm,
        QUICDialerConfig(
          authenticator: CryptoSignAuthenticator(DeskconnConfig.mobileAppAuthID, DeskconnConfig.servicePrivateKey),
        ),
      );
    }
    return _session!;
  }

  Future<OperationResult> createAccount({required String email, required String name, required String password}) async {
    _setLoading(true);

    try {
      var session = await _getSession();
      await session
          .call(DeskconnProcedures.accountCreate, args: [email, name, password])
          .timeout(DeskconnConfig.callTimeout);

      pendingEmail = email;
      _pendingPassword = password;

      return const OperationResult.success();
    } catch (e) {
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.signUp,
          fallback: DeskconnErrorMessages.signUpFailed,
        ),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<AccountVerificationResult> verifyOtp(String otp, {required String publicKey}) async {
    if (pendingEmail == null) {
      return const AccountVerificationResult.failure(DeskconnErrorMessages.pendingVerificationMissing);
    }

    try {
      var session = await _getSession();
      final res = await session
          .call(DeskconnProcedures.accountVerify, args: [pendingEmail, otp, publicKey])
          .timeout(DeskconnConfig.callTimeout);

      if (res.args.isEmpty) {
        return const AccountVerificationResult.failure(DeskconnErrorMessages.emptyVerificationResponse);
      }

      final principal = Map<String, dynamic>.from(res.args[0] as Map);
      return AccountVerificationResult.success(principal);
    } catch (e) {
      return AccountVerificationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.accountVerification,
          fallback: DeskconnErrorMessages.verificationFailed,
        ),
      );
    }
  }

  void clearPendingVerification() {
    pendingEmail = null;
    _pendingPassword = null;
    notifyListeners();
  }

  Future<OperationResult> resendOtp() async {
    if (pendingEmail == null) {
      return const OperationResult.failure(DeskconnErrorMessages.pendingVerificationMissing);
    }

    try {
      var session = await _getSession();
      await session.call(DeskconnProcedures.accountOtpResend, args: [pendingEmail]).timeout(DeskconnConfig.callTimeout);
      return const OperationResult.success();
    } catch (e) {
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.accountVerification,
          fallback: DeskconnErrorMessages.resendVerificationCodeFailed,
        ),
      );
    }
  }

  Future<OperationResult> requestPasswordReset(String email) async {
    try {
      var session = await _getSession();
      await session.call(DeskconnProcedures.accountPasswordForget, args: [email]).timeout(DeskconnConfig.callTimeout);

      pendingEmail = email;
      notifyListeners();
      return const OperationResult.success();
    } catch (e) {
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.forgotPassword,
          fallback: DeskconnErrorMessages.resetCodeSendFailed,
        ),
      );
    }
  }

  Future<OperationResult> resetPassword({required String otp, required String newPassword}) async {
    if (pendingEmail == null) {
      return const OperationResult.failure(DeskconnErrorMessages.pendingPasswordResetMissing);
    }

    try {
      var session = await _getSession();
      await session
          .call(DeskconnProcedures.accountPasswordReset, args: [pendingEmail, newPassword, otp])
          .timeout(DeskconnConfig.callTimeout);

      return const OperationResult.success();
    } catch (e) {
      return OperationResult.failure(
        DeskconnErrorMapper.messageFor(
          e,
          context: DeskconnErrorContext.resetPassword,
          fallback: DeskconnErrorMessages.passwordChangeFailed,
        ),
      );
    }
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }
}

class AccountVerificationResult {
  final Map<String, dynamic>? principal;
  final String? error;

  const AccountVerificationResult.success(this.principal) : error = null;
  const AccountVerificationResult.failure(this.error) : principal = null;

  bool get isSuccess => error == null;
}
