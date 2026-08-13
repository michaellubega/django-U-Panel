import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/auth_repository.dart';
import 'package:u_panel/core/auth/user_role.dart';

void main() {
  group('KIU administrator account detection', () {
    test('adminDocIsKiuAdministratorOnly excludes staff-number QA heuristic', () {
      final data = <String, dynamic>{
        AuthRepository.adminIsKiuAdminField: true,
        AuthRepository.adminIsAdminField: false,
        'staffNumber': 'KIU4235S',
      };
      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isTrue);
      expect(AuthRepository.adminDocIsQaStaff(data), isFalse);
    });
  });

  group('UserRole.kiuAdmin navigation intent', () {
    test('kiu admin is distinct from lecturer and QA admin', () {
      expect(UserRole.kiuAdmin.hasStaffOperationalAccess, isFalse);
      expect(UserRole.kiuAdmin.hasLecturerAttendanceAccess, isTrue);
      expect(UserRole.admin.hasStaffOperationalAccess, isTrue);
      expect(UserRole.qaStaff.hasStaffOperationalAccess, isTrue);
    });
  });
}
