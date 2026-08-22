import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/lecturer_registration_number.dart';

/// QA admin: assign lecturer by typing KIU staff ID or registration number.
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
      decoration: InputDecoration(
        labelText: 'Assigned lecturer (KIU staff ID)',
        hintText: LecturerRegistrationNumber.exampleHint,
        helperText:
            'Required. The lecturer must be registered under Staff & accounts first.',
        counterText: '',
      ),
      maxLength: 12,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
      ],
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Required' : null,
    );
  }
}
