import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/kiu_staff_auth_email.dart';
import 'package:u_panel/core/auth/login_email.dart';
import 'package:u_panel/core/auth/student_auth_email.dart';

void main() {
  group('LoginEmail.validateForPasswordReset', () {
    test('accepts @kiu.ac.ug staff mailboxes', () {
      expect(
        LoginEmail.validateForPasswordReset('jane.doe@kiu.ac.ug'),
        isNull,
      );
      expect(
        LoginEmail.normalizeForPasswordReset('Jane.Doe@KIU.AC.UG'),
        'jane.doe@kiu.ac.ug',
      );
    });

    test('accepts @studwc.kiu.ac.ug student mailboxes', () {
      expect(
        LoginEmail.validateForPasswordReset('sabiti.lubega@studwc.kiu.ac.ug'),
        isNull,
      );
      expect(
        LoginEmail.normalizeForPasswordReset('sabiti.lubega@studwc.kiu.ac.ug'),
        'sabiti.lubega@studwc.kiu.ac.ug',
      );
    });

    test('accepts @studmc.kiu.ac.ug student mailboxes', () {
      expect(
        LoginEmail.validateForPasswordReset('sabiti.lubega@studmc.kiu.ac.ug'),
        isNull,
      );
    });

    test('rejects personal email domains', () {
      expect(
        LoginEmail.validateForPasswordReset('user@gmail.com'),
        isNotNull,
      );
    });

    test('rejects staff id without real mailbox', () {
      expect(LoginEmail.validateForPasswordReset('KIU-0001'), isNull);
      expect(LoginEmail.isSyntheticStaff('KIU-0001'), isTrue);
    });
  });

  test('supported domain constants', () {
    expect(StudentAuthEmail.isStudentMailbox('a@studwc.kiu.ac.ug'), isTrue);
    expect(KiuStaffAuthEmail.isStaffMailbox('a@kiu.ac.ug'), isTrue);
  });
}
