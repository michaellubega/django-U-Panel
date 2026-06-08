import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/auth/kiu_admin_job_title.dart';
import '../../core/auth/kiu_admin_registration_number.dart';
import '../../core/auth/lecturer_registration_number.dart';
import '../../core/auth/student_registration_number.dart';
import '../../core/auth/user_role.dart';
import '../../core/connectivity/app_connectivity.dart';

/// Edit full name and registration number for the signed-in account.
class UpdateProfileScreen extends StatefulWidget {
  const UpdateProfileScreen({super.key});

  @override
  State<UpdateProfileScreen> createState() => _UpdateProfileScreenState();
}

class _UpdateProfileScreenState extends State<UpdateProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameC = TextEditingController();
  final _regC = TextEditingController();
  final _roleC = TextEditingController();
  bool _busy = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    final auth = AuthRepository.instance;
    _nameC.text = auth.currentFullName?.trim() ?? '';
    _regC.text = auth.currentRegistrationNumber?.trim() ?? '';
    if (auth.isKiuAdmin) {
      _roleC.text = auth.currentKiuAdminJobTitle?.trim() ?? '';
    }
  }

  @override
  void dispose() {
    _nameC.dispose();
    _regC.dispose();
    _roleC.dispose();
    super.dispose();
  }

  SelfServiceProfileKind? get _kind =>
      AuthRepository.instance.selfServiceProfileKind;

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter your full name.';
    }
    return null;
  }

  String? _validateRegistration(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter your registration number.';
    }
    switch (_kind) {
      case SelfServiceProfileKind.student:
        return StudentRegistrationNumber.validateFormat(value);
      case SelfServiceProfileKind.administrator:
        return KiuAdminRegistrationNumber.validateFormat(value);
      case SelfServiceProfileKind.lecturer:
        return LecturerRegistrationNumber.validateFormat(value);
      case null:
        return null;
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() => _submitError = null);
    if (!_formKey.currentState!.validate()) return;

    if (AppConnectivity.instance.initialized &&
        !AppConnectivity.instance.isOnline) {
      setState(
        () => _submitError = AuthRepository.networkUnavailableMessage,
      );
      return;
    }

    setState(() => _busy = true);
    final auth = AuthRepository.instance;
    final err = await AuthRepository.instance.updateProfileForCurrentUser(
      fullName: _nameC.text,
      registrationNumber: _regC.text,
      kiuAdminJobTitle: auth.isKiuAdmin ? _roleC.text : null,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _submitError = err;
      });
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile updated successfully.')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kind;
    final auth = AuthRepository.instance;
    final regExample = auth.profileRegistrationExample;
    final staffNumber = auth.currentStaffNumber?.trim();
    final showStaffIdNote = kind == SelfServiceProfileKind.lecturer &&
        staffNumber != null &&
        staffNumber.isNotEmpty &&
        staffNumber != _regC.text.trim().toUpperCase();

    return Scaffold(
      appBar: AppBar(title: const Text('Update profile')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_submitError != null) ...[
                  Text(
                    _submitError!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _nameC,
                  autofocus: true,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  validator: _validateName,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _regC,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: _busy ? null : (_) => _submit(),
                  validator: _validateRegistration,
                  decoration: InputDecoration(
                    labelText: 'Registration number',
                    helperText: regExample != null
                        ? 'Format example: $regExample'
                        : null,
                  ),
                ),
                if (showStaffIdNote) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Login staff ID: $staffNumber (assigned by an administrator).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (auth.isKiuAdmin) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _roleC,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Admin role (optional)',
                      hintText: 'DIRECTOR QUALITY ASSURANCE',
                      helperText: KiuAdminJobTitle.examplesLine,
                    ),
                    onChanged: (v) {
                      final upper = v.toUpperCase();
                      if (v != upper) {
                        _roleC.value = _roleC.value.copyWith(
                          text: upper,
                          selection: TextSelection.collapsed(
                            offset: upper.length,
                          ),
                        );
                      }
                    },
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save profile'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
