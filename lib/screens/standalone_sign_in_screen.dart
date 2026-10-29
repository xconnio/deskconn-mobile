import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:deskconn_mobile_app/core/auth/standalone_login.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_messages.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/screens/desktop_list_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_snack_bar.dart';
import 'package:deskconn_mobile_app/widgets/auth_card_layout.dart';
import 'package:deskconn_mobile_app/widgets/validators.dart';

enum _StandaloneMethod { password, key }

class StandaloneSignInScreen extends StatefulWidget {
  const StandaloneSignInScreen({super.key});

  @override
  State<StandaloneSignInScreen> createState() => _StandaloneSignInScreenState();
}

class _StandaloneSignInScreenState extends State<StandaloneSignInScreen> {
  final urlCtrl = TextEditingController();
  final authIdCtrl = TextEditingController();
  final secretCtrl = TextEditingController();
  final fingerprintCtrl = TextEditingController();

  _StandaloneMethod method = _StandaloneMethod.password;
  bool _obscureSecret = true;

  String? urlError;
  String? authIdError;
  String? secretError;
  String? fingerprintError;

  @override
  void dispose() {
    urlCtrl.dispose();
    authIdCtrl.dispose();
    secretCtrl.dispose();
    fingerprintCtrl.dispose();
    super.dispose();
  }

  void _clearErrors() {
    if (urlError == null && authIdError == null && secretError == null && fingerprintError == null) return;
    setState(() {
      urlError = null;
      authIdError = null;
      secretError = null;
      fingerprintError = null;
    });
  }

  String? _formatError(String Function() parse) {
    try {
      parse();
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Future<void> _connect(SessionProvider session) async {
    FocusScope.of(context).unfocus();

    final secretLabel = method == _StandaloneMethod.password ? 'Password' : 'Private key';
    setState(() {
      urlError =
          Validators.required(urlCtrl.text, label: 'URL') ??
          _formatError(() => StandaloneLogin.parseAddress(urlCtrl.text));
      authIdError = Validators.required(authIdCtrl.text, label: 'Username');
      secretError = Validators.required(secretCtrl.text, label: secretLabel);
      fingerprintError =
          Validators.required(fingerprintCtrl.text, label: 'Certificate fingerprint') ??
          _formatError(() => StandaloneLogin.parseFingerprint(fingerprintCtrl.text));
    });
    if (urlError != null || authIdError != null || secretError != null || fingerprintError != null) return;

    final secret = method == _StandaloneMethod.password ? secretCtrl.text : secretCtrl.text.trim();
    final result = await session.loginStandalone(
      StandaloneLogin(
        address: StandaloneLogin.parseAddress(urlCtrl.text),
        authId: authIdCtrl.text.trim(),
        password: method == _StandaloneMethod.password ? secret : null,
        privateKey: method == _StandaloneMethod.key ? secret : null,
        certificateFingerprint: StandaloneLogin.parseFingerprint(fingerprintCtrl.text),
      ),
    );

    if (!mounted) return;

    if (result.isSuccess && session.loggedIn) {
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const DesktopListScreen()), (_) => false);
    } else {
      AppSnackBar.showError(context, result.error ?? DeskconnErrorMessages.standaloneSignInFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final isPassword = method == _StandaloneMethod.password;

    return Scaffold(
      appBar: AppBar(title: const Text('Standalone machine')),
      body: AuthCardLayout(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Connect straight to a machine running deskconnd in standalone mode, without a Deskconn account.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearErrors(),
              decoration: InputDecoration(
                labelText: 'URL',
                hintText: 'quic://192.168.1.10:18080',
                errorText: urlError,
                errorMaxLines: 2,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: authIdCtrl,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearErrors(),
              decoration: InputDecoration(labelText: 'Username', errorText: authIdError),
            ),
            const SizedBox(height: 16),
            SegmentedButton<_StandaloneMethod>(
              segments: const [
                ButtonSegment(value: _StandaloneMethod.password, label: Text('Password')),
                ButtonSegment(value: _StandaloneMethod.key, label: Text('Private key')),
              ],
              selected: {method},
              onSelectionChanged: (selection) => setState(() {
                method = selection.first;
                secretCtrl.clear();
                secretError = null;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: secretCtrl,
              obscureText: _obscureSecret,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearErrors(),
              decoration: InputDecoration(
                labelText: isPassword ? 'Password' : 'Private key (hex)',
                errorText: secretError,
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscureSecret = !_obscureSecret),
                  icon: Icon(_obscureSecret ? Icons.visibility_off : Icons.visibility),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: fingerprintCtrl,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              onChanged: (_) => _clearErrors(),
              decoration: InputDecoration(
                labelText: 'Certificate fingerprint',
                helperText: 'SHA-256 printed by desk serve --mode standalone.',
                helperMaxLines: 3,
                errorText: fingerprintError,
                errorMaxLines: 2,
              ),
            ),
            const SizedBox(height: 24),
            if (session.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else
              ElevatedButton(onPressed: () => _connect(session), child: const Text('Connect')),
          ],
        ),
      ),
    );
  }
}
