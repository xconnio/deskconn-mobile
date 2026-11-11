import 'package:deskconn_mobile_app/providers/auth_provider.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';
import 'package:deskconn_mobile_app/screens/verify_otp_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_snack_bar.dart';
import 'package:deskconn_mobile_app/widgets/auth_card_layout.dart';
import 'package:deskconn_mobile_app/widgets/password_requirement_item.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:deskconn_mobile_app/widgets/validators.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final emailCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final nameFocus = FocusNode();
  final passFocus = FocusNode();

  String? emailError;
  String? nameError;
  bool _obscurePassword = true;

  bool get _passwordMeetsRequirements => Validators.isPasswordValid(passCtrl.text);
  bool get _canCreateAccount =>
      Validators.email(emailCtrl.text) == null &&
      Validators.name(nameCtrl.text, label: 'Username') == null &&
      _passwordMeetsRequirements;

  @override
  void dispose() {
    emailCtrl.dispose();
    nameCtrl.dispose();
    passCtrl.dispose();
    nameFocus.dispose();
    passFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: AuthCardLayout(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: emailCtrl,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => nameFocus.requestFocus(),
              onChanged: (v) {
                setState(() {
                  emailError = null;
                });
              },
              decoration: InputDecoration(labelText: 'Email', errorText: emailError),
            ),

            const SizedBox(height: 16),

            TextField(
              controller: nameCtrl,
              focusNode: nameFocus,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => passFocus.requestFocus(),
              onChanged: (v) {
                setState(() {
                  nameError = null;
                });
              },
              decoration: InputDecoration(labelText: 'Username', errorText: nameError),
            ),

            const SizedBox(height: 16),

            TextField(
              controller: passCtrl,
              focusNode: passFocus,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              onChanged: (v) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            PasswordRequirementItem(isMet: _passwordMeetsRequirements),

            const SizedBox(height: 24),

            auth.isLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                : ElevatedButton(
                    onPressed: _canCreateAccount
                        ? () async {
                            FocusScope.of(context).unfocus();

                            setState(() {
                              emailError = Validators.email(emailCtrl.text);
                              nameError = Validators.name(nameCtrl.text, label: 'Username');
                            });

                            if (emailError != null || nameError != null || !_passwordMeetsRequirements) {
                              return;
                            }

                            final result = await auth.createAccount(
                              email: emailCtrl.text.trim(),
                              name: nameCtrl.text.trim(),
                              password: passCtrl.text,
                            );

                            if (!context.mounted) return;

                            if (result.isSuccess) {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const VerifyOtpScreen()));
                            } else {
                              AppSnackBar.showError(context, result.error ?? DeskconnErrorMessages.signUpFailed);
                            }
                          }
                        : null,
                    child: const Text('Create account'),
                  ),

            const Divider(),
            TextButton(
              onPressed: auth.isLoading
                  ? null
                  : () {
                      if (Navigator.canPop(context)) {
                        Navigator.pop(context);
                        return;
                      }

                      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SignInScreen()));
                    },
              child: const Text('Already have an account? Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
