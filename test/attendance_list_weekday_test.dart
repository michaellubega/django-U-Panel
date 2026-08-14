import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/api/api_datetime.dart';
import 'package:u_panel/features/attendance/attendance_list_hierarchy.dart';
import 'package:u_panel/features/attendance/models/attendance_models.dart';

void main() {
  test('apiDateOnlyToField keeps weekday anchor dates stable', () {
    final tuesday = attendanceListDateForWeekday(DateTime.tuesday);
    expect(apiDateOnlyToField(tuesday), '2024-01-02');
    expect(apiDateOnlyToField(attendanceListDateForWeekday(DateTime.sunday)),
        '2024-01-07');
  });

  test('attendanceListDateFromStored normalizes UTC-shifted ISO strings', () {
    const shiftedTuesday = '2024-01-01T21:00:00.000Z';
    final normalized = attendanceListDateFromStored(shiftedTuesday);
    final expectedWeekday = DateTime.parse(shiftedTuesday).toLocal().weekday;
    expect(normalized, attendanceListDateForWeekday(expectedWeekday));
    expect(normalized.weekday, expectedWeekday);
  });

  test('attendanceListDateFromStored accepts date-only legacy values', () {
    final normalized = attendanceListDateFromStored('2024-01-03');
    expect(normalized, attendanceListDateForWeekday(DateTime.wednesday));
  });

  test('round-trip write/read keeps list under correct weekday bucket', () {
    final list = AttendanceList(
      id: '1',
      time: '08:00',
      room: 'R1',
      whoTaught: 'Dr. Test',
      date: attendanceListDateForWeekday(DateTime.tuesday),
      courses: const ['CS101'],
      year: '1',
      sem: '1',
    );

    final serialized = apiDateOnlyToField(list.date);
    final restored = attendanceListDateFromStored(serialized);
    final restoredList = AttendanceList(
      id: list.id,
      time: list.time,
      room: list.room,
      whoTaught: list.whoTaught,
      date: restored,
      courses: list.courses,
      year: list.year,
      sem: list.sem,
    );

    final byDay = groupListsByWeekday([restoredList]);
    expect(byDay[DateTime.tuesday]?.length, 1);
    expect(byDay[DateTime.monday], isNull);
  });

  test('weekend list stays visible after UTC-shifted deserialize', () {
    const shiftedSunday = '2024-01-06T21:00:00.000Z';
    final date = attendanceListDateFromStored(shiftedSunday);
    final list = AttendanceList(
      id: 'weekend-1',
      time: '09:00',
      room: 'R2',
      whoTaught: 'Dr. Weekend',
      date: date,
      program: AttendanceProgram.weekend,
      courses: const ['CS201'],
      year: '2',
      sem: '1',
    );

    expect(attendanceListVisibleInHierarchy(list), isTrue);
    expect(
      isWeekendWeekday(list.date.weekday),
      isTrue,
      reason: 'weekend program requires Sat/Sun class day',
    );
  });
}
