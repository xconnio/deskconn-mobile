/// User-facing fallback messages used when an error cannot be mapped from a
/// known backend error URI.
class DeskconnErrorMessages {
  const DeskconnErrorMessages._();

  static const defaultError = 'Something went wrong. Please try again.';
  static const requestTimedOut = 'The request timed out. Please try again.';

  static const signInFailed = 'Unable to send verification code.';
  static const standaloneSignInFailed = 'Could not connect to the machine.';
  static const standaloneCertificateMismatch = 'The machine\'s certificate does not match the fingerprint.';
  static const signInSessionExpired = 'Sign-in session expired. Please sign in again.';
  static const invalidSignInCode = 'Invalid or expired code.';
  static const signUpFailed = 'Could not create your account.';
  static const signUpFailedWithRetry = 'Could not create your account. Please try again.';
  static const verificationFailed = 'Verification failed. Please try again.';
  static const verificationSessionExpired = 'Verification session expired. Please create your account again.';
  static const verificationSignInNotInitialized = 'Verification completed, but sign-in could not be initialized.';
  static const verificationSignInFailed = 'Verification completed, but sign-in failed.';
  static const resendVerificationCodeFailed = 'Could not resend the verification code.';
  static const resetCodeSendFailed = 'Could not send a reset code.';
  static const passwordChangeFailed = 'Could not change your password.';
  static const passwordChanged = 'Password changed successfully';
  static const pendingVerificationMissing = 'No pending verification';
  static const pendingPasswordResetMissing = 'No pending password reset';
  static const emptyVerificationResponse = 'Empty verification response';
}
