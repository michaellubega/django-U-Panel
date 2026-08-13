import 'package:flutter_test/flutter_test.dart';
import 'package:u_panel/core/cache/smart_cache_policy.dart';

void main() {
  test('staff attendance list catalog refreshes sooner than profile cache', () {
    expect(
      SmartCachePolicy.staffAttendanceListsTtl.inSeconds,
      lessThan(SmartCachePolicy.profileAndNoticesTtl.inSeconds),
    );
    expect(
      SmartCachePolicy.staffAttendanceListsSoftStale.inSeconds,
      lessThan(SmartCachePolicy.staffAttendanceListsTtl.inSeconds),
    );
  });
}
