import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// QA admin: assign lecturer by typing KIU-#### only.
class AssignedLecturerField extends StatelessWidget {
  const AssignedLecturerField({
    super.key,
    required this.manualStaffController,
  });

  final TextEditingController manualStaffController;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: manualStaffController,
      decoration: const InputDecoration(
        labelText: 'Assigned lecturer (KIU staff ID)',
        hintText: 'e.g. KIU-0042 or 0042',
        helperText:
            'Required. The lecturer must be registered under Staff & accounts first.',
        counterText: '',
      ),
      maxLength: 10,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
      ],
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Required' : null,
    );
  }
}
