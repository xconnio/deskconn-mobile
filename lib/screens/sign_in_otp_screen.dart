import 'package:deskconn_mobile_app/core/auth/otp_resend_cooldown.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/screens/desktop_list_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_snack_bar.dart';
import 'package:deskconn_mobile_app/widgets/auth_card_layout.dart';
import 'package:deskconn_mobile_app/widgets/otp_code_field.dart';
import 'package:deskconn_mobile_app/widgets/otp_resend_button.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SignInOtpScreen extends StatefulWidget {
  const SignInOtpScreen({super.key, required this.email});

  final String email;

  @override
  State<SignInOtpScreen> createState() => _SignInOtpScreenState();
}

class _SignInOtpScreenState extends State<SignInOtpScreen> {
  final otpCtrl = TextEditingController();
  final otpFocus = FocusNode();
  final _resendCooldown = OtpResendCooldown();

  bool _resending = false;

  bool get _canVerify => otpCtrl.text.length == 6;
  bool get _canResend => !_resending && _resendCooldown.canResend;

  @override
  void initState() {
    super.initState();
    _resendCooldown.start(onChanged: _refreshCooldown, notifyImmediately: false);
  }

  @override
  void dispose() {
    _resendCooldown.dispose();
    otpCtrl.dispose();
    otpFocus.dispose();
    super.dispose();
  }

  void _refreshCooldown() {
    if (mounted) setState(() {});
  }

  Future<void> _verify() async {
    if (!_canVerify) return;

    FocusScope.of(context).unfocus();

    final session = context.read<SessionProvider>();
    final result = await session.verifySignInOtp(email: widget.email, otp: otpCtrl.text);

    if (!mounted) return;

    if (result.isSuccess && session.loggedIn) {
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const DesktopListScreen()), (_) => false);
    } else {
      AppSnackBar.showError(context, result.error ?? DeskconnErrorMessages.invalidSignInCode);
    }
  }

  Future<void> _resendCode() async {
    if (!_canResend) return;

    setState(() {
      _resending = true;
    });

    final result = await context.read<SessionProvider>().resendSignInOtp(widget.email);

    if (!mounted) return;

    setState(() {
      _resending = false;
    });

    if (result.isSuccess) {
      otpCtrl.clear();
      _resendCooldown.start(onChanged: _refreshCooldown);
    } else {
      AppSnackBar.showError(context, result.error ?? DeskconnErrorMessages.resendVerificationCodeFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Verify sign in')),
      body: AuthCardLayout(
        alignment: const Alignment(0, -0.48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Enter the 6-digit code sent to ${widget.email}', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            OtpCodeField(
              controller: otpCtrl,
              focusNode: otpFocus,
              enabled: !session.isLoading,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            if (session.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              ElevatedButton(onPressed: _canVerify ? _verify : null, child: const Text('Verify')),
            const SizedBox(height: 12),
            OtpResendButton(
              label: _resendCooldown.label,
              isLoading: _resending,
              onPressed: session.isLoading || !_canResend ? null : _resendCode,
            ),
          ],
        ),
      ),
    );
  }
}
