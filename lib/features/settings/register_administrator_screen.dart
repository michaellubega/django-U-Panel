import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/errors/user_facing_errors.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/theme/app_theme.dart';
import 'staff_credentials_screen.dart';

enum _StaffIdMode { auto, manual }

/// Full administrators only: create another administrator (KIU-####, same as register staff).
class RegisterAdministratorScreen extends StatefulWidget {
  const RegisterAdministratorScreen({super.key});

  @override
  State<RegisterAdministratorScreen> createState() =>
      _RegisterAdministratorScreenState();
}

class _RegisterAdministratorScreenState
    extends State<RegisterAdministratorScreen> {
  _StaffIdMode _staffIdMode = _StaffIdMode.auto;
  final _fullNameC = TextEditingController();
  final _manualStaffIdC = TextEditingController();
  late final TextEditingController _defaultPasswordC;
  bool _markAsKiuAdministrator = false;
  bool _busy = false;
  bool _defaultPasswordVisible = false;

  @override
  void initState() {
    super.initState();
    _defaultPasswordC = TextEditingController(
      text: StaffAuthEmail.defaultLecturerPassword,
    );
  }

  @override
  void dispose() {
    _fullNameC.dispose();
    _manualStaffIdC.dispose();
    _defaultPasswordC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_busy) return;

    final fullName = _fullNameC.text.trim();
    if (fullName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the administrator\'s name.')),
      );
      return;
    }

    if (_staffIdMode == _StaffIdMode.manual &&
        _manualStaffIdC.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a staff ID (KIU-####).')),
      );
      return;
    }

    final manualArg =
        _staffIdMode == _StaffIdMode.manual ? _manualStaffIdC.text.trim() : null;

    setState(() => _busy = true);
    final result = await AuthRepository.instance.registerAdministratorAccount(
      fullName: fullName,
      manualStaffNumber: manualArg,
      markAsKiuAdministrator: _markAsKiuAdministrator,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
      return;
    }

    final staffId = result.staffNumber;
    if (staffId == null) return;

    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => StaffCredentialsScreen(
          fullName: fullName,
          roleLabel: 'Administrator',
          staffId: staffId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grant administrator access'),
        backgroundColor: AppTheme.secondary,
        foregroundColor: Colors.white,
      ),
      body: ListenableBuilder(
        listenable: AuthRepository.instance,
        builder: (context, _) {
          final auth = AuthRepository.instance;
          if (!auth.adminCheckDone) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!auth.isFullAdministrator) {
            final denied = auth.firestoreRoleCheckDenied;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  denied
                      ? UserFacingErrors.adminProfileUnavailable
                      : 'Only full administrators can grant administrator access. '
                          'QA staff should use Register staff → QA staff instead.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Creates a new administrator account with full administrator role '
                '(not QA staff). Sign-in uses staff ID and the default password, '
                'same as lecturers and QA staff.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 24),
              Text(
                'Name',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _fullNameC,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  hintText: 'e.g. Jane Doe',
                ),
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 24),
              Text(
                'Staff ID',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<_StaffIdMode>(
                segments: const [
                  ButtonSegment(value: _StaffIdMode.auto, label: Text('Auto')),
                  ButtonSegment(
                    value: _StaffIdMode.manual,
                    label: Text('Manual'),
                  ),
                ],
                selected: {_staffIdMode},
                onSelectionChanged: (s) => setState(() => _staffIdMode = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                _staffIdMode == _StaffIdMode.auto
                    ? 'The system assigns the next free KIU-#### (e.g. KIU-0003).'
                    : 'Enter a specific KIU-#### if you are reserving an ID.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.35,
                    ),
              ),
              if (_staffIdMode == _StaffIdMode.manual) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _manualStaffIdC,
                  decoration: const InputDecoration(
                    labelText: 'Staff ID',
                    hintText: 'KIU-0001',
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
              ],
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _markAsKiuAdministrator,
                onChanged: (v) =>
                    setState(() => _markAsKiuAdministrator = v ?? false),
                title: const Text('KIU administrator (campus check-in)'),
                subtitle: const Text(
                  'Also grants campus check-in/out and lecturer attendance access.',
                ),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 12),
              TextFormField(
                readOnly: true,
                controller: _defaultPasswordC,
                obscureText: !_defaultPasswordVisible,
                decoration: InputDecoration(
                  labelText: 'Default password for new accounts',
                  suffixIcon: IconButton(
                    tooltip: _defaultPasswordVisible
                        ? 'Hide password'
                        : 'Show password',
                    onPressed: () => setState(
                      () => _defaultPasswordVisible = !_defaultPasswordVisible,
                    ),
                    icon: Icon(
                      _defaultPasswordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create administrator'),
              ),
            ],
          );
        },
      ),
    );
  }
}
