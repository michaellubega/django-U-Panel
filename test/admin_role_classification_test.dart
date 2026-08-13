import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/auth_repository.dart';

void main() {
  group('AuthRepository admin doc classification', () {
    test('KIU administrator with staff number is not QA staff', () {
      final data = <String, dynamic>{
        AuthRepository.adminIsKiuAdminField: true,
        AuthRepository.adminIsAdminField: false,
        'staffNumber': 'KIU4235S',
        'fullName': 'Campus Admin',
      };

      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isTrue);
      expect(AuthRepository.adminDocIsQaStaff(data), isFalse);
      expect(AuthRepository.adminDocIsFullAdministrator(data), isFalse);
    });

    test('QA staff with staff number is QA staff', () {
      final data = <String, dynamic>{
        AuthRepository.adminIsAdminField: true,
        AuthRepository.adminRoleField: AuthRepository.adminRoleQaStaff,
        'staffNumber': 'KIU-1234',
      };

      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isFalse);
      expect(AuthRepository.adminDocIsQaStaff(data), isTrue);
    });

    test('full administrator is not KIU-only', () {
      final data = <String, dynamic>{
        AuthRepository.adminIsAdminField: true,
        AuthRepository.adminRoleField: AuthRepository.adminRoleAdministrator,
      };

      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isFalse);
      expect(AuthRepository.adminDocIsQaStaff(data), isFalse);
      expect(AuthRepository.adminDocIsFullAdministrator(data), isTrue);
    });

    test('legacy QA staff row without role but with staff number', () {
      final data = <String, dynamic>{
        'staffNumber': 'KIU-5678',
      };

      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isFalse);
      expect(AuthRepository.adminDocIsQaStaff(data), isTrue);
    });

    test('Django-synced KIU admin with both flags is still KIU admin', () {
      final data = <String, dynamic>{
        AuthRepository.adminIsKiuAdminField: true,
        AuthRepository.adminIsAdminField: true,
        'staffNumber': 'KIU4235S',
        'fullName': 'Campus Admin',
      };

      expect(AuthRepository.adminDocIsKiuAdministrator(data), isTrue);
      expect(AuthRepository.adminDocIsKiuAdministratorOnly(data), isFalse);
      expect(AuthRepository.adminDocIsQaStaff(data), isFalse);
      expect(AuthRepository.adminDocIsFullAdministrator(data), isFalse);
    });
  });
}
