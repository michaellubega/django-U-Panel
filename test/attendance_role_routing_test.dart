import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/attendance_role_routing.dart';
import 'package:u_panel/core/auth/user_role.dart';

void main() {
  group('AttendanceRoleRouting.showsStaffAttendanceUi', () {
    test('shows staff UI for @kiu.ac.ug before lecturer doc hydration', () {
      expect(
        AttendanceRoleRouting.showsStaffAttendanceUi(
          isLoggedIn: true,
          roleCheckDone: false,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: true,
          isLikelyStudent: false,
          isStudentAuthIdentity: false,
          resolvedRole: UserRole.lecturer,
        ),
        isTrue,
      );
    });

    test('shows staff UI when role hydrated but isLecturer flag missing', () {
      expect(
        AttendanceRoleRouting.showsStaffAttendanceUi(
          isLoggedIn: true,
          roleCheckDone: true,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: true,
          isLikelyStudent: false,
          isStudentAuthIdentity: false,
          resolvedRole: UserRole.lecturer,
        ),
        isTrue,
      );
    });

    test('shows student UI for student mailbox during hydration', () {
      expect(
        AttendanceRoleRouting.showsStaffAttendanceUi(
          isLoggedIn: true,
          roleCheckDone: false,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: false,
          isLikelyStudent: true,
          isStudentAuthIdentity: true,
          resolvedRole: UserRole.student,
        ),
        isFalse,
      );
    });

    test('shows student UI after hydration for students', () {
      expect(
        AttendanceRoleRouting.showsStaffAttendanceUi(
          isLoggedIn: true,
          roleCheckDone: true,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: false,
          isLikelyStudent: false,
          isStudentAuthIdentity: true,
          resolvedRole: UserRole.student,
        ),
        isFalse,
      );
    });
  });

  group('AttendanceRoleRouting.scopesAttendanceToSignedInUser', () {
    test('scopes lecturer loads for staff mailbox without isLecturer flag', () {
      expect(
        AttendanceRoleRouting.scopesAttendanceToSignedInUser(
          showsStaffAttendanceUi: true,
          adminCheckDone: true,
          isAdmin: false,
          isKiuAdmin: false,
          isLecturer: false,
          roleCheckDone: true,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: true,
          isLikelyStudent: false,
          resolvedRole: UserRole.lecturer,
        ),
        isTrue,
      );
    });

    test('does not scope QA admin loads', () {
      expect(
        AttendanceRoleRouting.scopesAttendanceToSignedInUser(
          showsStaffAttendanceUi: true,
          adminCheckDone: true,
          isAdmin: true,
          isKiuAdmin: false,
          isLecturer: false,
          roleCheckDone: true,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: false,
          isLikelyStudent: false,
          resolvedRole: UserRole.qaStaff,
        ),
        isFalse,
      );
    });

    test('scopes KIU admin loads even when legacy isAdmin is true', () {
      expect(
        AttendanceRoleRouting.scopesAttendanceToSignedInUser(
          showsStaffAttendanceUi: true,
          adminCheckDone: true,
          isAdmin: true,
          isKiuAdmin: true,
          isLecturer: false,
          roleCheckDone: true,
          isSyntheticStaffAuthIdentity: false,
          isStaffAuthIdentity: false,
          isLikelyStudent: false,
          resolvedRole: UserRole.kiuAdmin,
        ),
        isTrue,
      );
    });
  });
}
