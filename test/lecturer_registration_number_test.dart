import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/auth/lecturer_registration_number.dart';

void main() {
  group('LecturerRegistrationNumber', () {
    test('accepts KIU registration numbers for lecturer assignment', () {
      expect(LecturerRegistrationNumber.isValidLookupId('KIU1234S'), isTrue);
      expect(LecturerRegistrationNumber.isValidLookupId('kiu1234s'), isTrue);
      expect(
        LecturerRegistrationNumber.normalizeForLookup('KIU1234S'),
        'KIU1234S',
      );
    });

    test('accepts synthetic KIU staff IDs for lecturer assignment', () {
      expect(LecturerRegistrationNumber.isValidLookupId('KIU-0042'), isTrue);
      expect(LecturerRegistrationNumber.isValidLookupId('0042'), isTrue);
      expect(
        LecturerRegistrationNumber.normalizeForLookup('0042'),
        'KIU-0042',
      );
    });

    test('rejects unknown staff id formats', () {
      expect(LecturerRegistrationNumber.isValidLookupId('ABC1234S'), isFalse);
      expect(LecturerRegistrationNumber.isValidLookupId('KIU-12'), isFalse);
      expect(LecturerRegistrationNumber.validateFormat('ABC1234S'), isNotNull);
    });
  });
}
