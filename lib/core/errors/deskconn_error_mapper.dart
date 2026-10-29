import 'dart:async';

import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_uris.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

enum DeskconnErrorContext {
  signIn,
  standaloneSignIn,
  signInOtp,
  signUp,
  accountVerification,
  forgotPassword,
  resetPassword,
  generalAuth,
}

class DeskconnErrorMapper {
  const DeskconnErrorMapper._();

  static const _genericMessages = {
    DeskconnErrorUris.userExists: 'An account with this email already exists.',
    DeskconnErrorUris.userNotFound: 'Account not found.',
    DeskconnErrorUris.deviceExists: 'This device is already registered.',
    DeskconnErrorUris.deviceNotFound: 'This device could not be found.',
    DeskconnErrorUris.userOtpInvalid: 'The code is invalid or expired.',
    DeskconnErrorUris.userOtpCooldown: 'Please wait before requesting another code.',
    DeskconnErrorUris.userOtpLimitExceeded: 'Too many code requests. Please try again later.',
    DeskconnErrorUris.userOtpTooManyAttempts: 'Too many incorrect attempts. Please request a new code.',
    DeskconnErrorUris.userAlreadyVerified: 'This account is already verified.',
    DeskconnErrorUris.userNotVerified: 'Please verify your email before signing in.',
    DeskconnErrorUris.desktopExists: 'This desktop is already linked.',
    DeskconnErrorUris.desktopNotFound: 'Desktop not found.',
    DeskconnErrorUris.organizationNotFound: 'Organization not found.',
    DeskconnErrorUris.userNotAuthorized: 'You are not authorized to perform this action.',
    DeskconnErrorUris.userAlreadyMember: 'This user already has access.',
    DeskconnErrorUris.invitationAlreadySent: 'An invitation has already been sent.',
    DeskconnErrorUris.invitationInvalid: 'This invitation is no longer valid.',
    DeskconnErrorUris.invitationExpired: 'This invitation has expired.',
    DeskconnErrorUris.invitationNotFound: 'Invitation not found.',
    DeskconnErrorUris.internalError: 'We could not complete the request. Please try again.',
    DeskconnErrorUris.authenticationFailed: 'Authentication failed. Please try again.',
    DeskconnErrorUris.principalExists: 'This device is already linked to an account.',
    DeskconnErrorUris.notFound: 'The requested item could not be found.',
    DeskconnErrorUris.appVersionExists: 'This app version already exists.',
    DeskconnErrorUris.desktopAccessNotFound: 'Desktop access could not be found.',
  };

  static const _authMessages = {
    DeskconnErrorContext.signIn: {
      DeskconnErrorUris.authenticationFailed: 'Invalid email or password.',
      DeskconnErrorUris.userNotFound: 'Invalid email or password.',
      DeskconnErrorUris.userNotVerified: 'Please verify your email before signing in.',
    },
    DeskconnErrorContext.standaloneSignIn: {
      DeskconnErrorUris.authenticationFailed: 'Invalid username, password or key.',
    },
    DeskconnErrorContext.signInOtp: {
      DeskconnErrorUris.userOtpInvalid: 'The sign-in code is invalid or expired.',
      DeskconnErrorUris.userOtpTooManyAttempts: 'Too many incorrect attempts. Please request a new sign-in code.',
      DeskconnErrorUris.userOtpCooldown: 'Please wait before requesting another sign-in code.',
      DeskconnErrorUris.userOtpLimitExceeded: 'Too many sign-in code requests. Please try again later.',
      DeskconnErrorUris.userNotFound: 'Invalid email or password.',
    },
    DeskconnErrorContext.signUp: {
      DeskconnErrorUris.userExists: 'An account with this email already exists.',
      DeskconnErrorUris.authenticationFailed: DeskconnErrorMessages.signUpFailedWithRetry,
    },
    DeskconnErrorContext.accountVerification: {
      DeskconnErrorUris.userOtpInvalid: 'The verification code is invalid or expired.',
      DeskconnErrorUris.userOtpTooManyAttempts: 'Too many incorrect attempts. Please request a new verification code.',
      DeskconnErrorUris.userOtpCooldown: 'Please wait before requesting another verification code.',
      DeskconnErrorUris.userOtpLimitExceeded: 'Too many verification code requests. Please try again later.',
      DeskconnErrorUris.userAlreadyVerified: 'This account is already verified. Please sign in.',
    },
    DeskconnErrorContext.forgotPassword: {
      DeskconnErrorUris.userOtpCooldown: 'Please wait before requesting another reset code.',
      DeskconnErrorUris.userOtpLimitExceeded: 'Too many reset code requests. Please try again later.',
      DeskconnErrorUris.userNotFound: 'If this email is registered, a reset code will be sent.',
    },
    DeskconnErrorContext.resetPassword: {
      DeskconnErrorUris.userOtpInvalid: 'The reset code is invalid or expired.',
      DeskconnErrorUris.userOtpTooManyAttempts: 'Too many incorrect attempts. Please request a new reset code.',
      DeskconnErrorUris.userNotFound: 'We could not reset the password for this account.',
    },
  };

  static String messageFor(
    Object error, {
    DeskconnErrorContext context = DeskconnErrorContext.generalAuth,
    String fallback = DeskconnErrorMessages.defaultError,
  }) {
    final uri = _uriFor(error);
    if (uri != null) {
      return _authMessages[context]?[uri] ?? _genericMessages[uri] ?? fallback;
    }

    if (error is TimeoutException) {
      return DeskconnErrorMessages.requestTimedOut;
    }

    return fallback;
  }

  static String? _uriFor(Object error) {
    if (error is ApplicationError) return error.message;

    final raw = error.toString();
    for (final uri in DeskconnErrorUris.values) {
      if (raw.contains(uri)) return uri;
    }

    return null;
  }
}
