import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';

/// Change password for the signed-in account.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentC = TextEditingController();
  final _newC = TextEditingController();
  final _confirmC = TextEditingController();
  bool _busy = false;
  bool _hideCurrent = true;
  bool _hideNew = true;
  bool _hideConfirm = true;
  String? _errorText;

  @override
  void dispose() {
    _currentC.dispose();
    _newC.dispose();
    _confirmC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _currentC.text;
    final next = _newC.text;
    final confirm = _confirmC.text;
    if (next != confirm) {
      setState(() => _errorText = 'New passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _errorText = null;
    });
    final err = await AuthRepository.instance.changePassword(
      currentPassword: current,
      newPassword: next,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _errorText = err;
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password changed successfully.')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _currentC,
                obscureText: _hideCurrent,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Current password',
                  errorText: _errorText,
                  suffixIcon: IconButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _hideCurrent = !_hideCurrent),
                    icon: Icon(
                      _hideCurrent
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _newC,
                obscureText: _hideNew,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'New password',
                  suffixIcon: IconButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _hideNew = !_hideNew),
                    icon: Icon(
                      _hideNew
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmC,
                obscureText: _hideConfirm,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Confirm new password',
                  suffixIcon: IconButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _hideConfirm = !_hideConfirm),
                    icon: Icon(
                      _hideConfirm
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Change password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
