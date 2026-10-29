import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/screens/forgot_password_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_in_otp_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_up_screen.dart';
import 'package:deskconn_mobile_app/screens/standalone_sign_in_screen.dart';
import 'package:deskconn_mobile_app/theme/typography.dart';
import 'package:deskconn_mobile_app/widgets/app_snack_bar.dart';
import 'package:deskconn_mobile_app/widgets/logo.dart';
import 'package:deskconn_mobile_app/widgets/theme_toggle.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskconn_mobile_app/widgets/validators.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final passFocus = FocusNode();
  String? emailError;
  String? passwordError;
  bool _obscurePassword = true;

  void _clearForm() {
    emailCtrl.clear();
    passCtrl.clear();
    emailError = null;
    passwordError = null;
  }

  @override
  void initState() {
    super.initState();
    _restoreEmail();
  }

  Future<void> _restoreEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString('last_email');
    if (email != null) {
      if (mounted) {
        setState(() {
          emailCtrl.text = email;
        });
      }
    }
  }

  @override
  void dispose() {
    emailCtrl.dispose();
    passCtrl.dispose();
    passFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, actions: const [ThemeToggleButton()]),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 16),
                const DeskconnLogo(size: 48),
                const SizedBox(height: 12),
                Text('Deskconn', style: DeskconnTypography.title(context)),
                const SizedBox(height: 32),

                Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  child: SizedBox(
                    width: 380,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: emailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) => passFocus.requestFocus(),
                            onChanged: (v) {
                              if (emailError != null || passwordError != null) {
                                setState(() {
                                  emailError = null;
                                  passwordError = null;
                                });
                              }
                            },
                            decoration: InputDecoration(labelText: 'Email', errorText: emailError),
                          ),

                          const SizedBox(height: 16),

                          TextField(
                            controller: passCtrl,
                            focusNode: passFocus,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => FocusScope.of(context).unfocus(),
                            onChanged: (v) {
                              if (emailError != null || passwordError != null) {
                                setState(() {
                                  emailError = null;
                                  passwordError = null;
                                });
                              }
                            },
                            decoration: InputDecoration(
                              labelText: 'Password',
                              errorText: passwordError,
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          if (session.isLoading)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Center(
                                child: SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            )
                          else
                            ElevatedButton(
                              onPressed: () async {
                                FocusScope.of(context).unfocus();

                                setState(() {
                                  emailError = Validators.email(emailCtrl.text);
                                  passwordError = Validators.required(passCtrl.text, label: 'Password');
                                });

                                if (emailError != null || passwordError != null) {
                                  return;
                                }

                                final email = emailCtrl.text.trim();
                                final result = await session.requestSignInOtp(email, passCtrl.text);

                                if (!context.mounted) return;

                                if (result.isSuccess) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => SignInOtpScreen(email: email)),
                                  );
                                } else {
                                  AppSnackBar.showError(context, result.error ?? DeskconnErrorMessages.signInFailed);
                                }
                              },
                              child: const Text('Sign in'),
                            ),

                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: session.isLoading
                                  ? null
                                  : () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                                      );
                                    },
                              child: const Text('Forgot password?'),
                            ),
                          ),

                          const Divider(),
                          TextButton(
                            onPressed: session.isLoading
                                ? null
                                : () async {
                                    setState(_clearForm);

                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => const SignUpScreen()),
                                    );

                                    if (!context.mounted) return;
                                    setState(_clearForm);
                                  },
                            child: const Text('Create account'),
                          ),
                          TextButton(
                            onPressed: session.isLoading
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const StandaloneSignInScreen()),
                                  ),
                            child: const Text('Connect to a standalone machine'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
