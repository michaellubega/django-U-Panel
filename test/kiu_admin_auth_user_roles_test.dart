import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/auth_repository.dart';

void main() {
  group('AuthRepository.applyAuthUserRoleHints', () {
    test('Django kiu_admin role wins over stale student role', () {
      var kiu = false;
      var admin = false;
      var qa = false;
      var lecturer = false;
      var onboarding = false;

      AuthRepository.applyAuthUserRoleHints(
        <String, dynamic>{
          'role': 'kiu_admin',
          'is_kiu_admin': true,
          'is_admin': true,
          'is_student': true,
        },
        preserveKiuAdminFromDocs: false,
        setKiuAdmin: (v) => kiu = v,
        setAdmin: (v) => admin = v,
        setQaStaff: (v) => qa = v,
        setLecturer: (v) => lecturer = v,
        setOnboardingComplete: (v) => onboarding = v,
      );

      expect(kiu, isTrue);
      expect(admin, isFalse);
      expect(qa, isFalse);
    });

    test('does not downgrade document KIU admin when API role is still student', () {
      var kiu = true;
      var admin = true;
      var qa = true;

      AuthRepository.applyAuthUserRoleHints(
        <String, dynamic>{
          'role': 'student',
          'is_kiu_admin': false,
          'is_admin': false,
          'is_qa_staff': false,
        },
        preserveKiuAdminFromDocs: true,
        setKiuAdmin: (v) => kiu = v,
        setAdmin: (v) => admin = v,
        setQaStaff: (v) => qa = v,
        setLecturer: (_) {},
        setOnboardingComplete: (_) {},
      );

      expect(kiu, isTrue);
      expect(admin, isTrue);
      expect(qa, isTrue);
    });

    test('admin doc with adminRole kiu_administrator grants role', () {
      final data = <String, dynamic>{
        AuthRepository.adminRoleField: AuthRepository.staffAccountRoleKiuAdministrator,
      };
      expect(AuthRepository.adminDocIsKiuAdministrator(data), isTrue);
      expect(AuthRepository.adminDocGrantsRole(data), isTrue);
    });
  });
}
