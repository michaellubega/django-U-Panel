import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/errors/user_facing_errors.dart';
import '../../core/auth/staff_auth_email.dart';
import '../../core/theme/app_theme.dart';
import 'staff_credentials_screen.dart';

enum _StaffKind { qaStaff, lecturer }

enum _StaffIdMode { auto, manual }

/// Admin-only: register QA staff or lecturer with name and a `KIU-####` staff ID (auto or manual).
class RegisterStaffScreen extends StatefulWidget {
  const RegisterStaffScreen({super.key});

  @override
  State<RegisterStaffScreen> createState() => _RegisterStaffScreenState();
}

class _RegisterStaffScreenState extends State<RegisterStaffScreen> {
  _StaffKind? _kind;
  _StaffIdMode _staffIdMode = _StaffIdMode.auto;
  final _fullNameC = TextEditingController();
  final _manualStaffIdC = TextEditingController();
  late final TextEditingController _defaultPasswordC;
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
        const SnackBar(content: Text('Enter the staff member\'s name.')),
      );
      return;
    }

    final kind = _kind;
    if (kind == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Select user type: QA staff or lecturer.')),
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

    final manualArg = _staffIdMode == _StaffIdMode.manual
        ? _manualStaffIdC.text.trim()
        : null;

    setState(() => _busy = true);
    final StaffRegistrationResult result;
    if (kind == _StaffKind.qaStaff) {
      result = await AuthRepository.instance.registerQaStaffAccount(
        fullName: fullName,
        manualStaffNumber: manualArg,
      );
    } else {
      result = await AuthRepository.instance.registerLecturerAccount(
        fullName: fullName,
        manualStaffNumber: manualArg,
      );
    }
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

    final roleLabel = kind == _StaffKind.qaStaff ? 'QA staff' : 'Lecturer';
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => StaffCredentialsScreen(
          fullName: fullName,
          roleLabel: roleLabel,
          staffId: staffId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register staff'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: ListenableBuilder(
        listenable: AuthRepository.instance,
        builder: (context, _) {
          final auth = AuthRepository.instance;
          if (!auth.adminCheckDone) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!auth.isAdmin) {
            final denied = auth.apiRoleCheckDenied;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  denied
                      ? UserFacingErrors.adminProfileUnavailable
                      : UserFacingErrors.notAdminForStaffCreation,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final kind = _kind;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'User type',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<_StaffKind>(
                emptySelectionAllowed: true,
                segments: const [
                  ButtonSegment(
                      value: _StaffKind.qaStaff, label: Text('QA staff')),
                  ButtonSegment(
                      value: _StaffKind.lecturer, label: Text('Lecturer')),
                ],
                selected: kind == null ? const <_StaffKind>{} : {kind},
                onSelectionChanged:
                    _busy ? null : (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 8),
              Text(
                kind == null
                    ? 'Select QA staff or lecturer for this account.'
                    : kind == _StaffKind.qaStaff
                        ? 'QA staff: KIU-#### sign-in with full operational access (attendance, reports).'
                        : 'Lecturer: KIU-#### or @kiu.ac.ug — attendance scoped to their classes.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.35,
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
                      value: _StaffIdMode.manual, label: Text('Manual')),
                ],
                selected: {_staffIdMode},
                onSelectionChanged: (s) =>
                    setState(() => _staffIdMode = s.first),
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
                onPressed: (_busy || kind == null) ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Register'),
              ),
            ],
          );
        },
      ),
    );
  }
}
